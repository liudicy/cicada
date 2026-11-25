import AVFoundation
import AudioToolbox
import CoreMedia
import Speech
import Translation

// MARK: - Translation

enum TranslateFailure: Error {
    case badURL
    case badResponse(Int)
    case parse
    case empty
}

struct GoogleTranslator {
    static func translate(_ text: String, source: String, target: String) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = comps.url else { throw TranslateFailure.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Cicada/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TranslateFailure.parse }
        guard http.statusCode == 200 else { throw TranslateFailure.badResponse(http.statusCode) }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [Any],
            let segments = root.first as? [Any]
        else { throw TranslateFailure.parse }
        let result = segments.compactMap { seg -> String? in
            guard let arr = seg as? [Any], let s = arr.first as? String else { return nil }
            return s
        }.joined()
        guard !result.isEmpty else { throw TranslateFailure.empty }
        return result
    }
}


/// Whether Google is worth asking. Two network errors or timeouts in a row (in China, usually no
/// proxy) mark it down for a minute: partial text, refreshed every second, would otherwise wait out
/// the 8 s timeout each time. After the minute one call goes through again; a success or a change
/// of network brings it straight back. A 429 only pauses it 10 s and never counts as down.
struct GoogleHealth {
    static let downAfter = 2
    static let pause: TimeInterval = 60
    private(set) var failures = 0
    private(set) var until = Date.distantPast
    private(set) var down = false

    func open(_ now: Date = Date()) -> Bool { now >= until }

    mutating func succeeded() { failures = 0; until = .distantPast; down = false }

    mutating func unreachable(_ now: Date = Date()) {
        failures += 1
        if failures >= Self.downAfter { down = true; until = now.addingTimeInterval(Self.pause) }
    }

    mutating func rateLimited(_ now: Date = Date()) { until = now.addingTimeInterval(10) }

    /// A proxy turned on, Wi-Fi back: try again now, still down until it answers.
    mutating func networkChanged() { until = .distantPast }
}

/// What the user is told about translation, without naming providers: Google down, and whether
/// finished sentences are going untranslated too (no key, and no on-device model to stand in).
struct TranslationHealth: Equatable {
    var googleDown = false
    /// 语音和文字只发给你的服务: Google is left out on purpose, so nothing says it can't be reached.
    var googleOff = false
    var sentencesUntranslated = false
    var proxy: AICheck.ProxyHint?
}

// MARK: - Translation chain

/// Ling (with a key) → Google → Apple's on-device translation.
/// Finished sentences and speak-back go to Ling, which keeps names consistent through a glossary
/// taken from the meeting notes. Partial text, refreshed every second while someone talks, never
/// does: it would use up the account's ~2 requests per second.
@MainActor
final class TranslationService {
    /// `file`: a line of an imported recording, sent to Ling behind everything live.
    enum Kind { case draft, sentence, speak, file }

    let ling: LingClient
    /// Names and terms the notes have settled on, e.g. "江充 (Jiang Chong)".
    var glossary: () -> [String] = { [] }

    /// What a finished sentence's request carries so the service can also point out misheard words
    /// (改正听错的词). nil: fixing is off, and the request is the plain translation it always was.
    struct FixContext {
        /// The meeting's title once it has one: the field tells "质押" from "制约".
        var topic: String?
        /// The user's word list (`Vocabulary.promptLines`).
        var words: [String]
        /// The lines just before, as shown.
        var recent: [String]
        /// On a second pass: the lines after it, which often tell what a word was.
        var following: [String] = []
        /// The notes' summary so far, once there is one.
        var summary: String? = nil
    }
    var fixContext: ((_ text: String) -> FixContext?)?
    /// The fixes the service proposed for a sentence it translated (by its text as heard).
    var onFixes: ((_ text: String, _ edits: [Correction.Edit]) -> Void)?
    private var google = GoogleHealth()
    private(set) var health = TranslationHealth() {
        didSet { if health != oldValue { onHealth?(health) } }
    }
    /// Set by the app: the banner and settings show `health`.
    var onHealth: ((TranslationHealth) -> Void)?
    /// Set by the app: reads the proxy settings once Google goes down, to word the hint.
    var proxyHint: (() async -> AICheck.ProxyHint)?
    private var lastUnreachableTry = Date.distantPast

    /// A service that answers nothing (a home server switched off) costs every line its timeout
    /// before Google gets it, so subtitles run seconds late. While the check says unreachable, one
    /// line in 15 s still goes to it, so a server that is back is noticed without waiting for a check.
    private func lingWorthTrying() -> Bool {
        guard ling.aiCheck.failure?.reason == .unreachable else { return true }
        guard Date().timeIntervalSince(lastUnreachableTry) >= 15 else { return false }
        lastUnreachableTry = Date()
        return true
    }

    init(ling: LingClient) { self.ling = ling }

    /// Debug (`googleDown:on`): Google fails as if there were no proxy, without touching the network.
    var simulateGoogleDown = false

    /// Set by the app (语音和文字只发给你的服务, custom service only): Google is never asked, so the
    /// text stays with the user's service and this Mac. A stale "can't reach Google" goes with it.
    var googleOff = false {
        didSet {
            guard googleOff != oldValue else { return }
            google = GoogleHealth()
            health = TranslationHealth(googleOff: googleOff)
        }
    }

    func networkChanged() { google.networkChanged() }

    private func googleAnswered() {
        google.succeeded()
        health.googleDown = false
        health.proxy = nil
    }

    private func googleUnreachable() {
        let was = google.down
        google.unreachable()
        guard google.down, !was else { return }
        debugLog("translate google down: paused \(Int(GoogleHealth.pause)) s")
        health.googleDown = true
        if let proxyHint {
            Task { let hint = await proxyHint(); if self.health.googleDown { self.health.proxy = hint } }
        }
    }

    /// `trace`, when given, collects which providers were tried, how long each took and why it
    /// fell through (diagnostics; never the text).
    /// Debug (`translateFail:<n>`): the next n sentences fail on every provider, to test the retry.
    var failNext = 0

    /// Partial text (`.draft`) has no trace: each one reports here instead (seconds, answered), so
    /// diagnostics can count them without a line per refresh.
    var onDraft: ((Double, Bool) -> Void)?

    func translate(_ text: String, source: String, target: String, kind: Kind, trace: TranslateTrace? = nil) async -> String? {
        if source == target { return text }
        // Partial text only ever goes to Google: left out, it shows the original until the sentence ends.
        if kind == .draft, googleOff { return nil }
        if kind == .draft, let onDraft {
            let started = Date()
            let out = await chain(text, source: source, target: target, kind: kind, trace: trace)
            onDraft(Date().timeIntervalSince(started), out != nil)
            return out
        }
        let out = await chain(text, source: source, target: target, kind: kind, trace: trace)
        if kind == .sentence { health.sentencesUntranslated = out == nil }
        return out
    }

    private func chain(_ text: String, source: String, target: String, kind: Kind, trace: TranslateTrace?) async -> String? {
        if kind == .sentence, failNext > 0 {
            failNext -= 1
            trace?.attempts.append(.init(provider: ling.provider.id.rawValue, seconds: 0, failure: "simulated"))
            return nil
        }
        if kind != .draft, ling.usable, lingWorthTrying() {
            let started = Date()
            let (out, failure) = await viaLing(text, source: source, target: target, kind: kind, trace: trace)
            trace?.attempts.append(.init(provider: ling.provider.id.rawValue, seconds: Date().timeIntervalSince(started),
                                         failure: out == nil ? failure : nil))
            if let out {
                debugLog("translate via=\(ling.provider.id.rawValue) kind=\(kind)")
                return out
            }
        }
        if googleOff {
            // Left out on purpose: no attempt in the trace, so diagnostics don't show Google failing.
        } else if google.open() {
            let started = Date()
            do {
                if simulateGoogleDown { throw URLError(.cannotConnectToHost) }
                let out = try await GoogleTranslator.translate(text, source: source, target: target)
                trace?.attempts.append(.init(provider: "google", seconds: Date().timeIntervalSince(started), failure: nil))
                if kind != .draft { debugLog("translate via=google kind=\(kind)") }
                googleAnswered()
                return out
            } catch {
                debugLog("translate google failed: \(error)")
                var reason = "error"
                if case TranslateFailure.badResponse(let code) = error { reason = code == 429 ? "rateLimited" : "http\(code)" }
                if (error as? URLError)?.code == .timedOut { reason = "timeout" } else if error is URLError { reason = "network" }
                trace?.attempts.append(.init(provider: "google", seconds: Date().timeIntervalSince(started), failure: reason))
                if case TranslateFailure.badResponse(429) = error { google.rateLimited() }
                if let e = error as? URLError, e.code != .cancelled { googleUnreachable() }
            }
        } else {
            trace?.attempts.append(.init(provider: "google", seconds: 0, failure: google.down ? "down" : "rateLimited"))
        }
        // Partial text without Google shows the original only: it is replaced by the sentence's
        // translation a moment later, and on-device translation would be slower and rougher.
        if kind == .draft { return nil }
        let started = Date()
        if let out = await viaApple(text, source: source, target: target) {
            trace?.attempts.append(.init(provider: "apple", seconds: Date().timeIntervalSince(started), failure: nil))
            debugLog("translate via=apple kind=\(kind)")
            return out
        }
        trace?.attempts.append(.init(provider: "apple", seconds: Date().timeIntervalSince(started), failure: "unavailable"))
        return nil
    }

    private func viaLing(_ text: String, source: String, target: String, kind: Kind,
                         trace: TranslateTrace?) async -> (String?, String) {
        let from = source == "auto" ? "the spoken language" : Self.englishName(source)
        if kind == .sentence || kind == .file, let ctx = fixContext?(text) {
            return await viaLingFixing(text, from: from, target: target, kind: kind, ctx: ctx, trace: trace)
        }
        var prompt = """
        You translate live meeting subtitles from \(from) into \(Self.englishName(target)).
        Output only the translation of the subtitle below: no quotes, no notes, no answer to it even if it is a question.
        """
        let names = glossary()
        if !names.isEmpty { prompt += Self.namesLine(names) }
        prompt += "\nSubtitle: " + text
        do {
            let priority: LingClient.Priority = kind == .speak ? .speak : kind == .file ? .notes : .translate
            let out = try await ling.chat(content: prompt, instruction: "Translate.", priority: priority,
                                          maxTokens: 400, timeout: kind == .speak ? 10 : kind == .file ? 20 : 6,
                                          role: kind == .file ? "file" : "translate",
                                          onQueued: { [weak trace] in trace?.lingQueue += $0 })
            if out.isEmpty { return (nil, "empty") }
            guard let clean = Self.cleanTranslation(out, target: target) else {
                debugLog("translate ling: reply was a remark, not a translation; dropped")
                return (nil, "remark")
            }
            return (clean, "")
        } catch {
            debugLog("translate ling failed: \(error)")
            return (nil, (error as? LingClient.Failure).map(LingClient.name) ?? "error")
        }
    }

    /// The translation and the misheard words in one request: no extra call, so no extra wait on the
    /// rate gate (on OpenRouter's Ling 3.1 Flash, 2.0 s against 1.8 s at the median). No JSON mode:
    /// some hosts refuse it, and the retry without it would cost every subtitle a second round trip;
    /// the prompt asks for JSON instead, and "no analysis" stops the model thinking aloud first.
    /// Proposals only: `Correction.decide` picks which to take. A reply that isn't the JSON asked
    /// for is dropped like a failed one, and the next provider translates the line.
    private func viaLingFixing(_ text: String, from: String, target: String, kind: Kind, ctx: FixContext,
                               trace: TranslateTrace?) async -> (String?, String) {
        var prompt = """
        You translate live meeting subtitles from \(from) into \(Self.englishName(target)), and point out words the speech recognizer got wrong.
        Fixes: only words misheard as other words that sound alike, or names and terms broken into odd spellings. Never rephrase, drop filler, reorder or add anything. If unsure, leave it.
        Translate the subtitle as fixed. No answer to it even if it is a question.
        confidence is how likely a fix is right; give a guess a low one. Leave out words you would not change.
        Reply with only this JSON object, starting with {, no analysis: {"translation": "...", "fixes": [{"from": "exact words from the subtitle", "to": "what was said", "confidence": 0.0-1.0}]}
        """
        if let topic = ctx.topic, !topic.isEmpty { prompt += "\nMeeting: " + topic }
        if !ctx.words.isEmpty { prompt += "\nThe user's word list (spellings to use): " + ctx.words.joined(separator: "; ") }
        let names = glossary()
        if !names.isEmpty { prompt += "\nNames the notes guessed (not confirmed): " + names.joined(separator: "; ") }
        if let summary = ctx.summary, !summary.isEmpty { prompt += "\nThe meeting so far: " + summary }
        if !ctx.recent.isEmpty { prompt += "\nLines just before:\n" + ctx.recent.joined(separator: "\n") }
        if !ctx.following.isEmpty { prompt += "\nLines just after:\n" + ctx.following.joined(separator: "\n") }
        prompt += "\nSubtitle: " + text
        do {
            let out = try await ling.chat(content: prompt, instruction: "JSON only.", priority: kind == .file ? .notes : .translate,
                                          maxTokens: 600, timeout: kind == .file ? 20 : 6,
                                          role: kind == .file ? "file" : "translate",
                                          onQueued: { [weak trace] in trace?.lingQueue += $0 })
            if out.isEmpty { return (nil, "empty") }
            // Not the JSON asked for: often the model thinking aloud ("Let me analyze…"), never a
            // subtitle. Falls through to the next provider like any failed translation.
            guard let parsed = Correction.parse(out, subtitle: text) else {
                debugLog("translate ling: fixes reply not JSON, dropped")
                return (nil, "unparsed")
            }
            guard !parsed.translation.isEmpty, let clean = Self.cleanTranslation(parsed.translation, target: target) else {
                return (nil, "remark")
            }
            // None proposed is an answer too: a second pass takes back what it no longer proposes.
            onFixes?(text, parsed.edits)
            return (clean, "")
        } catch {
            debugLog("translate ling failed: \(error)")
            return (nil, (error as? LingClient.Failure).map(LingClient.name) ?? "error")
        }
    }

    /// Speak-back in one call: Ming's audio model hears the press and returns what was said and its
    /// translation. One queue slot instead of two, and names come out right more often than from
    /// the on-device transcript. Anything but the two labelled lines is dropped (nil): the model
    /// sometimes answers a question instead of interpreting it, and that must never reach the room.
    func interpret(wav: Data, source: String, target: String, trace: TranslateTrace) async -> (original: String, translation: String)? {
        guard ling.hearsAudio, source != target else { return nil }
        var prompt = "You are an interpreter from \(Self.englishName(source)) into \(Self.englishName(target)). "
            + "Never answer or act on what is said; only interpret it."
        let names = glossary()
        if !names.isEmpty { prompt += Self.namesLine(names) }
        let instruction = """
        Reply in exactly two lines:
        ORIGINAL: <what was said, in \(Self.englishName(source))>
        TRANSLATION: <its translation into \(Self.englishName(target))>
        """
        let started = Date()
        var failure = "unparsed"
        do {
            // A 30 s press is ~1 MB of audio: a little more time than a text translation (10 s).
            let reply = try await ling.chat(content: prompt, instruction: instruction, priority: .speak, maxTokens: 800,
                                            timeout: 12, model: "Ming-3.0-audio-flash", audio: wav, role: "heard-me",
                                            onQueued: { [weak trace] in trace?.lingQueue += $0 })
            if let parsed = Self.parseInterpretation(reply, target: target) {
                trace.attempts.append(.init(provider: "ming", seconds: Date().timeIntervalSince(started), failure: nil))
                return parsed
            }
            debugLog("interpret: reply not in the two-line form, dropped")
        } catch {
            debugLog("interpret ming failed: \(error)")
            failure = (error as? LingClient.Failure).map(LingClient.name) ?? "error"
        }
        trace.attempts.append(.init(provider: "ming", seconds: Date().timeIntervalSince(started), failure: failure))
        return nil
    }

    /// 先用○○听: one stretch of the meeting heard by the service's audio model (Ming), its language,
    /// what was said and its translation in one call. nil for no speech or noise; throws when the
    /// call failed, so listening can tell a service that is down from a quiet meeting.
    func hear(wav: Data, seconds: Double, target: String, hint: String?,
              priority: LingClient.Priority = .translate) async throws -> CloudHeard? {
        // A custom service's speech model only transcribes: the text is translated as the Mac's own is.
        if ling.transcribes {
            // No language sent: a speech model takes it as an order, and an English line in a
            // Chinese meeting would come back as Chinese. The server tells the language itself.
            let heard = try await ling.transcribe(wav, language: nil)
            return CloudHearing.transcript(heard.text, reported: heard.language, hint: hint, target: target, seconds: seconds)
        }
        guard ling.hearsAudio else { throw LingClient.Failure.noKey }
        let reply = try await ling.chat(content: CloudHearing.prompt(target: target, hint: hint, names: glossary()),
                                        instruction: CloudHearing.instruction(target: target), priority: priority,
                                        maxTokens: CloudHearing.tokens(seconds: seconds), timeout: 12,
                                        model: "Ming-3.0-audio-flash", audio: wav, role: "heard-them")
        return CloudHearing.parse(reply, target: target, hint: hint, seconds: seconds)
    }

    /// `ORIGINAL: …` then `TRANSLATION: …`, both non-empty, and the translation in the target's
    /// script (Chinese/Japanese targets need CJK, others must not be mostly CJK).
    static func parseInterpretation(_ reply: String, target: String) -> (original: String, translation: String)? {
        var original: String?, translation: String?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("ORIGINAL:") {
                original = String(line.dropFirst("ORIGINAL:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.uppercased().hasPrefix("TRANSLATION:") {
                translation = String(line.dropFirst("TRANSLATION:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let o = original, let t = translation, !o.isEmpty, !t.isEmpty, o != t else { return nil }
        let letters = t.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = ["zh", "ja", "ko"].contains(where: { target.hasPrefix($0) })
        if wantsCJK ? cjk == 0 : cjk * 2 > letters.count { return nil }
        return (o, t)
    }

    /// "Translate." in each target language, letters only and lowercased.
    nonisolated static let instructionEchoes: Set<String> = [
        "翻译", "翻譯", "translate", "翻訳", "翻訳して", "翻訳する", "翻訳してください", "번역", "번역해", "번역하세요", "번역해주세요",
        "traducir", "traduce", "traduzca", "traduire", "traduisez", "traduis", "übersetzen", "übersetze", "traduzir", "traduza",
    ]

    /// Ling sometimes comments on a garbled subtitle ("The subtitle appears to be… Here is the
    /// best-effort translation:") instead of translating it, and that would land in the subtitles and
    /// the record. Remark lines are dropped, a "Translation:" label is stripped, and what is left must
    /// be in the target's script; nil means the next provider translates it.
    nonisolated static func cleanTranslation(_ reply: String, target: String) -> String? {
        // A line is a remark only when it opens or ends like one and talks about the job itself,
        // so a subtitle that happens to start with "The text…" is kept.
        let opener = ["here is", "here's", "the subtitle", "this subtitle", "the text", "this text", "the original",
                      "the user", "note", "(note", "i'm sorry", "i am sorry", "sorry", "it seems", "it appears", "this appears"]
        let about = ["translat", "subtitle", "garbled", "transcri", "asr", "speech recognition", "best-effort"]
        // The same in Chinese: "请提供需要翻译的字幕内容", "您似乎忘记提供……".
        let zhAbout = ["字幕", "翻译"], zhRemark = ["请提供", "似乎", "看起来", "无法", "乱码", "没有附上", "您只发送"]
        // Reasoning that leaked into the reply ("…</think>") goes; the answer follows it.
        let answer = reply.components(separatedBy: "</think>").last ?? reply
        var kept: [String] = []
        for raw in answer.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            let remark = (opener.contains(where: { lower.hasPrefix($0) }) || line.hasSuffix(":") || line.hasSuffix("："))
                && about.contains(where: { lower.contains($0) })
                || zhAbout.contains(where: { line.contains($0) }) && zhRemark.contains(where: { line.contains($0) })
            if lower.hasPrefix("translation:") {
                line = String(line.dropFirst("translation:".count)).trimmingCharacters(in: .whitespaces)
            } else if remark {
                // A note after the translation ("(Note: …" and its list of other wordings) ends it.
                if !kept.isEmpty { break }
                continue
            }
            if !line.isEmpty { kept.append(line) }
        }
        var out = kept.joined(separator: " ")
        // Quotes come off only when they wrap the whole reply; a closing ” inside it belongs to the text.
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")]
        where out.count >= 2 && out.hasPrefix(open) && out.hasSuffix(close) && out.dropFirst().dropLast().contains(open) == false {
            out = String(out.dropFirst().dropLast())
        }
        out = out.trimmingCharacters(in: .whitespaces)
        guard !out.isEmpty else { return nil }
        // Ling translated the fixed "Translate." instruction instead of the subtitle ("翻译。" for an
        // empty subtitle, or for "Translate this into Chinese please."). A subtitle that really is
        // just "翻译一下" loses Ling's answer too, and the next provider translates it.
        if Self.instructionEchoes.contains(String(out.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic })) { return nil }
        let letters = out.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = ["zh", "ja", "ko"].contains(where: { target.hasPrefix($0) })
        if !letters.isEmpty, wantsCJK ? cjk == 0 : cjk * 2 > letters.count { return nil }
        return out
    }

    /// Apple's on-device translation, made outside a SwiftUI view: only on macOS 26.
    private func viaApple(_ text: String, source: String, target: String) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        guard source != "auto" else { return nil }
        let from = Locale.Language(identifier: Self.appleCode(source))
        let to = Locale.Language(identifier: Self.appleCode(target))
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return nil }
        do {
            let session = TranslationSession(installedSource: from, target: to)
            return try await session.translate(text).targetText
        } catch {
            debugLog("translate apple failed: \(error)")
            return nil
        }
    }

    private static func appleCode(_ code: String) -> String {
        switch code {
        case "zh-CN": "zh-Hans"
        case "zh-TW": "zh-Hant"
        default: code
        }
    }

    /// The notes' names for a request. Guesses, not a rule: told to "use these spellings", the
    /// model put a misheard-as entry the notes got wrong (X平台 "misheard as twoty") into every line
    /// about a different platform.
    nonisolated static func namesLine(_ names: [String]) -> String {
        "\nNames the notes guessed (spellings to use; a misheard form only where it plainly means that name): " + names.joined(separator: "; ")
    }

    nonisolated static func englishName(_ code: String) -> String {
        switch code {
        case "zh-CN": "Simplified Chinese"
        case "zh-TW": "Traditional Chinese"
        default: Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }
}
