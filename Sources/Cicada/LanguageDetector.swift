import AVFoundation

// MARK: - Spoken language detection

/// Detects the spoken language by transcribing the same short clip with
/// every installed on-device model and comparing how confident each one is.
/// The right model is typically ≥0.85 confident; wrong ones produce little
/// text or score well below that.
enum LanguageDetector {
    struct Candidate {
        let lang: Lang
        let confidence: Double
        let chars: Int
        let text: String
        let score: Double
    }

    static func rank(_ clip: [AVAudioPCMBuffer], candidates: [Lang]) async -> [Candidate] {
        await withTaskGroup(of: Candidate?.self) { group in
            for lang in candidates {
                group.addTask { await evaluate(clip, lang: lang) }
            }
            var out: [Candidate] = []
            for await c in group { if let c { out.append(c) } }
            return out.sorted { $0.score > $1.score }
        }
    }

    private static func evaluate(_ clip: [AVAudioPCMBuffer], lang: Lang) async -> Candidate? {
        guard let heard = await Recognition.transcribe(clip, locale: lang.locale) else { return nil }
        return Candidate(lang: lang, confidence: heard.confidence, chars: heard.letters, text: heard.text,
                         score: score(conf: heard.confidence, chars: heard.letters, text: heard.text, lang: lang))
    }

    /// A clip in which no model wrote more than a short word (the room before anyone speaks, a
    /// cough, a two-character fragment of a sentence) says nothing about the language. Counted as
    /// unsure, two of them held a room's lines, and one between two sure answers kept them held:
    /// a table speaking short Chinese sentences lost a whole meeting that way.
    static func saysNothing(_ ranked: [Candidate]) -> Bool {
        ranked.count >= 2 && ranked.allSatisfy { $0.chars <= 3 }
    }

    static func score(conf: Double, chars: Int, text: String, lang: Lang) -> Double {
        guard chars > 0 else { return 0 }
        // Very short output means the model mostly heard noise.
        let lengthFactor = min(1.0, Double(chars) / 6.0)
        // A CJK model that mostly writes Latin letters is transcribing a foreign language.
        var scriptFactor = 1.0
        if ["ja", "zh-CN", "ko"].contains(lang.code) {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let latin = letters.filter { $0.isASCII }.count
            if !letters.isEmpty, Double(latin) / Double(letters.count) > 0.5 { scriptFactor = 0.75 }
        }
        return conf * lengthFactor * scriptFactor
    }
}


// MARK: - What detection has settled

/// Where "auto" stands on the meeting's language, and when to check it again. Pure: `ListenEngine`
/// runs the checks and acts on each `Decision`.
struct LanguageDetection {
    enum Verdict: Equatable {
        /// Not settled yet: lines are held until it is (or 听不出 asks).
        case unknown
        /// The model checked says the audio isn't its language: what it writes is noise, neither
        /// shown nor kept, until another model or a pick settles it.
        case notThis
        case confirmed
    }

    /// What a check's answer asks the engine to do.
    enum Decision: Equatable {
        /// Nothing new to show (the clip had no words, or one sure answer after a no).
        case none
        /// The one model there is says it isn't its language (`firstTime`: just now).
        case notThis(Lang, firstTime: Bool)
        /// Every model unsure (`now`: the second time in a row, lines held from here).
        case noneOfThem(now: Bool)
        /// Too close to call: the language stays as it is.
        case ambiguous
        /// The language listened in is right.
        case confirmed(Lang)
        /// Another language, sure enough to switch to; `replayAll` replays all speech held back.
        case switchTo(Lang, replayAll: Bool)
        /// Another language once: switched to if the next check agrees.
        case pending(Lang)
    }

    private(set) var verdict = Verdict.unknown
    /// A language one check preferred, switched to if the next check agrees.
    private(set) var pendingSwitch: Lang?
    /// A check is due (a pause, 20 s more speech, a new model, Latin letters from a CJK model).
    var due = true
    /// A check is running.
    private(set) var checking = false
    private(set) var lastCheckAt = Date.distantPast
    /// Voiced seconds after which the next periodic check is due.
    var nextPeriodic = 30.0
    /// Checks too close to call: two of them and the lines are kept anyway.
    private(set) var ambiguous = 0
    private var unsureStreak = 0
    private var sureStreak = 0

    var confirmed: Bool { verdict == .confirmed }
    var mismatch: Bool { verdict == .notThis }
    /// Lines may be written down even though nothing is confirmed.
    var settledEnough: Bool { confirmed || (ambiguous >= 2 && !mismatch) }

    /// A new run.
    mutating func start() { self = LanguageDetection() }

    /// 自动 turned on or off: whatever was known is for the old setting.
    mutating func modeChanged() {
        verdict = .unknown
        pendingSwitch = nil
        due = true
    }

    /// 重新识别: ask again from scratch (a no from the one model stands until another answer).
    mutating func redetect() {
        if verdict == .confirmed { verdict = .unknown }
        pendingSwitch = nil
        due = true
        ambiguous = 0
        unsureStreak = 0
        sureStreak = 0
        lastCheckAt = .distantPast
    }

    /// A background model download ended: a new model gets its say.
    mutating func modelFetched(ok: Bool) {
        if ok { clearMismatch(); unsureStreak = 0; sureStreak = 0 }
        due = true
    }

    /// Listening moved to another language (or to a service): the old model's no is moot.
    mutating func clearMismatch() { if verdict == .notThis { verdict = .unknown } }

    /// Unsure again (the model for it couldn't be had, or a pick to redo). A no stands.
    mutating func unconfirm() { if verdict == .confirmed { verdict = .unknown } }

    /// Known by other means: back from a service that heard the language, a debug run.
    mutating func setConfirmed(_ on: Bool) { if on { verdict = .confirmed } else { unconfirm() } }

    /// Picked from 听不出.
    mutating func picked() {
        verdict = .confirmed
        pendingSwitch = nil
        due = false
        unsureStreak = 0
        sureStreak = 0
    }

    mutating func checkStarted(at now: Date = Date()) {
        due = false
        lastCheckAt = now
        checking = true
    }

    mutating func checkEnded() { checking = false }

    /// A check's models ranked best first, heard while listening in `active`.
    mutating func apply(_ ranked: [LanguageDetector.Candidate], active: Lang?) -> Decision {
        guard let best = ranked.first else { return .none }
        if LanguageDetector.saysNothing(ranked) {
            if !confirmed || mismatch { due = true }
            return .none
        }
        if ranked.count == 1 {
            // The right model is ≥0.85 sure; English heard by a French model scored 0.12.
            guard best.lang == active, best.confidence >= 0.6, best.score >= 0.6 else {
                // A confirmed language stands: one answer while confirmed is a check whose other
                // models failed (`rank` drops them), not the one model there is saying no.
                if confirmed { return .none }
                // Asked again only by the usual triggers (a pause, 20 s more speech), or when a model arrives.
                let first = !mismatch
                verdict = .notThis
                return .notThis(best.lang, firstTime: first)
            }
            clearMismatch()
        }
        // Every model unsure: a language with no model here, not a close call. On their own language
        // English scored 0.95, Chinese 0.84, Korean 0.97; Japanese heard by the Chinese model 0.66,
        // German and Spanish heard by English or Chinese at most 0.48.
        // Twice in a row, so one noisy clip doesn't ask; nothing is kept meanwhile.
        if ranked.count >= 2, best.score < 0.72 {
            unsureStreak += 1
            sureStreak = 0
            var now = false
            if unsureStreak >= 2, verdict == .unknown {
                verdict = .notThis
                now = true
            }
            if !confirmed { due = true }
            return .noneOfThem(now: now)
        }
        unsureStreak = 0
        // Said no once: Japanese heard by the Chinese model reached 0.73 now and then, so one sure
        // answer doesn't take it back; two in a row do.
        if mismatch, ranked.count >= 2 {
            sureStreak += 1
            if sureStreak < 2 {
                due = true
                return .none
            }
        }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        guard best.confidence >= 0.6, best.score - runnerUp >= 0.08 else {
            ambiguous += 1
            if !confirmed { due = true }
            return .ambiguous
        }
        if best.lang == active {
            verdict = .confirmed
            pendingSwitch = nil
            return .confirmed(best.lang)
        }
        let currentScore = ranked.first(where: { $0.lang == active })?.score ?? 0
        let overwhelming = best.score - currentScore >= 0.30
        if !confirmed || overwhelming || pendingSwitch == best.lang {
            // The first answer replays everything held back; a later switch, the last sentence or so.
            let replayAll = !confirmed
            verdict = .confirmed
            pendingSwitch = nil
            return .switchTo(best.lang, replayAll: replayAll)
        }
        pendingSwitch = best.lang
        due = true
        return .pending(best.lang)
    }
}
