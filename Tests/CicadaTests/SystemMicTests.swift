import Foundation
import Testing
@testable import Cicada

@Suite struct SystemMicTests {
    let builtIn = SystemMicPlan.Device(uid: "BuiltInMicrophoneDevice", isVirtual: false)
    let airpods = SystemMicPlan.Device(uid: "airpods", isVirtual: false)
    let blackhole = SystemMicPlan.Device(uid: "BlackHole2ch_UID", isVirtual: true)
    var all: [SystemMicPlan.Device] { [blackhole, builtIn, airpods] }

    @Test func savedMicComesBackWhilePluggedIn() {
        #expect(SystemMicPlan.original(saved: "airpods", current: blackhole.uid, inputs: all) == "airpods")
    }

    @Test func unpluggedSavedMicFallsBackToARealOne() {
        #expect(SystemMicPlan.original(saved: "airpods", current: blackhole.uid, inputs: [blackhole, builtIn]) == builtIn.uid)
    }

    @Test func currentRealMicIsTheOriginalWhenNothingIsSaved() {
        #expect(SystemMicPlan.original(saved: "", current: "airpods", inputs: all) == "airpods")
    }

    /// The user had already picked BlackHole as the system mic by hand: "back" must still be a real mic.
    @Test func neverRestoresToTheVirtualMic() {
        #expect(SystemMicPlan.original(saved: "", current: blackhole.uid, inputs: all) == builtIn.uid)
        #expect(SystemMicPlan.original(saved: blackhole.uid, current: blackhole.uid, inputs: all) == builtIn.uid)
        #expect(SystemMicPlan.original(saved: "", current: blackhole.uid, inputs: [blackhole]) == nil)
    }

    @Test func recordingUsesTheChosenMicElseTheOriginal() {
        #expect(SystemMicPlan.recording(chosen: "airpods", saved: builtIn.uid, current: blackhole.uid, inputs: all) == "airpods")
        #expect(SystemMicPlan.recording(chosen: "", saved: builtIn.uid, current: blackhole.uid, inputs: all) == builtIn.uid)
        // A chosen mic that's unplugged, or the virtual mic itself, is skipped.
        #expect(SystemMicPlan.recording(chosen: "gone", saved: "", current: "airpods", inputs: all) == "airpods")
        #expect(SystemMicPlan.recording(chosen: blackhole.uid, saved: "", current: blackhole.uid, inputs: all) == builtIn.uid)
    }
}
