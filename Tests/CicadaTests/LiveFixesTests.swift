import Foundation
import Testing
@testable import Cicada

/// Who wins on a line: the user's decisions, then the word list, then the recheck, then the first guess.
@MainActor @Suite struct LiveFixesTests {
    private func setup(_ lines: [String]) -> (LiveFixes, SessionStore, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixes-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        let s = store.begin()
        for (i, t) in lines.enumerated() {
            store.append(TranscriptLine(id: "l\(i)", t: Double(i), speaker: "them", src: t, dst: nil, srcLang: "zh-CN", dstLang: "en"))
        }
        let settings = AppSettings()
        settings.fixMisheard = true
        settings.askNames = true
        return (LiveFixes(store: store, vocabulary: Vocabulary(url: nil), settings: settings), store, s.id)
    }

    private func line(_ store: SessionStore, _ id: String, _ l: String) -> TranscriptLine {
        store.session(id)!.lines.first { $0.id == l }!
    }

    @Test func recheckTakesBackAGuessButKeepsTheUsersYes() {
        let (fx, store, id) = setup(["最近那个开布特提了，这个是跑好的测试"])
        let text = line(store, id, "l0").src
        fx.received(text, [.init(from: "开布特", to: "Curve", confidence: 0.9), .init(from: "跑好的", to: "跑跑的", confidence: 0.9)])
        #expect(line(store, id, "l0").shown.contains("跑跑的"))
        fx.answer(fx.pending(in: id)[0].fix, yes: true, in: id)
        #expect(line(store, id, "l0").shown == "最近那个Curve提了，这个是跑跑的测试")
        // The recheck, with the lines after it in view, proposes nothing.
        fx.received(text, [])
        #expect(line(store, id, "l0").shown == "最近那个Curve提了，这个是跑好的测试")
    }

    @Test func confirmedHeardFormsApplyWithoutTheService() {
        let (fx, store, id) = setup(["扩展到这个莫拉的链", "单个的拉不改"])
        fx.vocabulary.confirm(heard: "莫拉", word: "Morpho")
        fx.applyKnown(lineID: "l0", in: id)
        fx.applyKnown(lineID: "l1", in: id)
        #expect(line(store, id, "l0").shown == "扩展到这个Morpho的链")
        #expect(line(store, id, "l1").fixes == nil)
    }

    @Test func editEverywhereTeachesTheListAndUndoPutsItBack() {
        let (fx, store, id) = setup(["我木娜找了一个", "木娜那边也有", "别的"])
        #expect(fx.sameHeard(lineID: "l0", in: id, edited: "我Monad找了一个")?.count == 2)
        let n = fx.edit(lineID: "l0", in: id, to: "我Monad找了一个", everywhere: true, remember: true)
        #expect(n == 2)
        #expect(line(store, id, "l1").shown == "Monad那边也有")
        #expect(fx.vocabulary.knows(heard: "木娜", word: "Monad"))
        // A later pass can't override what the user wrote.
        fx.received(line(store, id, "l1").src, [.init(from: "木娜", to: "Mona", confidence: 0.95)])
        #expect(line(store, id, "l1").shown == "Monad那边也有")
        fx.undo()
        #expect(line(store, id, "l0").shown == "我木娜找了一个")
        #expect(!fx.vocabulary.knows(heard: "木娜", word: "Monad"))
    }

    @Test func oneOffEditDoesNotTeachTheList() {
        let (fx, store, id) = setup(["我木娜找了一个", "木娜那边也有"])
        fx.edit(lineID: "l0", in: id, to: "我Monad找了一个", everywhere: false, remember: true)
        #expect(line(store, id, "l1").shown == "木娜那边也有")
        #expect(fx.vocabulary.terms.isEmpty)
    }

    @Test func laterTakesItOffTheCardButKeepsItWaiting() {
        let (fx, _, id) = setup(["最近那个开布特提了"])
        fx.received("最近那个开布特提了", [.init(from: "开布特", to: "Curve", confidence: 0.9)])
        let a = fx.asking(in: id)!
        fx.later(a.fix, in: id)
        #expect(fx.asking(in: id) == nil)
        #expect(fx.pending(in: id).count == 1)
        fx.undo()
        #expect(fx.asking(in: id) != nil)
    }

    @Test func revertStaysRevertedThroughTheRecheck() {
        let (fx, store, id) = setup(["但质压这种"])
        fx.received("但质压这种", [.init(from: "质压", to: "质押", confidence: 0.9)])
        let f = line(store, id, "l0").fixes![0]
        fx.revert(f, lineID: "l0", in: id)
        fx.received("但质压这种", [.init(from: "质压", to: "质押", confidence: 0.9)])
        #expect(line(store, id, "l0").shown == "但质压这种")
    }

    @Test func yesFixesTheRestOfTheMeetingAtOnce() {
        let (fx, store, id) = setup(["最近那个开布特提了", "开布特那边也说了"])
        fx.received("最近那个开布特提了", [.init(from: "开布特", to: "Curve", confidence: 0.9)])
        fx.answer(fx.pending(in: id)[0].fix, yes: true, in: id)
        #expect(line(store, id, "l1").shown == "Curve那边也说了")
        fx.undo()
        #expect(line(store, id, "l1").shown == "开布特那边也说了")
    }

    @Test func editRevertEditRevertGoesBack() {
        let (fx, store, id) = setup(["Great, let's lock that in.", "Design signs off by Friday."])
        for _ in 0..<2 {
            fx.edit(lineID: "l0", in: id, to: "Great, let's lock that in now.", everywhere: true, remember: true)
            #expect(line(store, id, "l0").shown == "Great, let's lock that in now.")
            let f = line(store, id, "l0").fixes!.first { $0.applied }!
            fx.revert(f, lineID: "l0", in: id)
            #expect(line(store, id, "l0").shown == "Great, let's lock that in.")
        }
        #expect(line(store, id, "l0").fixes!.count == 1)
        #expect(line(store, id, "l1").fixes == nil)
    }
}
