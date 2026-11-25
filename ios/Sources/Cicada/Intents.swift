import AppIntents
import Foundation

// 快速开始: 开始听 for the Action button, Control Center and Siri, and the Live Activity's 暂停 and
// 结束并出纪要. Compiled into the app and into the CicadaLive extension (its Control Center button
// names the intent); every intent runs in the app, which hands it to AppModel through `IntentHub`.

@MainActor
enum IntentHub {
    /// Set by AppModel. An intent that comes before it (the app launched by the intent) is kept
    /// in `pending` and run once AppModel is there.
    static var run: ((Action) -> Void)? {
        didSet { if let run, let p = pending { pending = nil; run(p) } }
    }
    static var pending: Action?

    enum Action { case start, stop, togglePause }

    static func send(_ a: Action) {
        if let run { run(a) } else { pending = a }
    }
}

struct StartListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "开始听"
    static let description = IntentDescription("用麦克风听会议室，出实时双语字幕和纪要")
    /// The microphone starts with the app in front: iOS won't start recording from the background.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentHub.send(.start)
        return .result()
    }
}

struct StopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束并出纪要"
    static let description = IntentDescription("结束正在听的会议，有 key 时整理纪要")

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentHub.send(.stop)
        return .result()
    }
}

struct PauseListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暂停或继续听"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentHub.send(.togglePause)
        return .result()
    }
}

#if !CICADA_LIVE
/// Siri and Spotlight (the app's only; the extension builds with CICADA_LIVE). Phrases in the languages people ask in; each must name the app.
struct CicadaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartListeningIntent(), phrases: [
            "用\(.applicationName)开始听",
            "\(.applicationName)开始听",
            "Start listening with \(.applicationName)",
            "\(.applicationName) start listening",
        ], shortTitle: "开始听", systemImageName: "mic.fill")
        AppShortcut(intent: StopListeningIntent(), phrases: [
            "\(.applicationName)结束",
            "Stop \(.applicationName)",
        ], shortTitle: "结束并出纪要", systemImageName: "stop.fill")
    }
}
#endif
