import Foundation
import Security

// MARK: - API key (local file)

/// The user's AI keys, one file per service (`ling-api-key`, `ai-key-<service>`) only this user
/// can read (0600, folder 0700) under Application Support, left out of backups. Never written to
/// UserDefaults, logs or exports.
///
/// Not the Keychain for now: the app is signed ad hoc, so the Keychain only trusts one exact build
/// (its cdhash) and asks for the login password after every rebuild or update. Back to the Keychain
/// once builds are signed with a Developer ID (a stable team id). Keys saved there by earlier
/// builds are moved over once.
enum AIKey {
    private static var cached: [String: String?] = [:]

    /// Tests only: keep the key in this folder instead, and leave the Keychain alone, so a test
    /// run never touches the user's real key.
    static var folderOverride: URL? { didSet { cached = [:] } }

    private static var folder: URL {
        folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder)
    }
    private static func file(_ service: String) -> URL {
        folder.appendingPathComponent(service == "ling" ? "ling-api-key" : "ai-key-\(service)")
    }

    static func read(_ service: String = "ling") -> String? {
        if let hit = cached[service] { return hit }
        var value = (try? String(contentsOf: file(service), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty ?? true { value = nil }
        if value == nil, service == "ling", folderOverride == nil, let old = LegacyKeychain.take() {
            // One last Keychain prompt, then the key lives in the file.
            value = old
            write(old, service)
        }
        cached[service] = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String, _ service: String = "ling") -> Bool {
        let ok = write(key, service)
        cached[service] = .some(ok ? key : nil)
        return ok
    }

    static func remove(_ service: String = "ling") {
        try? FileManager.default.removeItem(at: file(service))
        if service == "ling", folderOverride == nil { LegacyKeychain.delete() }
        cached[service] = .some(nil)
    }

    @discardableResult
    private static func write(_ key: String, _ service: String) -> Bool {
        let file = file(service)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            // Create it 0600 before the key goes in, so it is never readable by others.
            if !fm.fileExists(atPath: file.path) {
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    debugLog("ai key: could not create the key file")
                    return false
                }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #if os(iOS)
            // Readable after the first unlock: listening goes on on the lock screen, and a meeting
            // started from the Action Button while locked still needs the key for the notes.
            try Data(key.utf8).write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            #else
            try Data(key.utf8).write(to: file)
            #endif
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            debugLog("ai key: save failed \(error.localizedDescription)")
            return false
        }
    }

    /// Where builds before the file kept the key: login Keychain, service = bundle id + ".ai".
    private enum LegacyKeychain {
        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.wquguru.cicada.swiftrun") + ".ai",
             kSecAttrAccount as String: "ling"]
        }

        /// The old key, removed from the Keychain once read.
        static func take() -> String? {
            // Skip the Keychain entirely when there was never an item (no prompt for new users).
            var exists = query
            exists[kSecReturnAttributes as String] = true
            guard SecItemCopyMatching(exists as CFDictionary, nil) == errSecSuccess else { return nil }
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let key = (out as? Data).flatMap({ String(data: $0, encoding: .utf8) }), !key.isEmpty else { return nil }
            delete()
            debugLog("ai key: moved from the Keychain to the key file")
            return key
        }

        static func delete() { SecItemDelete(query as CFDictionary) }
    }

    /// "sk-…3f9a" for display.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "sk-…" }
        return String(key.prefix(3)) + String(repeating: "•", count: 12) + String(key.suffix(4))
    }
}

// MARK: - Ling client

/// The one AI client for the whole app: Ling (ant-ling.com) or another OpenAI-compatible service
/// (`AIProvider`), whichever settings name. Request *starts* go through one gate in priority order
/// (speak-back, translation, notes), spaced for the service: Ling's account allows about 2
/// requests per second across every model.
///
/// Two Ling quirks found in testing shape every call (`AIConfig.shape` turns thinking off for the
/// others too, each its own way):
/// - `thinking` is on by default: always disable it (otherwise +2.6 s and billed reasoning).
/// - When the user message reads like a factual question, the gateway answers it with a search
///   essay instead of following the prompt. So the content always goes in the system message and
///   the user message is a fixed instruction; a search-style reply is detected and dropped.
@MainActor
final class LingClient: ObservableObject {
    enum Priority: Int, Comparable {
        case speak = 0, translate = 1, notes = 2
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    enum KeyState: Equatable {
        case none
        case unchecked
        case checking
        case ok(seconds: Double)
        case invalid
        case unreachable(String)
    }

    enum Failure: Error, Equatable {
        case noKey, invalidKey, rateLimited, hijacked, timeout, http(Int), network, parse
    }

    static let models = AIProvider.ling.textModels.map(\.id)
    private static let hijackPrefixes = ["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索"]

    @Published private(set) var keyState: KeyState
    @Published private(set) var rateLimitedAt: Date?
    /// The service's text models from its `/models`, recommended first (empty until fetched).
    @Published private(set) var catalog: [String] = []
    /// The service in use, its address and models. Set by the app from settings.
    var config: () -> AIConfig = { AIConfig(provider: .ling, base: AIProvider.ling.base, textModel: "Ling-3.1-flash",
                                            voiceModel: "Ming-3.0-tts-0.5B", voiceBase: AIProvider.ling.base) }
    var provider: AIProvider { config().provider }

    /// Debug control only: make every chat call fail this way.
    var simulate: Failure?

    /// Debug control only: act as if there were no key, without touching the key file.
    var hideKey = false

    /// Tests swap in a session with a stub protocol.
    var session: URLSession = .shared

    var hasKey: Bool { key != nil }
    /// The key for the service in use. A custom service on this Mac may need none: "".
    var key: String? {
        if hideKey { return nil }
        let c = config()
        if c.provider.id == .custom {
            guard let base = c.base else { return nil }
            return AIKey.read(c.provider.id.rawValue) ?? (AIProvider.isLocal(base.absoluteString) ? "" : nil)
        }
        return AIKey.read(c.provider.id.rawValue)
    }
    /// The key is known to work (or at least not known to be bad): notes and translation.
    var usable: Bool { hasKey && keyState != .invalid }
    /// Voices in the room from this service (else the Mac's).
    var speaks: Bool { usable && config().hasVoices }
    /// The user's own voice: only Ling clones.
    var clones: Bool { usable && provider.clones }
    /// Speak-back heard by the service's audio model (Ming) instead of on this Mac.
    var hearsAudio: Bool { usable && provider.hearsAudio }

    init() {
        keyState = AIKey.read() == nil ? .none : .unchecked
    }

    /// Settings switched service, address or model: forget the old state and check again.
    func reconfigure() {
        catalog = []
        keyState = hasKey ? .unchecked : .none
        if hasKey { Task { await check() } }
    }

    // MARK: Key

    /// Saves the key and checks it with the cheapest possible request.
    func setKey(_ raw: String) async {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if hideKey { debugLog("ai key: not saved while hidden (debug)"); keyState = .invalid; return }
        AIKey.save(k, provider.id.rawValue)
        await check()
    }

    func removeKey() {
        AIKey.remove(provider.id.rawValue)
        catalog = []
        keyState = hasKey ? .unchecked : .none
    }

    /// The cheapest request that proves the key: Ling's tiny model, OpenRouter's key info, OpenAI's
    /// model list, else one token from the chosen model. A custom service must also return JSON
    /// (the notes need it).
    func check() async {
        guard let key else { keyState = .none; return }
        keyState = .checking
        let c = config()
        let started = Date()
        let name = c.provider.id == .custom ? L("这个服务") : c.provider.name
        do {
            switch c.provider.id {
            case .ling:
                _ = try await post("chat/completions", body: ["model": "Ling-3.0-tiny", "messages": [["role": "user", "content": "hi"]],
                                                             "max_tokens": 1, "thinking": ["type": "disabled"]], key: key, timeout: 15)
            case .openrouter:
                _ = try await get("key", key: key)
            case .openai:
                _ = try await get("models", key: key)
            case .zenmux, .custom:
                var body: [String: Any] = ["model": c.textModel, "messages": [["role": "user", "content": "hi"]]]
                c.shape(&body, maxTokens: 1)
                _ = try await post("chat/completions", body: body, key: key, timeout: 20)
                if c.provider.id == .custom {
                    var json: [String: Any] = ["model": c.textModel, "response_format": ["type": "json_object"],
                                               "messages": [["role": "system", "content": "Reply with the JSON object {\"ok\": true}."],
                                                            ["role": "user", "content": "Reply."]]]
                    c.shape(&json, maxTokens: 20)
                    do { _ = try await post("chat/completions", body: json, key: key, timeout: 20) } catch Failure.http(let code) {
                        keyState = .unreachable(L("这个服务不支持 JSON（HTTP \(code)），纪要用不了"))
                        return
                    }
                }
            }
            keyState = .ok(seconds: Date().timeIntervalSince(started))
        } catch Failure.invalidKey {
            keyState = .invalid
        } catch Failure.rateLimited {
            keyState = .ok(seconds: Date().timeIntervalSince(started))
        } catch Failure.http(let code) where code == 404 || code == 400 {
            keyState = .unreachable(c.provider.id == .custom ? L("找不到模型，或地址不对（HTTP \(code)）") : L("\(name) 拒绝了请求（HTTP \(code)），请检查模型名"))
        } catch {
            keyState = .unreachable(L("连不上 \(name)，请检查网络或代理"))
        }
        debugLog("ai \(c.provider.id.rawValue): key check → \(keyState)")
        if case .ok = keyState, c.provider.id != .ling { await fetchCatalog() }
    }

    /// The service's text models, for the model menu. Quietly empty when it has no `/models`.
    func fetchCatalog() async {
        let c = config()
        guard let key, c.provider.id != .ling, let data = try? await getData("models", key: key) else { return }
        catalog = AIConfig.textModels(fromCatalog: data, recommended: c.provider.textModels.map(\.id))
        debugLog("ai \(c.provider.id.rawValue): \(catalog.count) models")
    }

    // MARK: Chat

    /// One chat completion. `content` goes in the system message, `instruction` is the fixed user
    /// message. Notes retry 429s with backoff; translation and speak-back fail fast so the caller
    /// can fall back to another translator. `audio` (a WAV) goes in the user message before the
    /// instruction, for Ming's audio model (Ling only: `hearsAudio`).
    func chat(content: String, instruction: String, priority: Priority, json: Bool = false,
              maxTokens: Int = 1024, timeout: TimeInterval = 30, model: String? = nil, audio: Data? = nil,
              role: String? = nil, onQueued: ((Double) -> Void)? = nil) async throws -> String {
        guard let key else { throw Failure.noKey }
        guard keyState != .invalid else { throw Failure.invalidKey }
        if let simulate {
            if simulate == .rateLimited { rateLimitedAt = Date() }
            throw simulate
        }
        let c = config()
        let call = CallLabel(provider: c.provider.id.rawValue, model: model ?? c.textModel,
                             role: role ?? (priority == .notes ? "notes" : "translate"))
        var body: [String: Any] = [
            "model": call.model,
            "messages": [
                ["role": "system", "content": content],
                ["role": "user", "content": audio.map { wav -> Any in
                    [["type": "audio_url", "audio_url": ["url": "data:audio/wav;base64," + wav.base64EncodedString()]],
                     ["type": "text", "text": instruction]]
                } ?? instruction],
            ],
            "stream": false,
        ]
        c.shape(&body, maxTokens: maxTokens)
        if json { body["response_format"] = ["type": "json_object"] }
        let attempts = priority == .notes ? 4 : 1
        var delay = 1.0
        for attempt in 1...attempts {
            let asked = Date()
            await acquire(priority)
            let queued = Date().timeIntervalSince(asked)
            onQueued?(queued)
            let started = Date()
            do {
                let root = try await post("chat/completions", body: body, key: key, timeout: timeout)
                guard let choice = (root["choices"] as? [[String: Any]])?.first,
                      let message = choice["message"] as? [String: Any],
                      let text = message["content"] as? String else { throw Failure.parse }
                let finish = choice["finish_reason"] as? String
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if (finish == nil && c.provider.id == .ling) || Self.hijackPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                    debugLog("ling: \(priority) search-style reply dropped (finish=\(finish ?? "nil"))")
                    throw Failure.hijacked
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let usage = root["usage"] as? [String: Any]
                debugLog("ling: \(priority) ok \(ms) ms tokens=\(usage?["prompt_tokens"] ?? "?")/\(usage?["completion_tokens"] ?? "?")")
                report(call, priority, at: started, queued: queued, outcome: "ok",
                       tokens: (usage?["prompt_tokens"] as? Int ?? 0, usage?["completion_tokens"] as? Int ?? 0))
                if rateLimitedAt != nil { rateLimitedAt = nil }
                return trimmed
            } catch let failure as Failure {
                report(call, priority, at: started, queued: queued, outcome: Self.name(failure))
                guard failure == .rateLimited else { throw failure }
                guard attempt < attempts else {
                    rateLimitedAt = Date()
                    throw failure
                }
                let wait = delay + Double.random(in: 0...0.5)
                debugLog("ling: \(priority) 429, retry in \(String(format: "%.1f", wait)) s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                delay *= 2
            }
        }
        throw Failure.rateLimited
    }

    /// Every request, for diagnostics (timings and token counts only).
    var onCall: ((AICall) -> Void)?

    /// Which service, model and use a request is for: the diagnostics page groups by these.
    struct CallLabel { let provider, model, role: String }

    private func report(_ call: CallLabel, _ priority: Priority, at started: Date, queued: Double, outcome: String,
                        tokens: (Int, Int) = (0, 0), chars: Int = 0, firstAudio: Double? = nil) {
        onCall?(AICall(at: started, provider: call.provider, model: call.model, role: call.role, priority: "\(priority)",
                       queue: queued, seconds: Date().timeIntervalSince(started), outcome: outcome,
                       promptTokens: tokens.0, completionTokens: tokens.1, chars: chars, firstAudio: firstAudio))
    }

    static func name(_ failure: Failure) -> String {
        switch failure {
        case .http(let code): "http\(code)"
        default: "\(failure)"
        }
    }

    // MARK: Speech

    /// Streams the voice for `text` as raw 24 kHz mono 16-bit PCM chunks. Ling (Ming): a built-in
    /// `voice`, or a voice cloned from `reference` (a WAV data URI and what it says); `language` is
    /// Ming's `language_id`, needed for Japanese, Korean, German, French and Spanish. Others: the
    /// configured speech model and `voice`.
    ///
    /// Replies come three ways and all are read: SSE with base64 chunks (Ling, ZenMux), raw PCM
    /// bytes (OpenRouter), or one JSON `{"audio": <WAV>}`. Gemini TTS and Kokoro speak 24 kHz too.
    func speech(_ text: String, voice: String? = "UK_Charlotte", reference: (audio: String, text: String)? = nil,
                language: String? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor [weak self] in
                guard let self, let key = self.key else { cont.finish(throwing: Failure.noKey); return }
                let c = self.config()
                guard let base = c.voiceBase, let voiceModel = c.voiceModel else { cont.finish(throwing: Failure.noKey); return }
                let asked = Date()
                await self.acquire(.speak)
                let queued = Date().timeIntervalSince(asked)
                let started = Date()
                var firstAudio: Double?
                let call = CallLabel(provider: c.provider.id.rawValue, model: voiceModel, role: "voice")
                func yield(_ pcm: Data) {
                    if firstAudio == nil { firstAudio = Date().timeIntervalSince(started) }
                    cont.yield(pcm)
                }
                var req = URLRequest(url: base.appendingPathComponent("audio/speech"))
                req.httpMethod = "POST"
                req.timeoutInterval = 20
                if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = ["model": voiceModel, "input": text, "response_format": "pcm"]
                if c.provider.id == .ling {
                    body["sample_rate"] = 24000
                    body["stream"] = true
                    body["stream_format"] = "sse"
                    if let reference {
                        body["references"] = [["audio": reference.audio, "text": reference.text]]
                        req.timeoutInterval = 30
                    } else if let voice {
                        body["voice"] = voice
                    }
                    if let language { body["language_id"] = language }
                } else {
                    // OpenRouter documents no `stream` (it streams the bytes anyway); ZenMux needs it.
                    if c.provider.id != .openrouter { body["stream"] = true }
                    body["voice"] = voice ?? c.voices.first?.id ?? "Kore"
                }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await self.session.bytes(for: req)
                    let http = response as? HTTPURLResponse
                    switch http?.statusCode ?? 0 {
                    case 200: break
                    case 401, 403:
                        self.keyState = .invalid
                        throw Failure.invalidKey
                    case 429: throw Failure.rateLimited
                    case let code: throw Failure.http(code)
                    }
                    let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
                    if type.contains("event-stream") {
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:"),
                                  let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                            else { continue }
                            if obj["type"] as? String == "speech.audio.done" { break }
                            if let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) { yield(pcm) }
                        }
                    } else if type.contains("json") {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let b64 = obj["audio"] as? String, let wav = Data(base64Encoded: b64) else { throw Failure.parse }
                        yield(Self.pcm(fromWAV: wav))
                    } else {
                        // Raw PCM: hand it on in 0.1 s pieces so playback starts early.
                        var chunk = Data()
                        chunk.reserveCapacity(4800)
                        for try await b in bytes {
                            chunk.append(b)
                            if chunk.count >= 4800 { yield(chunk); chunk.removeAll(keepingCapacity: true) }
                        }
                        if !chunk.isEmpty { yield(chunk) }
                    }
                    self.report(call, .speak, at: started, queued: queued, outcome: "ok", chars: text.count, firstAudio: firstAudio)
                    cont.finish()
                } catch {
                    // Cancelled: the voice was cut short on purpose (stop, a new press), not a failure.
                    let outcome = Task.isCancelled ? "cancelled" : (error as? Failure).map(Self.name) ?? "network"
                    self.report(call, .speak, at: started, queued: queued, outcome: outcome, chars: text.count, firstAudio: firstAudio)
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// The samples of a WAV (its `data` chunk); the bytes as they are when there is no header.
    nonisolated static func pcm(fromWAV wav: Data) -> Data {
        guard wav.count > 12, wav.prefix(4) == Data("RIFF".utf8) else { return wav }
        var i = 12
        while i + 8 <= wav.count {
            let id = wav.subdata(in: i..<i + 4)
            let size = wav.subdata(in: i + 4..<i + 8).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            if id == Data("data".utf8) { return wav.subdata(in: i + 8..<min(wav.count, i + 8 + size)) }
            i += 8 + size + (size & 1)
        }
        return wav
    }

    // MARK: Transport

    private func post(_ path: String, body: [String: Any], key: String, timeout: TimeInterval) async throws -> [String: Any] {
        guard let base = config().base else { throw Failure.noKey }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(req, key: key)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.parse }
        return root
    }

    private func get(_ path: String, key: String) async throws -> [String: Any] {
        let data = try await getData(path, key: key)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func getData(_ path: String, key: String) async throws -> Data {
        guard let base = config().base else { throw Failure.noKey }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 15
        return try await send(req, key: key)
    }

    private func send(_ request: URLRequest, key: String) async throws -> Data {
        var req = request
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw Failure.timeout
        } catch {
            debugLog("ling: network error \(error.localizedDescription)")
            throw Failure.network
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 401, 403:
            if keyState != .invalid { keyState = .invalid }
            throw Failure.invalidKey
        case 429: throw Failure.rateLimited
        default:
            debugLog("ling: HTTP \(code)")
            throw Failure.http(code)
        }
    }

    // MARK: Start gate

    private var lastStart = Date.distantPast
    private var waiting: [(priority: Priority, seq: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var seq = 0
    private var pumping = false

    private func acquire(_ priority: Priority) async {
        if waiting.isEmpty && Date().timeIntervalSince(lastStart) >= provider.spacing {
            lastStart = Date()
            return
        }
        seq += 1
        let n = seq
        await withCheckedContinuation { cont in
            waiting.append((priority, n, cont))
            pump()
        }
    }

    private func pump() {
        guard !pumping, !waiting.isEmpty else { return }
        pumping = true
        let wait = max(0, provider.spacing - Date().timeIntervalSince(lastStart))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pumping = false
                guard let i = self.waiting.indices.min(by: {
                    (self.waiting[$0].priority, self.waiting[$0].seq) < (self.waiting[$1].priority, self.waiting[$1].seq)
                }) else { return }
                let next = self.waiting.remove(at: i)
                self.lastStart = Date()
                next.resume.resume()
                self.pump()
            }
        }
    }
}
