import Foundation
import Testing
@testable import Cicada

/// The share document is a contract with the server (server/src/doc.js) and the ports: the same
/// record must give the same bytes (Tests/fixtures/share).
struct ShareTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/share")

    static func session() throws -> Session {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Session.self, from: Data(contentsOf: fixtures.appendingPathComponent("session.json")))
    }

    @Test func fixtureBytes() throws {
        let doc = ShareProjection.doc(try Self.session(), scope: .full, names: false)
        let want = try String(contentsOf: Self.fixtures.appendingPathComponent("share-doc.json"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(String(decoding: ShareProjection.encode(doc), as: UTF8.self) == want)
    }

    @Test func nothingPrivateLeaves() throws {
        let text = String(decoding: ShareProjection.encode(ShareProjection.doc(try Self.session(), scope: .full, names: false)), as: UTF8.self)
        for secret in ["/Users/someone", "Emma", "Kenji", "Emmer", "Sure, Emma"] { #expect(!text.contains(secret), "\(secret)") }
    }

    @Test func namesWhenAsked() throws {
        let doc = ShareProjection.doc(try Self.session(), scope: .full, names: true)
        #expect(doc.notes?.todos.first?.owner == "Emma")
        #expect(doc.notes?.terms.first?.name == "Emma")
    }

    @Test func notesOnlyAndRemoved() throws {
        let s = try Self.session()
        #expect(ShareProjection.doc(s, scope: .notes, names: false).lines.isEmpty)
        let d = ShareProjection.doc(s, scope: .full, names: false, removed: [3], dropNotes: true)
        #expect(d.lines.count == 3 && d.notes == nil && d.hidden == 2)
    }

    @Test func speakerNumbersWithoutNames() throws {
        var s = try Self.session()
        // Two voices with five substantive lines each get numbers; their names stay out.
        s.lines = (0..<10).map { i in
            TranscriptLine(id: "v\(i)", t: Double(i), speaker: "them", src: "this is line number \(i)", dst: "第 \(i) 句话", srcLang: "en", dstLang: "zh", voice: i % 2 == 0 ? 3 : 7)
        }
        let d = ShareProjection.doc(s, scope: .full, names: false)
        #expect(Set(d.lines.map(\.who)) == ["说话人 1", "说话人 2"])
        let named = ShareProjection.doc(s, scope: .full, names: true)
        #expect(Set(named.lines.map(\.who)) == ["Emma", "Kenji"])
    }

    @Test func password() {
        let salt = Data(repeating: 1, count: 16)
        // Same as the browser's crypto.subtle PBKDF2-SHA256, 32 bytes (server/test/api.test.mjs).
        let v = SharePassword.verifier("ruby-41-lake", salt: salt, iterations: 1000)
        #expect(v.map { String(format: "%02x", $0) }.joined() == "eab69fcd00a0517794c156495dd76ad1fbfb036ea03df3d59a68a33519009c81")
        #expect(v == SharePassword.verifier("ruby-41-lake", salt: salt, iterations: 1000))
        #expect(v != SharePassword.verifier("ruby-41-laka", salt: salt, iterations: 1000))
        #expect(SharePassword.make().split(separator: "-").count == 3)
    }

    @Test func blockedHitsMapBack() {
        // The server counts lines of what was sent; the app maps them back to the record.
        let kept = [0, 1, 4, 5, 6]
        let hits = [ShareHit(part: "lines", from: 2, to: 3, questions: ["credential"])]
        #expect(ShareHit.recordLines(hits, kept: kept) == [4, 5])
    }
}
