import Foundation
import Testing
@testable import Cicada

/// Answers Ling requests from the test, and keeps what was asked. Requests reach a URLProtocol
/// with the body as a stream, not `httpBody`.
final class LingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "")
    nonisolated(unsafe) static var seen: [(at: Date, body: [String: Any])] = []
    /// Where each request went and the key it carried, in order.
    nonisolated(unsafe) static var sent: [(host: String, auth: String?)] = []
    /// Answers each request by what it asked, instead of `reply`.
    nonisolated(unsafe) static var respond: (([String: Any]) -> (Int, String))?
    private static let lock = NSLock()

    static func reset(_ status: Int = 200, _ body: String) {
        lock.withLock { reply = (status, body); seen = []; sent = []; respond = nil }
    }

    static func chatReply(_ text: String, finish: String? = "stop") -> String {
        var choice: [String: Any] = ["message": ["content": text]]
        if let finish { choice["finish_reason"] = finish }
        return String(data: try! JSONSerialization.data(withJSONObject: ["choices": [choice]]), encoding: .utf8)!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let (status, text) = Self.lock.withLock {
            Self.seen.append((Date(), body))
            Self.sent.append((request.url?.host ?? "", request.value(forHTTPHeaderField: "Authorization")))
            return Self.respond?(body) ?? Self.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The key file and the Ling client share `AIKey`'s state, so these run one at a time in a temp folder.
@MainActor @Suite(.serialized) struct LingTests {
    let folder: URL

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cicada-key-\(UUID().uuidString)")
        AIKey.folderOverride = folder
    }

    private func client() -> LingClient {
        AIKey.save("sk-test-0000000000")
        let ling = LingClient()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LingStub.self]
        ling.session = URLSession(configuration: config)
        return ling
    }

    // MARK: Custom service

    private func customClient() -> LingClient {
        let ling = client()
        ling.config = { AIConfig(provider: .custom, base: URL(string: "http://localhost:9/v1/"), textModel: "m") }
        return ling
    }

    @Test func aServerThatRefusesTemplateKwargsIsAskedWithoutThem() async throws {
        LingStub.reset(200, "")
        LingStub.respond = { body in body["chat_template_kwargs"] != nil ? (400, "{}") : (200, LingStub.chatReply("好")) }
        let ling = customClient()
        #expect(try await ling.chat(content: "x", instruction: "Translate.", priority: .translate) == "好")
        _ = try await ling.chat(content: "y", instruction: "Translate.", priority: .translate)
        let bodies = LingStub.seen.map(\.body)
        #expect(bodies.count == 3 && bodies[0]["chat_template_kwargs"] != nil && bodies[1]["chat_template_kwargs"] == nil)
        // Not sent again once refused.
        #expect(bodies[2]["chat_template_kwargs"] == nil)
    }

    @Test func aRefusalForSomethingElseKeepsThinkingOff() async throws {
        LingStub.reset(200, "")
        // No JSON mode on this server: 400 with or without the kwargs. Asked again without JSON mode.
        LingStub.respond = { body in body["response_format"] != nil ? (400, "{}") : (200, LingStub.chatReply("好")) }
        let ling = customClient()
        #expect(try await ling.chat(content: "x", instruction: "Notes.", priority: .translate, json: true) == "好")
        #expect(LingStub.seen.last?.body["response_format"] == nil && LingStub.seen.last?.body["chat_template_kwargs"] != nil)
        _ = try await ling.chat(content: "y", instruction: "Translate.", priority: .translate)
        #expect(LingStub.seen.last?.body["chat_template_kwargs"] != nil)
    }

    // MARK: Notes apart

    private func notesClient(own: Bool) -> LingClient {
        let ling = client()
        AIKey.save("sk-main-1111111111", "custom")
        ling.config = { AIConfig(provider: .custom, base: URL(string: "https://main.example/v1/"), textModel: "mt",
                                 notesModel: "big", notesBase: own ? URL(string: "https://notes.example/v1/") : nil,
                                 notesOwnService: own) }
        return ling
    }

    @Test func notesGoToTheirModelAndServerTranslationStays() async throws {
        LingStub.reset(200, LingStub.chatReply("{}"))
        let ling = notesClient(own: true)
        AIKey.save("sk-notes-222222222", LingClient.notesKeyName)
        _ = try await ling.chat(content: "x", instruction: "Notes.", priority: .notes, json: true)
        _ = try await ling.chat(content: "y", instruction: "Translate.", priority: .translate)
        #expect(LingStub.seen.map { $0.body["model"] as? String } == ["big", "mt"])
        #expect(LingStub.sent.map(\.host) == ["notes.example", "main.example"])
        #expect(LingStub.sent.map(\.auth) == ["Bearer sk-notes-222222222", "Bearer sk-main-1111111111"])
    }

    @Test func notesWithoutTheirOwnKeyUseTheTranslationKey() async throws {
        LingStub.reset(200, LingStub.chatReply("{}"))
        let ling = notesClient(own: true)
        _ = try await ling.chat(content: "x", instruction: "Notes.", priority: .notes)
        #expect(LingStub.sent.first?.auth == "Bearer sk-main-1111111111")
        // The same service, another model: same address and key.
        let same = notesClient(own: false)
        AIKey.save("sk-notes-222222222", LingClient.notesKeyName)
        _ = try await same.chat(content: "x", instruction: "Notes.", priority: .notes)
        #expect(LingStub.sent.last?.host == "main.example" && LingStub.sent.last?.auth == "Bearer sk-main-1111111111")
        #expect(LingStub.seen.last?.body["model"] as? String == "big")
    }

    @Test func aRefusedNotesKeyLeavesTranslationWorking() async throws {
        LingStub.reset(200, "")
        LingStub.respond = { body in body["model"] as? String == "big" ? (401, "{}") : (200, LingStub.chatReply("好")) }
        let ling = notesClient(own: true)
        await #expect(throws: LingClient.Failure.invalidKey) {
            try await ling.chat(content: "x", instruction: "Notes.", priority: .notes)
        }
        #expect(ling.keyState != .invalid)
        #expect(try await ling.chat(content: "y", instruction: "Translate.", priority: .translate) == "好")
    }

    @Test func notesAtAnUnusableAddressSendNothing() async throws {
        LingStub.reset(200, LingStub.chatReply("{}"))
        let ling = client()
        AIKey.save("sk-main-1111111111", "custom")
        AIKey.save("sk-notes-222222222", LingClient.notesKeyName)
        ling.config = { AIConfig(provider: .custom, base: URL(string: "https://main.example/v1/"), textModel: "mt",
                                 notesOwnService: true, notesBadAddress: true) }
        await #expect(throws: LingClient.Failure.noKey) {
            try await ling.chat(content: "x", instruction: "Notes.", priority: .notes)
        }
        #expect(LingStub.sent.isEmpty)
    }

    @Test func notesFallBackToTranslationUntilSet() {
        let base = URL(string: "https://main.example/v1/")
        let plain = AIConfig(provider: .custom, base: base, textModel: "mt")
        #expect(!plain.notesApart && plain.forNotes == plain)
        let model = AIConfig(provider: .custom, base: base, textModel: "mt", notesModel: "big")
        #expect(model.notesApart && model.forNotes.textModel == "big" && model.forNotes.base == base)
        // Only the custom service splits.
        let ling = AIConfig(provider: .ling, base: AIProvider.ling.base, textModel: "x", notesModel: "big")
        #expect(!ling.notesApart && ling.forNotes.textModel == "x")
    }

    // MARK: Retries

    @Test func finalNotesKeepRetryingForAboutAMinute() {
        #expect(LingClient.retryWaits(.translate).isEmpty)
        #expect(LingClient.retryWaits(.speak, patient: true).isEmpty)
        #expect(LingClient.retryWaits(.notes) == [1, 2, 4])
        let patient = LingClient.retryWaits(.notes, patient: true)
        #expect(patient.count == 6)
        #expect((50...70).contains(patient.reduce(0, +)))
    }

    @Test func heardAudioRetriesAndTextFailsFast() {
        #expect(LingClient.retryWaits(.translate, audio: true) == [1, 2, 4, 8])
        #expect(LingClient.retryWaits(.speak, audio: true) == [1])
        #expect(LingClient.retryWaits(.translate, audio: false).isEmpty)
    }

    @Test func retryAfterIsSecondsOrADate() {
        #expect(LingClient.retryAfterSeconds("5") == 5)
        #expect(LingClient.retryAfterSeconds(nil) == nil)
        #expect(LingClient.retryAfterSeconds("soon") == nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // Tue, 14 Nov 2023 22:13:20 GMT
        #expect(LingClient.retryAfterSeconds("Tue, 14 Nov 2023 22:13:30 GMT", now: now) == 10)
    }

    @Test func heardAudioOutlastsA429AndTextFallsBackMeanwhile() async throws {
        LingStub.reset(200, "")
        var first = true
        LingStub.respond = { _ in
            if first { first = false; return (429, "{}") }
            return (200, LingStub.chatReply("ORIGINAL: hi\nTRANSLATION: 你好"))
        }
        let ling = client()
        async let heard = ling.chat(content: "x", instruction: "Hear.", priority: .translate, audio: Data([0, 1]))
        // The 429 pauses the gate: a text translation now fails at once (its caller uses Google)
        // instead of spending the pause in the queue.
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: LingClient.Failure.rateLimited) {
            try await ling.chat(content: "y", instruction: "Translate.", priority: .translate)
        }
        let reply = try await heard
        #expect(reply.hasPrefix("ORIGINAL"))
        #expect(LingStub.seen.count == 2)
        let gap = LingStub.seen[1].at.timeIntervalSince(LingStub.seen[0].at)
        #expect(gap >= 1 && gap < 2)
        #expect(ling.rateLimitedAt == nil)
    }

    // MARK: Key file

    @Test func keyFileIsOnlyForThisUser() throws {
        #expect(AIKey.save("sk-abc1234567890"))
        let file = folder.appendingPathComponent("ling-api-key")
        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "sk-abc1234567890")
    }

    @Test func keyIsNotInUserDefaults() {
        let key = "sk-not-in-defaults-\(UUID().uuidString)"
        AIKey.save(key)
        let values = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }
        #expect(!values.contains(where: { $0.contains(key) }))
    }

    @Test func keyReadsTrimmedAndRemoves() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "  sk-spaced-key \n".write(to: folder.appendingPathComponent("ling-api-key"), atomically: true, encoding: .utf8)
        AIKey.folderOverride = folder // forget the cached value
        #expect(AIKey.read() == "sk-spaced-key")
        AIKey.remove()
        #expect(AIKey.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("ling-api-key").path))
    }

    @Test func emptyKeyFileIsNoKey() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try " \n".write(to: folder.appendingPathComponent("ling-api-key"), atomically: true, encoding: .utf8)
        AIKey.folderOverride = folder
        #expect(AIKey.read() == nil)
    }

    @Test func eachServiceHasItsOwnKeyFile() throws {
        #expect(AIKey.save("sk-ling-111", "ling"))
        #expect(AIKey.save("sk-zen-222", "zenmux"))
        let file = folder.appendingPathComponent("ai-key-zenmux")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(AIKey.read("ling") == "sk-ling-111" && AIKey.read("zenmux") == "sk-zen-222" && AIKey.read("openai") == nil)
        AIKey.remove("zenmux")
        #expect(AIKey.read("zenmux") == nil && AIKey.read() == "sk-ling-111")
    }

    @Test func maskedShowsOnlyTheEnds() {
        #expect(AIKey.masked("sk-abcdefghij3f9a") == "sk-" + String(repeating: "•", count: 12) + "3f9a")
        #expect(AIKey.masked("short") == "sk-…")
    }

    // MARK: Client

    @Test func contentGoesInTheSystemMessageAndThinkingIsOff() async throws {
        let ling = client()
        LingStub.reset(200, LingStub.chatReply(" Hello. "))
        let out = try await ling.chat(content: "你好。", instruction: "Translate the system message.", priority: .translate)
        #expect(out == "Hello.")
        let body = try #require(LingStub.seen.first?.body)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "你好。")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "Translate the system message.")
    }

    @Test func eachRequestIsReportedWithServiceModelAndUse() async throws {
        let ling = client()
        var calls: [AICall] = []
        ling.onCall = { calls.append($0) }
        LingStub.reset(200, LingStub.chatReply("ok"))
        _ = try await ling.chat(content: "x", instruction: "y", priority: .translate)
        _ = try await ling.chat(content: "x", instruction: "y", priority: .notes)
        _ = try await ling.chat(content: "x", instruction: "y", priority: .notes, model: "Ling-3.0-tiny", role: "speakers")
        #expect(calls.map(\.provider) == ["ling", "ling", "ling"])
        #expect(calls.map(\.role) == ["translate", "notes", "speakers"])
        #expect(calls.map(\.model) == ["Ling-3.1-flash", "Ling-3.1-flash", "Ling-3.0-tiny"])
        #expect(calls.allSatisfy { $0.outcome == "ok" })
    }

    @Test func voiceRequestsAreReportedWithFirstAudio() async throws {
        let ling = client()
        var calls: [AICall] = []
        ling.onCall = { calls.append($0) }
        LingStub.reset(200, "0123456789")   // no Content-Type: raw PCM, one chunk
        var chunks = 0
        for try await _ in ling.speech("你好世界") { chunks += 1 }
        #expect(chunks == 1)
        let c = try #require(calls.first)
        #expect(c.role == "voice" && c.provider == "ling" && c.model == "Ming-3.0-tts-0.5B")
        #expect(c.outcome == "ok" && c.chars == 4 && c.firstAudio != nil && c.promptTokens == 0)
    }

    @Test func aJSONObjectInPlainTextCountsAsJSON() {
        func reply(_ t: String) -> [String: Any] { ["choices": [["message": ["content": t]]]] }
        #expect(LingClient.answersJSON(reply("{\"ok\": true}")))
        #expect(LingClient.answersJSON(reply("```json\n{\"ok\": true}\n```")))
        #expect(!LingClient.answersJSON(reply("ok")))
        #expect(!LingClient.answersJSON(nil))
    }

    @Test func rejectedKeyIsMarkedInvalid() async {
        let ling = client()
        LingStub.reset(401, "{}")
        await #expect(throws: LingClient.Failure.invalidKey) {
            try await ling.chat(content: "x", instruction: "y", priority: .translate)
        }
        #expect(ling.keyState == .invalid)
        #expect(!ling.usable)
    }

    @Test func searchStyleRepliesAreDropped() async {
        let ling = client()
        LingStub.reset(200, LingStub.chatReply("根据现有检索证据，……"))
        await #expect(throws: LingClient.Failure.hijacked) {
            try await ling.chat(content: "x", instruction: "y", priority: .translate)
        }
        LingStub.reset(200, LingStub.chatReply("Hello.", finish: nil))
        await #expect(throws: LingClient.Failure.hijacked) {
            try await ling.chat(content: "x", instruction: "y", priority: .translate)
        }
    }

    @Test func noKeyMeansNoRequest() async {
        let ling = client()
        AIKey.remove()
        LingStub.reset(200, LingStub.chatReply("Hello."))
        await #expect(throws: LingClient.Failure.noKey) {
            try await ling.chat(content: "x", instruction: "y", priority: .translate)
        }
        #expect(LingStub.seen.isEmpty)
    }

    @Test func startsAreSpacedAndGoInPriorityOrder() async throws {
        let ling = client()
        LingStub.reset(200, LingStub.chatReply("ok"))
        // The first call takes the gate; the next three queue behind it, asked in reverse priority.
        _ = try await ling.chat(content: "first", instruction: "i", priority: .notes)
        async let notes = ling.chat(content: "notes", instruction: "i", priority: .notes)
        async let translate = ling.chat(content: "translate", instruction: "i", priority: .translate)
        async let speak = ling.chat(content: "speak", instruction: "i", priority: .speak)
        _ = try await (notes, translate, speak)
        let order = LingStub.seen.map { (($0.body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? "" }
        #expect(order == ["first", "speak", "translate", "notes"])
        let times = LingStub.seen.map(\.at)
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(b.timeIntervalSince(a) >= 0.55)
        }
    }
}
