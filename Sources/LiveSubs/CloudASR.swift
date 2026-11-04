import Foundation

/// Cloud speech recognition for proofreading: after the on-device SpeechAnalyzer finishes a
/// sentence, its audio goes to an OpenAI-compatible multimodal endpoint (preset: Xiaomi MiMo
/// ASR) and the returned text replaces the transcript line. The on-device recognizer still drives
/// the live subtitles and sentence breaks — the cloud pass only makes the record more accurate.
///
/// The MiMo preset follows its docs: chat/completions with an `input_audio` part (WAV, base64,
/// ≤ 10 MB), `asr_options.language` one of auto/zh/en, and the key in an `api-key` header.
/// Not the shared LingClient: a sentence can cost a second or two and must not hold up
/// translation or notes, so this runs on its own serial queue with its own key.
@MainActor
final class CloudASRClient: ObservableObject {
    static let defaultBase = "https://api.xiaomimimo.com/v1"
    static let defaultModel = "mimo-v2.5-asr"

    enum Failure: Error, Equatable {
        case noKey, invalidKey, http(Int), network, parse, busy
    }

    var base: () -> String = { defaultBase }
    var model: () -> String = { defaultModel }

    var key: String? { AIKey.read("asr") }
    var hasKey: Bool { key != nil }

    /// One sentence at a time, in order; a slow request must not pile up behind live speech.
    private var running = false

    func setKey(_ raw: String) {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        AIKey.save(k, provider: "asr")
    }

    func removeKey() { AIKey.remove("asr") }

    /// The sentence's audio (16 kHz mono) and the on-device language guess; returns the cloud
    /// transcript, or throws (the caller keeps the on-device text).
    func transcribe(samples: [Float], language: String) async throws -> String {
        guard let key else { throw Failure.noKey }
        guard !running else { throw Failure.busy }
        running = true
        defer { running = false }
        let wav = Self.wav(samples)
        let body: [String: Any] = [
            "model": model(),
            "messages": [[
                "role": "user",
                "content": [["type": "input_audio",
                             "input_audio": ["data": "data:audio/wav;base64," + wav.base64EncodedString()]]],
            ]],
            "asr_options": ["language": Self.asrLanguage(language)],
        ]
        guard let baseURL = URL(string: base().hasSuffix("/") ? base() : base() + "/") else { throw Failure.network }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        // MiMo's docs use `api-key`; OpenAI-compatible gateways expect the Bearer header. Send both.
        req.setValue(key, forHTTPHeaderField: "api-key")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        let started = Date()
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            debugLog("asr: network error \(error.localizedDescription)")
            throw Failure.network
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403: throw Failure.invalidKey
        case let code: debugLog("asr: HTTP \(code)"); throw Failure.http(code)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw Failure.parse }
        debugLog("asr: ok \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(samples.count / 16) ms of audio")
        return text
    }

    /// MiMo's asr_options.language; anything it does not know falls back to auto.
    static func asrLanguage(_ locale: String) -> String {
        if locale.hasPrefix("zh") { return "zh" }
        if locale.hasPrefix("en") { return "en" }
        return "auto"
    }

    /// 16 kHz mono 16-bit WAV, the same encoding SpeakEngine sends to Ming (SpeakTest.wav).
    static func wav(_ samples: [Float]) -> Data {
        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767)
            pcm.append(Data(bytes: &v, count: 2))
        }
        var data = Data()
        let byteRate = UInt32(16000 * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + pcm.count)); data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1); u32(16000); u32(byteRate); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
