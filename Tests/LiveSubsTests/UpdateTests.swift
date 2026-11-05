import Foundation
import Testing
@testable import LiveSubs

@Suite struct UpdateTests {
    @Test func versionsCompareNumerically() {
        #expect(UpdateChecker.isNewer("2.10.0", than: "2.9.1"))
        #expect(UpdateChecker.isNewer("2.0.1", than: "2.0"))
        #expect(!UpdateChecker.isNewer("2.0", than: "2.0.0"))
        #expect(!UpdateChecker.isNewer("1.9.9", than: "2.0.0"))
        #expect(!UpdateChecker.isNewer("2.0.0", than: "2.0.0"))
    }

    @Test func checksumIsFoundByName() {
        let file = Data("""
            AAA111  Cicada-2.1.0-macOS-AppleSilicon.dmg
            BBB222 *Cicada-2.1.0-macOS-AppleSilicon.zip
            """.utf8)
        #expect(Updater.expectedHash(of: "Cicada-2.1.0-macOS-AppleSilicon.zip", in: file) == "bbb222")
        #expect(Updater.expectedHash(of: "Cicada-2.1.0-macOS-AppleSilicon.dmg", in: file) == "aaa111")
        #expect(Updater.expectedHash(of: "Cicada-2.0.0-macOS-AppleSilicon.zip", in: file) == nil)
    }
}

@Suite struct UpdateReleaseTests {
    static func release(_ tag: String, _ assets: [String], prerelease: Bool = false) -> String {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://x/\#($0)","size":1}"# }
        return #"{"tag_name":"\#(tag)","html_url":"https://x/\#(tag)","prerelease":\#(prerelease),"assets":[\#(list.joined(separator: ","))]}"#
    }

    static func newest(_ releases: [String]) -> String? {
        UpdateChecker.decode(Data("[\(releases.joined(separator: ","))]".utf8))
            .flatMap(UpdateChecker.newestMac)?.version
    }

    @Test func aReleaseWithoutTheMacZipIsSkipped() {
        let mac = Self.release("v1.1.0", ["Cicada-1.1.0-macOS-AppleSilicon.zip", "checksums.txt"])
        let windows = Self.release("v1.2.0", ["Cicada-1.2.0-Windows-x64.zip", "checksums.txt"])
        #expect(Self.newest([windows, mac]) == "1.1.0")
        #expect(Self.newest([windows]) == nil)
    }

    @Test func prereleasesAreSkippedAndNewestWins() {
        let old = Self.release("v1.0.0", ["Cicada-1.0.0-macOS-AppleSilicon.zip"])
        let new = Self.release("v1.10.0", ["Cicada-1.10.0-macOS-AppleSilicon.zip"])
        let beta = Self.release("v2.0.0", ["Cicada-2.0.0-macOS-AppleSilicon.zip"], prerelease: true)
        #expect(Self.newest([beta, old, new]) == "1.10.0")
    }

    @Test func aSingleReleaseFeedStillWorks() {
        let one = Self.release("v1.3.0", ["Cicada-1.3.0-macOS-AppleSilicon.zip"])
        #expect(UpdateChecker.decode(Data(one.utf8)).flatMap(UpdateChecker.newestMac)?.version == "1.3.0")
    }
}

@Suite struct UpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func dueWhenNeverCheckedOrOldEnough() {
        #expect(UpdateChecker.due(last: nil, now: now, after: UpdateChecker.every))
        #expect(UpdateChecker.due(last: now.addingTimeInterval(-4 * 3600), now: now, after: UpdateChecker.every))
        #expect(!UpdateChecker.due(last: now.addingTimeInterval(-3 * 3600), now: now, after: UpdateChecker.every))
        // Waking or opening the panel checks once the last check is an hour old.
        #expect(UpdateChecker.due(last: now.addingTimeInterval(-3601), now: now, after: UpdateChecker.stale))
        #expect(!UpdateChecker.due(last: now.addingTimeInterval(-600), now: now, after: UpdateChecker.stale))
    }

    /// A clock set back must not stop checks until it catches up.
    @Test func dueWhenLastCheckIsInTheFuture() {
        #expect(UpdateChecker.due(last: now.addingTimeInterval(86_400), now: now, after: UpdateChecker.every))
    }

    @MainActor @Test func checkedAgoWording() {
        #expect(Updates.checkedAgo(now.addingTimeInterval(-20), now: now) == L("刚刚查过"))
        #expect(Updates.checkedAgo(now.addingTimeInterval(-5 * 60), now: now) == L("5 分钟前查过"))
        #expect(Updates.checkedAgo(now.addingTimeInterval(-2 * 3600 - 59), now: now) == L("2 小时前查过"))
        #expect(Updates.checkedAgo(now.addingTimeInterval(-3 * 86_400), now: now) == L("3 天前查过"))
    }

    /// One notification per version, and none while a meeting or speaking is on.
    @Test func notifiesOncePerVersionWhenIdle() {
        #expect(Updates.shouldNotify("1.1.0", notified: nil, busy: false))
        #expect(Updates.shouldNotify("1.2.0", notified: "1.1.0", busy: false))
        #expect(!Updates.shouldNotify("1.1.0", notified: "1.1.0", busy: false))
        #expect(!Updates.shouldNotify("1.1.0", notified: nil, busy: true))
    }
}

@Suite struct UpdateMinimumSystemTests {
    @Test func comparesMinimumMacOS() {
        let os = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        #expect(Updater.runs("14.4", on: os))
        #expect(Updater.runs("14.5", on: os))
        #expect(!Updater.runs("15.0", on: os))
        #expect(!Updater.runs("26.0", on: os))
        #expect(Updater.runs("14", on: os))
    }
}
