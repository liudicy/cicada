import Foundation

/// The iOS counterpart of the Mac's `DevBuild` and `debugLog` (`Sources/LiveSubs/DevBuild.swift`,
/// `Settings.swift`): the shared sources call them by the same names. No /tmp on iOS, so the log
/// lives in the app container, where `xcrun simctl get_app_container booted <id> data` finds it.
enum DevBuild {
    /// Where it came from ("main @ 1b3d7f7"), or nil for a release build.
    static let label: String? = Bundle.main.object(forInfoDictionaryKey: "LiveSubsDev") as? String

    static var isDev: Bool { label != nil }

    /// Folder name under Application Support, kept the same as on the Mac.
    static var supportFolder: String { isDev ? "LiveSubs Dev" : "LiveSubs" }

    static var logPath: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDev ? "livesubs-dev-debug.log" : "livesubs-debug.log").path
    }
}

func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    let path = DevBuild.logPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Transcript content is only logged when the `debug` default is on, as on the Mac.
func contentLog(_ message: @autoclosure () -> String) {
    if UserDefaults.standard.bool(forKey: "debug") { debugLog(message()) }
}
