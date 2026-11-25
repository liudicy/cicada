import Foundation

/// A build run from a checkout rather than installed from a release, so the two can run side by
/// side and be told apart. `scripts/build.sh` without `RELEASE=1` stamps `LiveSubsDev` (branch and
/// commit) into Info.plist and gives the app its own bundle id (`com.wquguru.cicada.dev`): its own
/// settings, permissions, meeting records and log. `swift run` has no bundle at all.
enum DevBuild {
    /// Where it came from ("main @ 1b3d7f7"), "swift run", or nil for a release build.
    static let label: String? = {
        if let stamp = Bundle.main.object(forInfoDictionaryKey: "LiveSubsDev") as? String { return stamp }
        return Bundle.main.bundleIdentifier == nil ? "swift run" : nil
    }()

    static var isDev: Bool { label != nil }

    /// The fork release this build was packaged as ("1.1.1.1"), stamped into Info.plist by
    /// scripts/package-dev.sh. Its presence also opts the dev build into update checks, which
    /// then run against the fork's releases (see UpdateChecker).
    static let fork: String? = Bundle.main.object(forInfoDictionaryKey: "LiveSubsFork") as? String

    /// Folder name under ~/Library/Application Support.
    static var supportFolder: String { isDev ? "LiveSubs Dev" : "LiveSubs" }

    /// `CICADA_DEBUG_CHANNEL=x` (set with `open --env`, and for `tools/lsctl`) gives one running copy
    /// its own remote control and log, so two dev builds can be tested side by side.
    static let channel = ProcessInfo.processInfo.environment["CICADA_DEBUG_CHANNEL"].flatMap { $0.isEmpty ? nil : $0 }
    static var debugChannel: String { "com.wquguru.cicada.debug" + (channel.map { "." + $0 } ?? "") }

    static var logPath: String {
        let base = isDev ? "/tmp/livesubs-dev-debug" : "/tmp/livesubs-debug"
        return base + (channel.map { "-" + $0 } ?? "") + ".log"
    }
}
