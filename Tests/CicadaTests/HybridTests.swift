import Foundation
import Testing
@testable import Cicada

@Suite struct EchoMatchTests {
    private func h(_ t: String, _ s: Double, _ e: Double) -> EchoMatch.Heard { .init(text: t, start: s, end: e) }

    @Test func theRoomsCopyOfARemoteSentenceIsAnEcho() {
        let online = [h("Revenue grew by 12%, mostly from the new region.", 10, 14)]
        // Heard worse from the speakers, and a word lost.
        #expect(EchoMatch.isEcho(h("revenue grew by 12% mostly from new region", 10.3, 14.2), online: online))
    }

    @Test func cutDifferentlyStillMatches() {
        let online = [h("我们先看一下这个季度的数据。", 0, 2), h("收入增长了百分之十二，主要来自新的市场。", 2.2, 5)]
        #expect(EchoMatch.isEcho(h("这个季度的数据收入增长了百分之十二", 0.8, 4), online: online))
    }

    @Test func roomSpeechIsKept() {
        let online = [h("Revenue grew by 12%, mostly from the new region.", 10, 14)]
        #expect(!EchoMatch.isEcho(h("I think we should check the numbers for Europe first", 11, 15), online: online))
        #expect(!EchoMatch.isEcho(h("我觉得应该先看一下欧洲的情况", 11, 15), online: online))
    }

    @Test func theSameWordsLongAfterAreNotAnEcho() {
        let online = [h("Can everyone hear me okay?", 0, 2)]
        #expect(!EchoMatch.isEcho(h("can everyone hear me okay", 20, 22), online: online))
    }

    @Test func shortLinesMatchOnlyExactly() {
        let online = [h("OK.", 5, 5.5)]
        #expect(EchoMatch.isEcho(h("ok", 5.2, 5.6), online: online))
        #expect(!EchoMatch.isEcho(h("no", 5.2, 5.6), online: online))
    }

    @Test func gateClosesForTheHang() {
        let g = EchoGate()
        #expect(!g.closed(now: 100))
        g.hold(now: 100)
        #expect(g.closed(now: 100.3))
        #expect(!g.closed(now: 100 + EchoGate.hang + 0.01))
    }

    /// The Mac loud every 0.1 s from `from` to `to`, words every second when `words`, and the room
    /// mic at `during` while it plays and at `quiet` for as long again afterwards.
    private func play(_ g: EchoGate, from: Double, to: Double, words: Bool, during: Float, quiet: Float) {
        var t = from
        while t < to {
            g.hold(now: t)
            if words, Int(t * 10) % 10 == 0 { g.heardWords(now: t) }
            g.roomLevel(during, seconds: 0.1, now: t + 0.05)
            t += 0.1
        }
        let end = t
        while t < end + (to - from) + 2 {
            g.roomLevel(quiet, seconds: 0.1, now: t)
            t += 0.1
        }
    }

    @Test func thePressShareTheMacPlayedThrough() {
        let g = EchoGate()
        // The meeting loud through 0–4 s (a block every 0.1 s), then quiet.
        for i in 0..<40 { g.hold(now: 1000 + Double(i) * 0.1) }
        #expect(g.playedShare(from: 1000, to: 1004) > 0.9)
        #expect(g.playedShare(from: 1006, to: 1010) == 0)
        #expect(abs(g.playedShare(from: 1002, to: 1006) - 0.6) < 0.1)
        // Headphones: the speakers don't reach the mic, so nothing played counts.
        g.forced = false
        #expect(g.playedShare(from: 1000, to: 1004) == 0)
    }

    @Test func musicStopsClosingTheGate() {
        let g = EchoGate()
        var t = 0.0
        while t < 3 { g.hold(now: t); t += 0.1 }
        // Three seconds without words: still taken for speech that hasn't been recognized yet.
        g.hold(now: 3.0)
        #expect(g.closed(now: 3.1))
        // Five: music. The room is heard over it.
        while t < 5 { g.hold(now: t); t += 0.1 }
        g.hold(now: 5)
        #expect(g.playingMusic(now: 5))
        #expect(!g.closed(now: 5 + EchoGate.hang + 0.01))
        // Someone starts talking over it: words close it again.
        g.heardWords(now: 5.5)
        g.hold(now: 5.6)
        #expect(g.closed(now: 5.7))
    }

    @Test func speechKeepsTheGateClosedThroughALongSentence() {
        let g = EchoGate()
        var t = 0.0
        while t < 10 { g.hold(now: t); if Int(t * 10) % 10 == 0 { g.heardWords(now: t) }; t += 0.1 }
        #expect(!g.playingMusic(now: 10))
        #expect(g.closed(now: 10))
    }

    @Test func noEchoMeasuredOpensTheGate() {
        let g = EchoGate()
        #expect(g.echo)
        // Headphones: the room mic stays at its floor while the Mac speaks.
        play(g, from: 0, to: 6, words: true, during: 0.001, quiet: 0.001)
        #expect(!g.echo)
        g.hold(now: 20)
        #expect(!g.closed(now: 20.1))
    }

    @Test func speakersReachingTheMicKeepTheGate() {
        let g = EchoGate()
        play(g, from: 0, to: 6, words: true, during: 0.03, quiet: 0.001)
        #expect(g.echo)
        g.hold(now: 20)
        #expect(g.closed(now: 20.1))
    }

    @Test func echoComesBackWhenTheHeadphonesComeOff() {
        let g = EchoGate()
        play(g, from: 0, to: 6, words: true, during: 0.001, quiet: 0.001)
        #expect(!g.echo)
        play(g, from: 20, to: 45, words: true, during: 0.03, quiet: 0.001)
        #expect(g.echo)
    }

    @Test func aResetAssumesEchoAgain() {
        let g = EchoGate()
        play(g, from: 0, to: 6, words: true, during: 0.001, quiet: 0.001)
        #expect(!g.echo)
        g.reset()
        #expect(g.echo)
        g.hold(now: 50)
        #expect(g.closed(now: 50.1))
    }

    @Test func notEnoughToTellKeepsTheEcho() {
        #expect(EchoGate.ratio(during: [(0.001, 1)], quiet: [(0.001, 10)]) == nil)
        #expect(EchoGate.ratio(during: [(0.001, 5)], quiet: [(0.001, 1)]) == nil)
    }
}

@Suite struct VoiceGateBlockTests {
    /// The echo-cancelling unit's ~11 ms blocks learn the room's floor per second, as the mic tap's do.
    @Test func smallBlocksLearnTheFloorPerSecond() {
        var g = VoiceGate(adaptive: true)
        let block = 171.0 / 16000
        // Ten seconds of talk at 0.012, one quiet block (0.002) in each second.
        for i in 0..<Int(10 / block) { _ = g.voiced(i % 94 == 0 ? 0.002 : 0.012, seconds: block) }
        #expect(g.threshold < 0.006)
        let voice = g.voiced(0.012, seconds: block)
        #expect(voice)
    }
}
