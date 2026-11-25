import Foundation
import Testing
@testable import Cicada

@MainActor @Suite struct VocabularyTests {
    @Test func importLinesWithHeardForms() {
        let v = Vocabulary(url: nil)
        let r = v.importText("Uniswap V3\nMorpho = 莫拉、莫法\n\n" + String(repeating: "长", count: 41) + "\n巡检=寻检,巡练")
        #expect(r == .init(added: 3, updated: 0, skipped: [4]))
        #expect(v.knows(heard: "莫法", word: "morpho"))
        #expect(v.terms.first { $0.word == "巡检" }?.heard == ["寻检", "巡练"])
    }

    @Test func sameWordWhateverWidthOrCase() {
        let v = Vocabulary(url: nil)
        _ = v.importText("Aave")
        let r = v.importText("ＡＡＶＥ = 阿韦")
        #expect(r.updated == 1 && r.added == 0)
        #expect(v.terms.count == 1)
        #expect(v.knows(heard: "阿韦", word: "Aave"))
    }

    @Test func aYesNeverTeachesATranslation() {
        let v = Vocabulary(url: nil)
        v.confirm(heard: "平台", word: "platform")
        #expect(v.terms.isEmpty)
        v.confirm(heard: "平台", word: "platform", source: "user")
        #expect(v.knows(heard: "平台", word: "platform"))
    }

    @Test func confirmAndForget() {
        let v = Vocabulary(url: nil)
        v.confirm(heard: "开布特", word: "Curve")
        #expect(v.terms == [.init(word: "Curve", heard: ["开布特"], source: "live")])
        v.forget(heard: "开布特", word: "Curve")
        #expect(!v.knows(heard: "开布特", word: "Curve"))
    }

    @Test func promptPutsRecentFirst() {
        let v = Vocabulary(url: nil)
        _ = v.importText("A\nB = b")
        v.used("B", at: Date(timeIntervalSince1970: 100))
        #expect(v.promptLines() == ["B (heard as b)", "A"])
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vocab-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let v = Vocabulary(url: url)
        _ = v.importText("Morpho = 莫拉")
        #expect(Vocabulary(url: url).knows(heard: "莫拉", word: "Morpho"))
    }

    @Test func renameKeepsHeardFormsAndMerges() {
        let v = Vocabulary(url: nil)
        _ = v.importText("Morfo = 莫拉\nMorpho = 莫法")
        v.rename("Morfo", to: "Morpho")
        #expect(v.terms.count == 1)
        #expect(v.knows(heard: "莫拉", word: "Morpho") && v.knows(heard: "莫法", word: "Morpho"))
    }

    @Test func ownersAndPreview() {
        let v = Vocabulary(url: nil)
        _ = v.importText("Morpho = 莫拉")
        #expect(v.owners(ofHeard: "莫拉", except: "Mora") == ["Morpho"])
        #expect(v.owners(ofHeard: "莫拉", except: "Morpho").isEmpty)
        #expect(v.preview("Morpho = 莫法\nPendle\n" + String(repeating: "长", count: 41)) == .init(added: 1, updated: 1, skipped: [3]))
        #expect(v.terms.count == 1)
    }

    @Test func editsThatArentAWordForAWordTeachNothing() {
        let v = Vocabulary(url: nil)
        v.confirm(heard: "持。", word: "讲。")
        #expect(v.knows(heard: "持", word: "讲"))
        v.confirm(heard: "我来", word: "OK我来", source: "user")
        v.confirm(heard: "然后，", word: "然后")
        #expect(v.terms.map(\.word) == ["讲"])
        v.confirm(heard: "木娜", word: "Monad", source: "user")
        v.confirm(heard: "Uni斯图 V三", word: "Uniswap V3")
        #expect(v.knows(heard: "木娜", word: "Monad") && v.knows(heard: "Uni斯图 V三", word: "Uniswap V3"))
    }
}
