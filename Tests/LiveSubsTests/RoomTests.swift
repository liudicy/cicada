import Foundation
import Testing
@testable import LiveSubs

@Suite struct RoomTests {
    typealias In = RoomMicPlan.Input
    let builtIn = In(uid: "builtin", builtIn: true)
    let usb = In(uid: "usb")
    let airpods = In(uid: "airpods", bluetooth: true)
    let blackhole = In(uid: "blackhole", virtual: true)

    @Test func keepsTheChosenMicrophone() {
        #expect(RoomMicPlan.pick(defaultUID: "usb", inputs: [builtIn, usb, airpods]) == "usb")
        #expect(RoomMicPlan.pick(defaultUID: "builtin", inputs: [builtIn, usb]) == "builtin")
    }

    @Test func skipsTheVirtualMicAndHeadsets() {
        // 同声传译 makes BlackHole the default; AirPods hear the wearer, not the table.
        #expect(RoomMicPlan.pick(defaultUID: "blackhole", inputs: [blackhole, airpods, builtIn]) == "builtin")
        #expect(RoomMicPlan.pick(defaultUID: "airpods", inputs: [airpods, usb, builtIn]) == "builtin")
        #expect(RoomMicPlan.pick(defaultUID: "airpods", inputs: [airpods, usb]) == "usb")
    }

    @Test func aHeadsetIsBetterThanNothing() {
        #expect(RoomMicPlan.pick(defaultUID: "blackhole", inputs: [blackhole, airpods]) == "airpods")
        #expect(RoomMicPlan.pick(defaultUID: nil, inputs: [blackhole]) == nil)
    }

    @Test func asksAboutTheRoomAfterAQuietMinute() {
        #expect(!RoomPrompt.asks(room: false, listened: 30, voiced: 0))
        #expect(RoomPrompt.asks(room: false, listened: 61, voiced: 0))
        // Something played: it is an online meeting after all.
        #expect(!RoomPrompt.asks(room: false, listened: 300, voiced: 5))
        // Already listening to the room.
        #expect(!RoomPrompt.asks(room: true, listened: 300, voiced: 0))
    }

    @Test func notDuringACallOrOnceAnswered() {
        #expect(RoomPrompt.shows(silent: true, answered: false, inCall: false))
        #expect(!RoomPrompt.shows(silent: true, answered: true, inCall: false))
        #expect(!RoomPrompt.shows(silent: true, answered: false, inCall: true))
        #expect(!RoomPrompt.shows(silent: false, answered: false, inCall: false))
    }
}

@Suite struct VoiceGateTests {
    @Test func theMacsOwnAudioKeepsTheFixedLine() {
        var g = VoiceGate()
        let quiet = g.voiced(0.005), loud = g.voiced(0.02)
        #expect(!quiet)
        #expect(loud)
    }

    @Test func aQuietRoomHearsAQuietVoice() {
        // Room noise ~0.002, a voice across the table ~0.006: below -40 dBFS, still speech.
        var g = VoiceGate(adaptive: true)
        for i in 0..<120 { _ = g.voiced(i % 3 == 0 ? 0.002 : 0.006) }
        #expect(g.threshold < 0.006)
        let voice = g.voiced(0.006), noise = g.voiced(0.002)
        #expect(voice)
        #expect(!noise)
    }

    @Test func talkingOnAndOnKeepsTheRoomsFloor() {
        // Half a minute of steady talk: every second has one short gap between words at the room's level.
        var g = VoiceGate(adaptive: true)
        for i in 0..<(30 * VoiceGate.blocksPerSecond) { _ = g.voiced(i % VoiceGate.blocksPerSecond == 0 ? 0.002 : 0.012) }
        #expect(g.threshold < 0.005)
    }

    @Test func aNoisyRoomNeverGoesAboveTheFixedLine() {
        var g = VoiceGate(adaptive: true)
        for _ in 0..<120 { _ = g.voiced(0.02) }
        #expect(g.threshold == VoiceGate.fixed)
    }
}
