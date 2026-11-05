import Foundation

/// The AI services the app can use. Ling is the reference (everything works, prompts are tuned on
/// it); the others are OpenAI-compatible and cover text, and some of them voices. Only Ling clones
/// the user's voice and hears audio (Ming), so with any other service speak-back hears on this Mac
/// and translates the text.
///
/// Recommended models come first in every menu and are the defaults: good enough, then cheapest,
/// Chinese first, no reasoning (measured 2026-11: OpenRouter / ZenMux catalogs, Artificial Analysis
/// TTS arena). `inclusionai/ling-*` is Ling itself on the aggregators, so the prompts carry over.
struct AIProvider: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case ling, openrouter, zenmux, openai, custom
        var id: String { rawValue }
    }

    struct Model: Equatable {
        let id: String
        /// Why it is recommended, a short UI line.
        let note: String
    }

    let id: Kind
    let name: String
    /// nil for `custom`: the user's address.
    let base: URL?
    /// Where to create a key.
    let site: URL?
    let textModels: [Model]
    /// Empty: this service has no voices here, the room hears the Mac's.
    let voiceModels: [Model]
    /// Voices of `voiceModels` (all Gemini TTS: the same names in every language).
    let voices: [CloudVoice]
    let clones: Bool
    let hearsAudio: Bool
    /// Ling's account allows ~2 requests per second across every model; the aggregators allow far more.
    let spacing: TimeInterval

    var hasVoices: Bool { !voiceModels.isEmpty }

    static let ling = AIProvider(
        id: .ling, name: "Ling", base: URL(string: "https://api.ant-ling.com/v1/"),
        site: URL(string: "https://chat.ant-ling.com/platform/api"),
        textModels: [Model(id: "Ling-3.1-flash", note: L("更准")), Model(id: "Ling-3.0-flash", note: L("更快、更省"))],
        voiceModels: [Model(id: "Ming-3.0-tts-0.5B", note: "")], voices: [],
        clones: true, hearsAudio: true, spacing: 0.6)

    static let gemini: [CloudVoice] = [
        CloudVoice(id: "Kore", gender: L("女")), CloudVoice(id: "Aoede", gender: L("女")),
        CloudVoice(id: "Charon", gender: L("男")), CloudVoice(id: "Puck", gender: L("男")),
    ]

    static let openrouter = AIProvider(
        id: .openrouter, name: "OpenRouter", base: URL(string: "https://openrouter.ai/api/v1/"),
        site: URL(string: "https://openrouter.ai/settings/keys"),
        textModels: [Model(id: "inclusionai/ling-3.1-flash", note: L("和 Ling 同款")),
                     Model(id: "qwen/qwen3.8-flash", note: L("中文好"))],
        voiceModels: [Model(id: "google/gemini-3.8-flash-tts", note: L("效果和价格最均衡")),
                      Model(id: "google/gemini-3.8-flash-lite-tts", note: L("更省"))],
        voices: gemini, clones: false, hearsAudio: false, spacing: 0.1)

    static let zenmux = AIProvider(
        id: .zenmux, name: "ZenMux", base: URL(string: "https://zenmux.ai/api/v1/"),
        site: URL(string: "https://zenmux.ai/settings/keys"),
        textModels: [Model(id: "inclusionai/ling-3.0-flash", note: L("和 Ling 同款")),
                     Model(id: "qwen/qwen3.8-flash", note: L("中文好"))],
        voiceModels: [Model(id: "google/gemini-3.8-flash-tts", note: L("效果和价格最均衡")),
                      Model(id: "google/gemini-3.8-flash-lite-tts", note: L("更省"))],
        voices: gemini, clones: false, hearsAudio: false, spacing: 0.1)

    /// No voices: `/audio/speech` models shut down 2027-01-06 and their successor is Realtime-only.
    static let openai = AIProvider(
        id: .openai, name: "OpenAI", base: URL(string: "https://api.openai.com/v1/"),
        site: URL(string: "https://platform.openai.com/api-keys"),
        textModels: [Model(id: "gpt-5.4-nano", note: L("够用、更省"))],
        voiceModels: [], voices: [], clones: false, hearsAudio: false, spacing: 0.1)

    /// Any OpenAI-compatible address (a company gateway, Ollama, LM Studio…). Voices only when the
    /// user names a speech model; plain standard requests, none of Ling's workarounds.
    static let custom = AIProvider(
        id: .custom, name: L("自定义服务"), base: nil, site: nil,
        textModels: [], voiceModels: [], voices: [], clones: false, hearsAudio: false, spacing: 0.1)

    static let all: [AIProvider] = [.ling, .openrouter, .zenmux, .openai, .custom]

    static func named(_ raw: String) -> AIProvider { all.first { $0.id.rawValue == raw } ?? .ling }

    /// http only on this Mac (Ollama, LM Studio); anything else must be https.
    static func customBase(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = (isLocal(s) ? "http://" : "https://") + s }
        if !s.hasSuffix("/") { s += "/" }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        if url.scheme == "https" { return url }
        return url.scheme == "http" && isLocal(host) ? url : nil
    }

    static func isLocal(_ hostOrURL: String) -> Bool {
        let host = URL(string: hostOrURL.contains("://") ? hostOrURL : "http://" + hostOrURL)?.host ?? hostOrURL
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

/// A built-in voice of a cloud speech model.
struct CloudVoice: Equatable {
    let id: String
    /// "女" / "男", localized.
    let gender: String
}

/// What one call needs to know about the service in use, resolved from settings each time.
struct AIConfig: Equatable {
    var provider: AIProvider
    /// nil: a custom service without a valid address yet.
    var base: URL?
    var textModel: String
    /// nil: no voices with this service (the Mac's speak).
    var voiceModel: String?
    var voiceBase: URL?
    /// The voice a custom speech model speaks with (others pick per language).
    var customVoice: String?

    var hasVoices: Bool { voiceModel != nil && voiceBase != nil }

    /// The voices the room can pick from with this service.
    var voices: [CloudVoice] {
        guard hasVoices else { return [] }
        if provider.id == .custom { return customVoice.map { [CloudVoice(id: $0, gender: "")] } ?? [] }
        return provider.voices
    }

    /// The request body, shaped for the service: each one turns thinking off its own way, and
    /// OpenAI's current models take neither `max_tokens` nor a temperature.
    func shape(_ body: inout [String: Any], maxTokens: Int) {
        switch provider.id {
        case .ling:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
            body["thinking"] = ["type": "disabled"]
        case .openrouter, .zenmux:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
            body["reasoning"] = ["enabled": false]
        case .openai:
            body["max_completion_tokens"] = maxTokens
            body["reasoning_effort"] = "none"
        case .custom:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
        }
    }

    /// Text models from a `/models` reply, recommended ones first. Leaves out what cannot chat
    /// (speech, transcription, images, embeddings) when the service says so, or by name for OpenAI.
    static func textModels(fromCatalog data: Data, recommended: [String]) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return recommended }
        var ids: [String] = []
        for m in list {
            guard let id = m["id"] as? String, !id.hasSuffix(":batch") else { continue }
            let arch = m["architecture"] as? [String: Any]
            let out = (m["output_modalities"] ?? arch?["output_modalities"]) as? [String]
            if let out, out != ["text"], !out.contains("text") { continue }
            if out == nil, id.range(of: #"(embed|whisper|tts|transcribe|dall-e|image|moderation|realtime|audio|sora|search)"#,
                                    options: .regularExpression) != nil { continue }
            ids.append(id)
        }
        let rest = ids.filter { !recommended.contains($0) }.sorted()
        return recommended + rest
    }
}
