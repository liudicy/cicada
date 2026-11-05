import SwiftUI
import UIKit

/// The iOS side of the Mac's `AppModel.debugCommand`. `ios/scripts/ctl.sh <cmd>` writes the command
/// into the container's Caches/debug-command and posts a Darwin notification, which wakes us here;
/// `simctl openurl` with cicada-dev://debug?cmd=… works too but asks for confirmation every time.
/// Same names as on the Mac where the command means the same thing.
enum DebugChannel {
    static let name = "com.wquguru.cicada.debug" as CFString
    static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug-command")
    }

    @MainActor static func listen(_ model: AppModel) {
        guard DevBuild.isDev else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(model).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { DebugChannel.drain(model) } }
        }, name, nil, .deliverImmediately)
    }

    /// One command per line, run in order.
    @MainActor static func drain(_ model: AppModel) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        for line in text.split(separator: "\n") where !line.isEmpty { model.debugCommand(String(line)) }
    }
}

extension AppModel {
    func debugCommand(_ cmd: String) {
        debugLog("debug command: \(cmd)")
        let (name, arg) = cmd.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        switch name {
        case "open":
            tab = .records
            selection = nil
        case "settings":
            // iPhone: the tab; iPad: the sheet (the app can't tell which from here, so both).
            tab = .settings
            showSettings = true
        case "closeSettings":
            showSettings = false
            tab = .records
        case "listen", "start":
            startListening()
        case "window":
            // window:half|landscape|landscapeHalf|full: the iPad window drawn at that size (DevWindow).
            let s = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first ?? .zero
            let (short, long) = (min(s.width, s.height), max(s.width, s.height))
            switch arg {
            case "half": devWindow = CGSize(width: (short - 10) / 2, height: long)
            case "landscape": devWindow = CGSize(width: long, height: short)
            case "landscapeHalf": devWindow = CGSize(width: (long - 10) / 2, height: short)
            default: devWindow = nil
            }
            debugLog("window: \(arg) \(devWindow.map { "\($0)" } ?? "screen")")
        case "stop":
            stopListening()
        case "import":
            // What the import button shows until M3.
            comingSoon = L("导入录音或视频")
        case "livePage":
            livePage = arg == "notes" ? .notes : .subtitles
        case "source":
            // source:<locale>, 对方说 (en-US, ja-JP…)
            UserDefaults.standard.set(arg, forKey: Pref.source)
        case "target":
            // target:<code|system>, 翻译成
            UserDefaults.standard.set(arg, forKey: Pref.target)
        case "focusSpeaker":
            // focusSpeaker:<speaker number>, as tapping a chip; empty clears it
            focusSpeaker = Int(arg)
        case "play":
            NotificationCenter.default.post(name: .debugPlay, object: Double(arg) ?? 0)
        case "search":
            tab = .search
            searchPath = []
            query = arg
        case "mainShow":
            // mainShow:<id>[,transcript|notes]; an empty id is the newest meeting
            let parts = arg.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            tab = .records
            selection = parts.first.flatMap { id in store.sessions.contains(where: { $0.id == id }) ? id : nil }
                ?? store.sessions.first?.id
            if parts.count > 1 { recordPage = parts[1] == "notes" ? .notes : .transcript }
        case "back":
            selection = nil
            searchPath = []
            comingSoon = nil
        case "reload":
            store = SessionStore()
            notes = NotesEngine(ling: ling, store: store)
            wireNotes()
        case "generateNotes":
            // generateNotes:<id>, as the record page's 生成纪要 (needs a key).
            generateNotes(arg.isEmpty ? (selection ?? store.sessions.first?.id ?? "") : arg)
        case "rename":
            // rename:<id>,<title> (an empty title goes back to the automatic one)
            let parts = arg.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            rename(parts[0], to: parts.count > 1 ? parts[1] : "")
        case "delete":
            deleteSession(arg)
        case "speakers":
            UserDefaults.standard.set(arg == "on", forKey: Pref.voices)
            TranscriptExport.voices = arg == "on"
            objectWillChange.send()
        case "notesLang":
            UserDefaults.standard.set(arg, forKey: Pref.notesLanguage)
        case "nameSpeaker":
            // nameSpeaker:<id>,<voice>,<name>
            let p = arg.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if p.count == 3, let v = Int(p[1]) { renameSpeaker(session: p[0], voice: v, p[2]) }
        case "mergeSpeaker":
            // mergeSpeaker:<id>,<from voice>,<into voice>
            let p = arg.split(separator: ",").map(String.init)
            if p.count == 3, let a = Int(p[1]), let b = Int(p[2]) { mergeSpeaker(session: p[0], a, into: b) }
        case "speakerPrompt":
            // speakerPrompt:<speaker number>: the 是谁 prompt a chip's 改名字 opens
            namingSpeaker = Int(arg)
        case "undoSpeaker":
            undoSpeakerEdit()
        case "state":
            debugLog("room running=\(room.isRunning) lines=\(room.lines.count) draft=\(room.draft.count) level=\(room.level) status=\(room.status) session=\(room.sessionID ?? "-")")
            debugLog("state tab=\(tab.rawValue) selection=\(selection ?? "-") page=\(recordPage) sessions=\(store.sessions.count) query=\(query) notesLang=\(notesLanguageCode(selection ?? store.sessions.first?.id ?? "")) undo=\(speakerUndo?.text ?? "-")")
        default:
            debugLog("debug command unknown: \(cmd)")
        }
    }
}

/// Dev only: the iPad windows the simulator can't be put into from a script. There is no
/// Simulator.app to rotate it, iPadOS refuses a programmatic rotation in windowed mode, and no API
/// sizes a window. So the app is laid out at that window's size and size class, scaled to fit.
struct DevWindow: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if let size = model.devWindow {
            GeometryReader { geo in
                let scale = min(1, geo.size.width / size.width, geo.size.height / size.height)
                content
                    // iPadOS gives a window regular width from about 678 points.
                    .environment(\.horizontalSizeClass, size.width >= 678 ? .regular : .compact)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .background(Color(white: 0.3).ignoresSafeArea())
        } else {
            content
        }
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
