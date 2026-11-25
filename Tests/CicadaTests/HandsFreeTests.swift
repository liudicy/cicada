import Foundation
import Testing
@testable import Cicada

@Suite struct HandsFreeTests {
    private static let block = 170.0 / 16000

    /// Feeds `seconds` of blocks at `rms`; returns the events with the time each came at.
    private func feed(_ d: inout HandsFreeDetector, _ rms: Float, _ seconds: Double, clock: inout Double) -> [(HandsFreeDetector.Event, Double)] {
        var out: [(HandsFreeDetector.Event, Double)] = []
        for _ in 0..<Int((seconds / Self.block).rounded()) {
            let e = d.feed(rms: rms, seconds: Self.block)
            clock += Self.block
            if e != .none { out.append((e, clock)) }
        }
        return out
    }

    @Test func aSentenceStartsAndEndsAfterTheHangover() {
        var d = HandsFreeDetector(), t = 0.0
        #expect(feed(&d, 0.0005, 3, clock: &t).isEmpty)
        let began = feed(&d, 0.05, 2, clock: &t)
        #expect(began.count == 1 && began[0].0 == .began)
        #expect(began[0].1 - 3 < 0.15)
        let ended = feed(&d, 0.0005, 1.5, clock: &t)
        #expect(ended.count == 1 && ended[0].0 == .ended(cut: false))
        #expect(abs(ended[0].1 - 6) < 0.05)
    }

    @Test func nothingStartsBeforeTheFloorIsKnown() {
        var d = HandsFreeDetector(), t = 0.0
        #expect(feed(&d, 0.05, 1, clock: &t).isEmpty)
    }

    /// The room got noisier while quiet: the floor follows, the noise doesn't hold a sentence open.
    @Test func aRoomThatGetsNoisierEndsTheSentence() {
        var d = HandsFreeDetector(), t = 0.0
        _ = feed(&d, 0.0005, 3, clock: &t)
        let events = feed(&d, 0.008, 15, clock: &t).map(\.0)
        #expect(events.first == .began)
        #expect(events.last == .ended(cut: false))
        #expect(!d.talking)
    }

    @Test func aClickIsNotASentence() {
        var d = HandsFreeDetector(), t = 0.0
        _ = feed(&d, 0.0005, 3, clock: &t)
        #expect(feed(&d, 0.05, 0.03, clock: &t).isEmpty)
        #expect(feed(&d, 0.0005, 2, clock: &t).isEmpty)
    }

    /// The echo-cancelled voice comes through in pieces: short gaps don't reset the onset or end it.
    @Test func gapsBetweenWordsKeepOneSentence() {
        var d = HandsFreeDetector(), t = 0.0
        _ = feed(&d, 0.0005, 3, clock: &t)
        var events: [HandsFreeDetector.Event] = []
        for _ in 0..<6 {
            events += feed(&d, 0.05, 0.06, clock: &t).map(\.0)
            events += feed(&d, 0.0005, 0.1, clock: &t).map(\.0)
        }
        for _ in 0..<5 {
            events += feed(&d, 0.05, 0.3, clock: &t).map(\.0)
            events += feed(&d, 0.0005, 0.6, clock: &t).map(\.0)
        }
        events += feed(&d, 0.0005, 1.5, clock: &t).map(\.0)
        #expect(events == [.began, .ended(cut: false)])
    }

    @Test func aLongMonologueIsCutAndGoesOn() {
        var d = HandsFreeDetector(), t = 0.0
        _ = feed(&d, 0.0005, 3, clock: &t)
        // Speech with a short gap every 0.4 s, as words have.
        var events: [HandsFreeDetector.Event] = []
        for _ in 0..<110 {
            events += feed(&d, 0.05, 0.3, clock: &t).map(\.0)
            events += feed(&d, 0.0005, 0.1, clock: &t).map(\.0)
        }
        #expect(events == [.began, .ended(cut: true), .ended(cut: true)])
        #expect(d.talking)
    }

    /// A noisy room raises the line: its hum is not a voice.
    @Test func theLineFollowsTheRoom() {
        var d = HandsFreeDetector(), t = 0.0
        #expect(feed(&d, 0.008, 5, clock: &t).isEmpty)
        #expect(d.line > 0.03)
        #expect(feed(&d, 0.1, 1, clock: &t).map(\.0) == [.began])
    }

    /// What Ming made of the meeting's leftovers (100 % on the speakers, nobody talking) is found in the
    /// meeting's translated lines around it; my own sentence over the same meeting is not.
    @Test func theMeetingsOwnWordsAreItsEcho() {
        let meeting: [EchoMatch.Heard] = [
            .init(text: "Our revenue grew 12% this quarter, mostly from enterprise customers in Europe.", start: 0, end: 4),
            .init(text: "我们的营收本季度增长了12%，主要来自欧洲的企业客户。营销支出低于计划，我们还招聘了四名工程师。", start: 0, end: 7),
            .init(text: "下个月我们将上线新的定价页面，并回顾下半年的招聘计划。", start: 8, end: 12),
        ]
        #expect(EchoMatch.isEcho(.init(text: "营收增长；四名工程师；下半年", start: 3, end: 9), online: meeting))
        #expect(!EchoMatch.isEcho(.init(text: "我同意这个数字，设计那个岗位很急，周四之前我会回复。", start: 3, end: 9), online: meeting))
    }
}
