import Foundation
import Testing
@testable import Cicada

/// The small state machines pulled out of the engines and views: each transition as the code relied on it.
@Suite struct SystemAudioAccessTests {
    @Test func followsWhatTCCSays() {
        #expect(SystemAudioAccess.unknown.next(status: .granted, tapRan: false) == .granted)
        #expect(SystemAudioAccess.granted.next(status: .denied, tapRan: false) == .refused)
        #expect(SystemAudioAccess.refused.next(status: .granted, tapRan: false) == .granted)
        #expect(SystemAudioAccess.refused.next(status: .unknown, tapRan: false) == .unknown)
    }

    @Test func aTapThatRanMeansAllowed() {
        #expect(SystemAudioAccess.unknown.next(status: nil, tapRan: true) == .granted)
        #expect(SystemAudioAccess.unknown.next(status: .unknown, tapRan: true) == .granted)
        // TCC unreadable or undecided: what was known stays, pausing doesn't take it away.
        #expect(SystemAudioAccess.granted.next(status: .unknown, tapRan: false) == .granted)
        #expect(SystemAudioAccess.refused.next(status: nil, tapRan: false) == .refused)
        // TCC's no wins over a tap that ran before it was turned off.
        #expect(SystemAudioAccess.granted.next(status: .denied, tapRan: true) == .refused)
    }
}

@Suite struct LanguageDetectionTests {
    let english = sourceLanguages.first { $0.code == "en" }!
    let zh = sourceLanguages.first { $0.code == "zh-CN" }!
    let ja = sourceLanguages.first { $0.code == "ja" }!

    func c(_ lang: Lang, _ score: Double, chars: Int = 30) -> LanguageDetector.Candidate {
        .init(lang: lang, confidence: score, chars: chars, text: "", score: score)
    }

    @Test func aClearAnswerInTheLanguageListenedInConfirmsIt() {
        var d = LanguageDetection()
        #expect(d.apply([c(english, 0.9), c(zh, 0.6)], active: english) == .confirmed(english))
        #expect(d.verdict == .confirmed && d.settledEnough)
    }

    @Test func theFirstAnswerSwitchesAndReplaysEverything() {
        var d = LanguageDetection()
        #expect(d.apply([c(zh, 0.9), c(english, 0.5)], active: english) == .switchTo(zh, replayAll: true))
        #expect(d.confirmed)
    }

    @Test func onceConfirmedAnotherLanguageNeedsTwoChecksOrAWideMargin() {
        var d = LanguageDetection()
        _ = d.apply([c(english, 0.9), c(zh, 0.6)], active: english)
        #expect(d.apply([c(zh, 0.85), c(english, 0.7)], active: english) == .pending(zh))
        #expect(d.pendingSwitch == zh && d.due)
        #expect(d.apply([c(zh, 0.85), c(english, 0.7)], active: english) == .switchTo(zh, replayAll: false))
        // Overwhelming: at once.
        var e = LanguageDetection()
        _ = e.apply([c(english, 0.9), c(zh, 0.6)], active: english)
        #expect(e.apply([c(zh, 0.95), c(english, 0.6)], active: english) == .switchTo(zh, replayAll: false))
    }

    @Test func everyModelUnsureTwiceInARowHoldsTheLines() {
        var d = LanguageDetection()
        #expect(d.apply([c(english, 0.6), c(zh, 0.5)], active: english) == .noneOfThem(now: false))
        #expect(d.verdict == .unknown)
        #expect(d.apply([c(english, 0.6), c(zh, 0.5)], active: english) == .noneOfThem(now: true))
        #expect(d.mismatch && !d.settledEnough)
        // One sure answer after a no isn't enough; two are.
        #expect(d.apply([c(ja, 0.9), c(english, 0.5)], active: english) == .none)
        #expect(d.mismatch)
        #expect(d.apply([c(ja, 0.9), c(english, 0.5)], active: english) == .switchTo(ja, replayAll: true))
        #expect(d.confirmed && !d.mismatch)
    }

    @Test func theOneModelSayingNoHoldsUntilAPick() {
        var d = LanguageDetection()
        #expect(d.apply([c(english, 0.12)], active: english) == .notThis(english, firstTime: true))
        #expect(d.apply([c(english, 0.12)], active: english) == .notThis(english, firstTime: false))
        d.redetect()
        #expect(d.mismatch)  // a no stands through 重新识别
        d.picked()
        #expect(d.confirmed && !d.due)
        // A good answer from the one model takes a no back.
        var e = LanguageDetection()
        _ = e.apply([c(english, 0.12)], active: english)
        #expect(e.apply([c(english, 0.9)], active: english) == .confirmed(english))
        // Confirmed, a check where only one model answered doesn't take the language back.
        #expect(e.apply([c(english, 0.12)], active: english) == .none)
        #expect(e.confirmed)
    }

    @Test func twoCloseCallsLetLinesBeKept() {
        var d = LanguageDetection()
        #expect(d.apply([c(english, 0.80), c(zh, 0.76)], active: english) == .ambiguous)
        #expect(!d.settledEnough && d.due)
        #expect(d.apply([c(english, 0.80), c(zh, 0.76)], active: english) == .ambiguous)
        #expect(d.settledEnough && !d.confirmed)
    }

    @Test func aClipWithNoWordsOnlyAsksAgain() {
        var d = LanguageDetection()
        d.checkStarted()
        #expect(!d.due && d.checking)
        d.checkEnded()
        #expect(d.apply([c(english, 0.1, chars: 2), c(zh, 0.1, chars: 0)], active: english) == .none)
        #expect(d.due && d.verdict == .unknown)
    }

    @Test func resetsKeepWhatTheyAlwaysKept() {
        var d = LanguageDetection()
        _ = d.apply([c(english, 0.9), c(zh, 0.6)], active: english)
        d.unconfirm()
        #expect(d.verdict == .unknown)
        d.setConfirmed(true)
        d.modeChanged()
        #expect(d.verdict == .unknown && d.due && d.pendingSwitch == nil)
        _ = d.apply([c(english, 0.12)], active: english)
        d.clearMismatch()
        #expect(d.verdict == .unknown)
        d.start()
        #expect(d.verdict == .unknown && d.due && d.nextPeriodic == 30 && d.ambiguous == 0)
    }
}
