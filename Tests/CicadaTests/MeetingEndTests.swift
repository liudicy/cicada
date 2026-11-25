import Foundation
import Testing
@testable import Cicada

@Suite struct MeetingEndTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let zoom = ["us.zoom.xos": "Zoom"]

    func watch(_ silence: MeetingEndWatch.Silence = .prompt, followApps: Bool = true) -> MeetingEndWatch {
        var c = MeetingEndWatch.Config()
        c.followApps = followApps
        c.silence = silence
        return MeetingEndWatch(config: c, start: t0)
    }

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func hangUpEndsAfterTheGrace() {
        var w = watch()
        #expect(w.tick(at: at(10), calls: zoom, said: true) == nil)
        #expect(w.tick(at: at(20), calls: [:], said: true) == nil)
        #expect(w.pending == .init(reason: .appLeft("Zoom"), deadline: at(50)))
        #expect(w.tick(at: at(49), calls: [:], said: true) == nil)
        #expect(w.tick(at: at(50), calls: [:], said: true) == .appLeft("Zoom"))
    }

    @Test func rejoiningWithinTheGraceKeepsGoing() {
        var w = watch()
        _ = w.tick(at: at(10), calls: zoom, said: true)
        _ = w.tick(at: at(20), calls: [:], said: true)
        #expect(w.tick(at: at(30), calls: zoom, said: true) == nil)
        #expect(w.pending == nil)
    }

    @Test func speechDoesNotCancelAHangUp() {
        var w = watch()
        _ = w.tick(at: at(10), calls: zoom, said: true)
        _ = w.tick(at: at(20), calls: [:], said: true)
        w.heard(at: at(25))
        #expect(w.tick(at: at(50), calls: [:], said: true) == .appLeft("Zoom"))
    }

    @Test func keepGoingForgetsTheHangUp() {
        var w = watch()
        _ = w.tick(at: at(10), calls: zoom, said: true)
        _ = w.tick(at: at(20), calls: [:], said: true)
        w.keepGoing(at: at(30))
        #expect(w.tick(at: at(100), calls: [:], said: true) == nil)
        #expect(w.pending == nil)
    }

    @Test func silencePromptsThenEnds() {
        var w = watch()
        w.heard(at: at(5))
        #expect(w.tick(at: at(604), calls: [:], said: true) == nil)
        #expect(w.pending == nil)
        #expect(w.tick(at: at(605), calls: [:], said: true) == nil)
        #expect(w.pending == .init(reason: .silence, deadline: at(665)))
        #expect(w.tick(at: at(665), calls: [:], said: true) == .silence)
    }

    @Test func wordsCancelTheSilencePrompt() {
        var w = watch()
        _ = w.tick(at: at(600), calls: [:], said: true)
        #expect(w.pending?.reason == .silence)
        w.heard(at: at(620))
        #expect(w.pending == nil)
        #expect(w.tick(at: at(700), calls: [:], said: true) == nil)
    }

    @Test func silenceEndModeEndsAtOnceAndOffNever() {
        var end = watch(.end)
        #expect(end.tick(at: at(600), calls: [:], said: true) == .silence)
        var off = watch(.off)
        #expect(off.tick(at: at(99_999), calls: [:], said: true) == nil)
        #expect(off.pending == nil)
    }

    @Test func silenceDoesNotCountDuringACall() {
        var w = watch()
        #expect(w.tick(at: at(5_000), calls: zoom, said: true) == nil)
        #expect(w.pending == nil)
        // Without following apps, a call says nothing.
        var plain = watch(followApps: false)
        #expect(plain.tick(at: at(600), calls: zoom, said: true) == nil)
        #expect(plain.pending?.reason == .silence)
    }

    @Test func nothingSaidStopsQuietlyAfterTheSilence() {
        var w = watch()
        #expect(w.tick(at: at(599), calls: [:], said: false) == nil)
        #expect(w.tick(at: at(600), calls: [:], said: false) == .nobodySpoke)
        #expect(w.pending == nil)
        // Even when silence only prompts: there is nothing to keep, so no countdown.
        var e = watch(.end)
        #expect(e.tick(at: at(600), calls: [:], said: false) == .nobodySpoke)
        // Off, or a meeting app in a call (a muted webinar), keeps listening.
        var off = watch(.off)
        #expect(off.tick(at: at(5_000), calls: [:], said: false) == nil)
        var call = watch()
        #expect(call.tick(at: at(5_000), calls: zoom, said: false) == nil)
    }

    @Test func nothingSaidKeepsListening() {
        var w = watch()
        _ = w.tick(at: at(10), calls: zoom, said: false)
        #expect(w.tick(at: at(500), calls: [:], said: false) == nil)
        #expect(w.pending == nil)
        // A call that ended before anyone spoke is forgotten once someone does.
        w.heard(at: at(5_001))
        #expect(w.tick(at: at(5_002), calls: [:], said: true) == nil)
        #expect(w.pending == nil)
    }

    @Test func callsCountOnlyMeetingAppsReadingAMic() {
        let calls = MicUsers.calls(
            readers: [.init(bundleID: "us.zoom.xos", inputs: [82]),
                      .init(bundleID: "com.tencent.meeting", inputs: []),
                      .init(bundleID: "com.google.Chrome.helper", inputs: [82])],
            running: ["us.zoom.xos": "Zoom", "com.tencent.meeting": "腾讯会议", "com.google.Chrome": "Google Chrome"])
        #expect(calls == ["us.zoom.xos": "Zoom"])
    }
}
