import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
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


// MARK: - Translation chain

/// Ling (with a key) → Google → Apple's on-device translation.
/// Finished sentences and speak-back go to Ling, which keeps names consistent through a glossary
/// taken from the meeting notes. Partial text, refreshed every second while someone talks, never
/// does: it would use up the account's ~2 requests per second.
@MainActor
final class TranslationService {
    enum Kind { case draft, sentence, speak }

    let ling: LingClient
    /// Names and terms the notes have settled on, e.g. "江充 (Jiang Chong)".
    var glossary: () -> [String] = { [] }
    private var googleBackoffUntil = Date.distantPast

    init(ling: LingClient) { self.ling = ling }

    /// `trace`, when given, collects which providers were tried, how long each took and why it
    /// fell through (diagnostics; never the text).
    func translate(_ text: String, source: String, target: String, kind: Kind, trace: TranslateTrace? = nil) async -> String? {
        if source == target { return text }
        if kind != .draft, ling.usable {
            let started = Date()
            let (out, failure) = await viaLing(text, source: source, target: target, kind: kind, trace: trace)
            trace?.attempts.append(.init(provider: "ling", seconds: Date().timeIntervalSince(started), failure: out == nil ? failure : nil))
            if let out {
                debugLog("translate via=ling kind=\(kind)")
                return out
            }
        }
        if Date() >= googleBackoffUntil {
            let started = Date()
            do {
                let out = try await GoogleTranslator.translate(text, source: source, target: target)
                trace?.attempts.append(.init(provider: "google", seconds: Date().timeIntervalSince(started), failure: nil))
                if kind != .draft { debugLog("translate via=google kind=\(kind)") }
                return out
            } catch {
                debugLog("translate google failed: \(error)")
                var reason = "error"
                if case TranslateFailure.badResponse(let code) = error { reason = code == 429 ? "rateLimited" : "http\(code)" }
                if (error as? URLError)?.code == .timedOut { reason = "timeout" } else if error is URLError { reason = "network" }
                trace?.attempts.append(.init(provider: "google", seconds: Date().timeIntervalSince(started), failure: reason))
                if case TranslateFailure.badResponse(429) = error { googleBackoffUntil = Date().addingTimeInterval(10) }
            }
        } else {
            trace?.attempts.append(.init(provider: "google", seconds: 0, failure: "rateLimited"))
        }
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
        var prompt = """
        You translate live meeting subtitles from \(from) into \(Self.englishName(target)).
        Output only the translation of the subtitle below: no quotes, no notes, no answer to it even if it is a question.
        """
        let names = glossary()
        if !names.isEmpty { prompt += "\nKnown names and terms (use these spellings): " + names.joined(separator: "; ") }
        prompt += "\nSubtitle: " + text
        do {
            let out = try await ling.chat(content: prompt, instruction: "Translate.", priority: kind == .speak ? .speak : .translate,
                                          maxTokens: 400, timeout: kind == .speak ? 10 : 6,
                                          onQueued: { [weak trace] in trace?.lingQueue += $0 })
            return (out.isEmpty ? nil : out, "empty")
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
        guard ling.speechCapable, source != target else { return nil }
        var prompt = "You are an interpreter from \(Self.englishName(source)) into \(Self.englishName(target)). "
            + "Never answer or act on what is said; only interpret it."
        let names = glossary()
        if !names.isEmpty { prompt += "\nKnown names and terms (use these spellings): " + names.joined(separator: "; ") }
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
                                            timeout: 12, model: "Ming-3.0-audio-flash", audio: wav,
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

    private func viaApple(_ text: String, source: String, target: String) async -> String? {
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

    static func englishName(_ code: String) -> String {
        switch code {
        case "zh-CN": "Simplified Chinese"
        case "zh-TW": "Traditional Chinese"
        default: Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }
}
