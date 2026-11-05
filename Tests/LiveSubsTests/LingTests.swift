import Foundation
import Testing
@testable import LiveSubs

/// Answers Ling requests from the test, and keeps what was asked. Requests reach a URLProtocol
/// with the body as a stream, not `httpBody`.
final class LingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "")
    nonisolated(unsafe) static var seen: [(at: Date, body: [String: Any])] = []
    private static let lock = NSLock()

    static func reset(_ status: Int = 200, _ body: String) {
        lock.withLock { reply = (status, body); seen = [] }
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
        let (status, text) = Self.lock.withLock { Self.seen.append((Date(), body)); return Self.reply }
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
