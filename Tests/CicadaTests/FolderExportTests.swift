import Foundation
import Testing
@testable import Cicada

/// 存到文件夹's file name and frontmatter are a contract with the ports (Tests/fixtures/folder-export).
struct FolderExportTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/folder-export")

    struct Collision: Decodable { let stem: String; let taken: [String]; let want: String }
    struct Cases: Decodable {
        let timeZone: String
        let fileName: String
        let names: [[String]]
        let stems: [[String]]
        let escapes: [[String]]
        let collisions: [Collision]
    }

    static func cases() throws -> Cases {
        try JSONDecoder().decode(Cases.self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
    }

    static func session() throws -> Session {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Session.self, from: Data(contentsOf: fixtures.appendingPathComponent("session.json")))
    }

    @Test func frontmatterBytes() throws {
        let tz = TimeZone(identifier: try Self.cases().timeZone)!
        let want = try String(contentsOf: Self.fixtures.appendingPathComponent("frontmatter.md"), encoding: .utf8)
        #expect(FolderExportFormat.frontmatter(try Self.session(), timeZone: tz) == want)
    }

    @Test func fileName() throws {
        let c = try Self.cases()
        let stem = FolderExportFormat.stem(try Self.session(), timeZone: TimeZone(identifier: c.timeZone)!)
        #expect(FolderExportFormat.fileName(stem) { _ in false } == c.fileName)
    }

    @Test func names() throws {
        for pair in try Self.cases().names { #expect(FolderExportFormat.safeName(pair[0]) == pair[1], "\(pair[0])") }
    }

    @Test func stems() throws {
        let c = try Self.cases()
        var s = try Self.session()
        for pair in c.stems {
            s.title = pair[0]
            #expect(FolderExportFormat.stem(s, timeZone: TimeZone(identifier: c.timeZone)!) == pair[1])
        }
    }

    @Test func escapes() throws {
        for pair in try Self.cases().escapes { #expect(FolderExportFormat.quote(pair[0]) == pair[1], "\(pair[0])") }
    }

    @Test func collisions() throws {
        for c in try Self.cases().collisions {
            #expect(FolderExportFormat.fileName(c.stem) { c.taken.contains($0) } == c.want)
        }
    }

    /// The name: the user's title, else the notes', else the imported file's, never the display title.
    @Test func namePrecedence() throws {
        var s = try Self.session()
        s.renamed = false
        s.title = Session.defaultTitle(s.startedAt)
        #expect(FolderExportFormat.name(s) == "产品路线评审")
        s.notes = nil
        #expect(FolderExportFormat.name(s) == "")
        s.sourceFile = "Weekly sync.m4a"
        #expect(FolderExportFormat.name(s) == "Weekly sync")
        #expect(FolderExportFormat.frontmatter(s).contains("source: \"file\"\nnotes: \"none\""))
    }

    @Test func obsidianVaults() {
        let json = #"{"vaults":{"a":{"path":"/v/old","ts":1},"b":{"path":"/v/new","ts":5,"open":true},"c":{"path":"/gone","ts":9}}}"#
        let vaults = FolderExportFormat.obsidianVaults(Data(json.utf8)) { $0 != "/gone" }
        #expect(vaults.map(\.path) == ["/v/new", "/v/old"])
        #expect(FolderExportFormat.obsidianVaults(Data("not json".utf8)).isEmpty)
    }
}

/// Real writes into a temporary folder: the cases the ports test too.
struct FolderExportWriteTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-export-\(UUID().uuidString)")
    var folder: URL { root.appendingPathComponent("Cicada") }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func job(_ stem: String, old: String? = nil, text: String = "x") -> FolderExporter.Job {
        FolderExporter.Job(id: "a", stem: stem, old: old, text: text)
    }

    @Test func foreignFileIsKept() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "mine".write(to: folder.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        #expect(FolderExporter.write([job("n")], to: folder, ours: [:]) == [.wrote(id: "a", name: "n 2.md")])
        #expect(try String(contentsOf: folder.appendingPathComponent("n.md"), encoding: .utf8) == "mine")
    }

    @Test func renameMovesAndUnchangedSkips() throws {
        _ = FolderExporter.write([job("old")], to: folder, ours: [:])
        #expect(FolderExporter.write([job("old", old: "old.md")], to: folder, ours: ["a": "old.md"]) == [.unchanged(id: "a")])
        #expect(FolderExporter.write([job("new", old: "old.md")], to: folder, ours: ["a": "old.md"]) == [.wrote(id: "a", name: "new.md")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["new.md"])
    }

    @Test func missingParentIsNotCreated() {
        let gone = root.appendingPathComponent("unplugged/Cicada")
        #expect(FolderExporter.write([job("n")], to: gone, ours: [:]) == [.stopped(.missing)])
        #expect(!FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path))
    }

    /// A folder that can't be looked into reads as "no permission", not as a missing drive.
    @Test func unreadableParentIsDenied() throws {
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(FolderExporter.write([job("n")], to: locked.appendingPathComponent("Cicada"), ours: [:]) == [.stopped(.denied)])
    }
}
