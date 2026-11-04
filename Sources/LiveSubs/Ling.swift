import Foundation
import Security

// MARK: - Provider

/// A chat provider for translation and notes: Ling (built-in) or any OpenAI-compatible endpoint
/// the user adds. Custom providers persist in UserDefaults (no secrets there — keys live in
/// per-provider files, see `AIKey`).
struct AIProvider: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// e.g. "https://api.ant-ling.com/v1" (with or without the trailing slash).
    var baseURL: String
    var model: String

    /// The built-in provider keeps the id "ling": its key file and Ming voices are Ling-only.
    var isLing: Bool { id == "ling" }

    var base: URL? {
        URL(string: baseURL.hasSuffix("/") ? baseURL : baseURL + "/")
    }

    static let ling = AIProvider(id: "ling", name: "Ling",
                                 baseURL: "https://api.ant-ling.com/v1", model: "Ling-3.1-flash")
}

// MARK: - API key (local file)

/// API keys, one file per provider, only this user can read (0600, folder 0700) under
/// Application Support, left out of backups. Never written to UserDefaults, logs or exports.
///
/// Not the Keychain for now: the app is signed ad hoc, so the Keychain only trusts one exact build
/// (its cdhash) and asks for the login password after every rebuild or update. Back to the Keychain
/// once builds are signed with a Developer ID (a stable team id). Keys saved there by earlier
/// builds are moved over once.
enum AIKey {
    private static var cached: [String: String??] = [:]

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder)
    }
    private static func file(_ provider: String) -> URL {
        // Ling keeps its original file name so existing installs just work.
        folder.appendingPathComponent(provider == "ling" ? "ling-api-key" : "ai-key-\(provider)")
    }

    static func read(_ provider: String = "ling") -> String? {
        if let hit = cached[provider] { return hit! }
        var value = (try? String(contentsOf: file(provider), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty ?? true { value = nil }
        if value == nil, provider == "ling", let old = LegacyKeychain.take() {
            // One last Keychain prompt, then the key lives in the file.
            value = old
            write(old, provider)
        }
        cached[provider] = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String, provider: String = "ling") -> Bool {
        let ok = write(key, provider)
        cached[provider] = .some(ok ? key : nil)
        return ok
    }

    static func remove(_ provider: String = "ling") {
        try? FileManager.default.removeItem(at: file(provider))
        if provider == "ling" { LegacyKeychain.delete() }
        cached[provider] = .some(nil)
    }

    @discardableResult
    private static func write(_ key: String, _ provider: String) -> Bool {
        let fm = FileManager.default
        let file = file(provider)
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
            try Data(key.utf8).write(to: file)
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

/// Talks to the active chat provider (see `provider`): Ling by default, or any OpenAI-compatible
/// endpoint the user added. One shared instance for the whole app: request *starts* go through one
/// gate (≥ 0.6 s apart, overlapping is fine) in priority order: speak-back, translation, notes.
///
/// Two quirks found in testing shape every call to Ling (`provider().isLing`); other providers get
/// a plain OpenAI request instead:
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

    static let models = ["Ling-3.1-flash", "Ling-3.0-flash"]
    /// Ming voices and the `audio/speech` endpoint are Ling-only, whatever provider is active.
    private static let lingBase = URL(string: "https://api.ant-ling.com/v1/")!
    private static let hijackPrefixes = ["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索"]

    @Published private(set) var keyState: KeyState
    @Published private(set) var rateLimitedAt: Date?
    /// The provider chat calls go to. AppModel keeps this in sync with the user's choice; the
    /// default is Ling. A closure so switching providers needs no client rebuild.
    var provider: () -> AIProvider = { .ling }
    var model: () -> String = { "Ling-3.1-flash" }

    /// Debug control only: make every chat call fail this way.
    var simulate: Failure?

    /// Debug control only: act as if there were no key, without touching the key file.
    var hideKey = false

    var hasKey: Bool { key != nil }
    var key: String? { hideKey ? nil : AIKey.read(provider().id) }
    /// The key is known to work (or at least not known to be bad).
    var usable: Bool { hasKey && keyState != .invalid }
    /// Ming speech (and so speak-back and voice cloning) only exists with a usable Ling key.
    var speechCapable: Bool { provider().isLing && usable }

    init() {
        keyState = AIKey.read() == nil ? .none : .unchecked
    }

    // MARK: Key

    /// Saves the key for the active provider and checks it with the cheapest possible request.
    func setKey(_ raw: String) async {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        if hideKey { debugLog("ai key: not saved while hidden (debug)"); keyState = .invalid; return }
        AIKey.save(k, provider: provider().id)
        await check()
    }

    func removeKey() {
        AIKey.remove(provider().id)
        keyState = .none
    }

    /// The keyState belongs to the active provider; call this after switching providers.
    func check() async {
        guard let key else { keyState = .none; return }
        keyState = .checking
        let started = Date()
        let ling = provider().isLing
        var body: [String: Any] = [
            "model": ling ? "Ling-3.0-tiny" : provider().model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
        ]
        if ling { body["thinking"] = ["type": "disabled"] }
        do {
            _ = try await post("chat/completions", body: body, key: key, timeout: 15)
            keyState = .ok(seconds: Date().timeIntervalSince(started))
        } catch Failure.invalidKey {
            keyState = .invalid
        } catch Failure.rateLimited {
            keyState = .ok(seconds: Date().timeIntervalSince(started))
        } catch {
            keyState = .unreachable(L("连不上 %@，检查网络或代理").replacingOccurrences(of: "%@", with: provider().name))
        }
        debugLog("ling: key check → \(keyState)")
    }

    // MARK: Chat

    /// One chat completion. `content` goes in the system message, `instruction` is the fixed user
    /// message. Notes retry 429s with backoff; translation and speak-back fail fast so the caller
    /// can fall back to another translator. `audio` (a WAV) goes in the user message before the
    /// instruction, for Ming's audio model.
    func chat(content: String, instruction: String, priority: Priority, json: Bool = false,
              maxTokens: Int = 1024, timeout: TimeInterval = 30, model: String? = nil, audio: Data? = nil,
              onQueued: ((Double) -> Void)? = nil) async throws -> String {
        guard let key else { throw Failure.noKey }
        guard keyState != .invalid else { throw Failure.invalidKey }
        if let simulate {
            if simulate == .rateLimited { rateLimitedAt = Date() }
            throw simulate
        }
        let ling = provider().isLing
        var body: [String: Any] = [
            "model": model ?? self.model(),
            "messages": [
                ["role": "system", "content": content],
                ["role": "user", "content": audio.map { wav -> Any in
                    [["type": "audio_url", "audio_url": ["url": "data:audio/wav;base64," + wav.base64EncodedString()]],
                     ["type": "text", "text": instruction]]
                } ?? instruction],
            ],
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "stream": false,
        ]
        if ling { body["thinking"] = ["type": "disabled"] }
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
                if finish == nil || (ling && Self.hijackPrefixes.contains(where: { trimmed.hasPrefix($0) })) {
                    debugLog("ling: \(priority) search-style reply dropped (finish=\(finish ?? "nil"))")
                    throw Failure.hijacked
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let usage = root["usage"] as? [String: Any]
                debugLog("ling: \(priority) ok \(ms) ms tokens=\(usage?["prompt_tokens"] ?? "?")/\(usage?["completion_tokens"] ?? "?")")
                report(priority, at: started, queued: queued, outcome: "ok",
                       tokens: (usage?["prompt_tokens"] as? Int ?? 0, usage?["completion_tokens"] as? Int ?? 0))
                if rateLimitedAt != nil { rateLimitedAt = nil }
                return trimmed
            } catch let failure as Failure {
                report(priority, at: started, queued: queued, outcome: Self.name(failure))
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
    var onCall: ((LingCall) -> Void)?

    private func report(_ priority: Priority, at started: Date, queued: Double, outcome: String, tokens: (Int, Int) = (0, 0)) {
        onCall?(LingCall(at: started, priority: "\(priority)", queue: queued, seconds: Date().timeIntervalSince(started),
                         outcome: outcome, promptTokens: tokens.0, completionTokens: tokens.1))
    }

    static func name(_ failure: Failure) -> String {
        switch failure {
        case .http(let code): "http\(code)"
        default: "\(failure)"
        }
    }

    // MARK: Speech (Ming TTS)

    /// Streams Ming's voice for `text` as raw 24 kHz mono 16-bit PCM chunks: a built-in `voice`, or
    /// a voice cloned from `reference` (a WAV data URI and what it says). `language` is Ming's
    /// `language_id`, needed for Japanese, Korean, German, French and Spanish.
    /// Ling-only: it always uses the Ling key and endpoint, whatever provider is active.
    func speech(_ text: String, voice: String? = "UK_Charlotte", reference: (audio: String, text: String)? = nil,
                language: String? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor [weak self] in
                guard let self, let key = AIKey.read("ling") else { cont.finish(throwing: Failure.noKey); return }
                await self.acquire(.speak)
                var req = URLRequest(url: Self.lingBase.appendingPathComponent("audio/speech"))
                req.httpMethod = "POST"
                req.timeoutInterval = 20
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = [
                    "model": "Ming-3.0-tts-0.5B", "input": text,
                    "response_format": "pcm", "sample_rate": 24000, "stream": true, "stream_format": "sse",
                ]
                if let reference {
                    body["references"] = [["audio": reference.audio, "text": reference.text]]
                    req.timeoutInterval = 30
                } else if let voice {
                    body["voice"] = voice
                }
                if let language { body["language_id"] = language }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
                    case 200: break
                    case 401, 403:
                        self.keyState = .invalid
                        throw Failure.invalidKey
                    case 429: throw Failure.rateLimited
                    case let code: throw Failure.http(code)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                        else { continue }
                        if obj["type"] as? String == "speech.audio.done" { break }
                        if let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) { cont.yield(pcm) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transport

    private func post(_ path: String, body: [String: Any], key: String, timeout: TimeInterval) async throws -> [String: Any] {
        guard let base = provider().base else { throw Failure.network }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw Failure.timeout
        } catch {
            debugLog("ling: network error \(error.localizedDescription)")
            throw Failure.network
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403:
            if keyState != .invalid { keyState = .invalid }
            throw Failure.invalidKey
        case 429: throw Failure.rateLimited
        default:
            debugLog("ling: HTTP \(code)")
            throw Failure.http(code)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.parse }
        return root
    }

    // MARK: Start gate

    private static let spacing: TimeInterval = 0.6
    private var lastStart = Date.distantPast
    private var waiting: [(priority: Priority, seq: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var seq = 0
    private var pumping = false

    private func acquire(_ priority: Priority) async {
        if waiting.isEmpty && Date().timeIntervalSince(lastStart) >= Self.spacing {
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
        let wait = max(0, Self.spacing - Date().timeIntervalSince(lastStart))
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
