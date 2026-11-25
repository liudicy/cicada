import Foundation
import Testing
@testable import Cicada

@Suite struct MicUsersTests {
    let virtual: UInt32 = 87
    let builtIn: UInt32 = 82
    let names: [UInt32: String] = [87: "BlackHole 2ch", 82: "MacBook Pro 麦克风"]

    @Test func helperProcessesBelongToTheirApp() {
        let running: Set<String> = ["com.google.Chrome", "com.apple.Safari", "us.zoom.xos"]
        #expect(MicUsers.owner(of: "com.google.Chrome.helper", running: running) == "com.google.Chrome")
        #expect(MicUsers.owner(of: "com.google.Chrome.helper.renderer", running: running) == "com.google.Chrome")
        #expect(MicUsers.owner(of: "us.zoom.xos", running: running) == "us.zoom.xos")
        #expect(MicUsers.owner(of: "com.apple.WebKit.GPU", running: running) == "com.apple.Safari")
        #expect(MicUsers.owner(of: "com.apple.WebKit.GPU", running: ["us.zoom.xos"]) == nil)
        #expect(MicUsers.owner(of: "org.example.tool", running: running) == nil)
    }

    @Test func mergeSortsProblemsFirstAndListsIdleMeetingApps() {
        let users = MicUsers.merge(
            readers: [.init(bundleID: "us.zoom.xos", inputs: [virtual]),
                      .init(bundleID: "com.tencent.meeting", inputs: [builtIn]),
                      .init(bundleID: "com.google.Chrome.helper", inputs: [])],
            running: ["us.zoom.xos": "Zoom", "com.tencent.meeting": "腾讯会议", "com.microsoft.teams2": "Microsoft Teams",
                      "com.google.Chrome": "Google Chrome"],
            virtualMic: virtual, deviceName: { names[$0] }, ownBundleID: "com.wquguru.cicada")
        #expect(users.map(\.name) == ["腾讯会议", "Zoom", "Microsoft Teams"])
        #expect(users.map(\.state) == [.otherMic("MacBook Pro 麦克风"), .virtualMic, .idle])
    }

    @Test func anyVirtualInputCountsAndOwnAppIsHidden() {
        let users = MicUsers.merge(
            readers: [.init(bundleID: "com.google.Chrome.helper", inputs: [builtIn]),
                      .init(bundleID: "com.google.Chrome.helper", inputs: [virtual]),
                      .init(bundleID: "com.wquguru.cicada", inputs: [virtual])],
            running: ["com.google.Chrome": "Google Chrome", "com.wquguru.cicada": "知了"],
            virtualMic: virtual, deviceName: { names[$0] }, ownBundleID: "com.wquguru.cicada")
        #expect(users == [MicUser(bundleID: "com.google.Chrome", name: "Google Chrome", state: .virtualMic)])
    }

    @Test func larkWeComAndWebexMeetingsAreCalls() {
        let calls = MicUsers.calls(
            readers: [.init(bundleID: "com.larksuite.larkApp.helper", inputs: [builtIn]),
                      .init(bundleID: "com.tencent.WeWorkMac", inputs: [builtIn]),
                      .init(bundleID: "com.webex.meetingmanager", inputs: [builtIn]),
                      .init(bundleID: "com.tencent.xinWeChat", inputs: [builtIn])],
            running: ["com.larksuite.larkApp": "Lark", "com.tencent.WeWorkMac": "企业微信",
                      "com.webex.meetingmanager": "Webex Meetings", "com.tencent.xinWeChat": "微信"])
        // 微信 reads the mic for a voice message too: that isn't a call.
        #expect(calls == ["com.larksuite.larkApp": "Lark", "com.tencent.WeWorkMac": "企业微信",
                          "com.webex.meetingmanager": "Webex Meetings"])
    }

    @Test func applesOwnMicReadersAreNotMeetings() {
        let users = MicUsers.merge(
            readers: [.init(bundleID: "com.apple.Sound-Settings.extension", inputs: [builtIn]),
                      .init(bundleID: "com.apple.FaceTime", inputs: [builtIn])],
            running: ["com.apple.Sound-Settings.extension": "Sound (System Settings)", "com.apple.FaceTime": "FaceTime"],
            virtualMic: virtual, deviceName: { names[$0] }, ownBundleID: "com.wquguru.cicada")
        #expect(users.map(\.name) == ["FaceTime"])
    }
}
