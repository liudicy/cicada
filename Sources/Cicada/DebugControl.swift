import AppKit
import Foundation

/// The reply to one `tools/lsctl` command. lsctl waits for it by id instead of grepping the log, so an
/// agent knows a command ran, failed or doesn't exist from the exit code alone. A command sent without
/// an id (an older lsctl) gets no reply, as before.
struct DebugReply {
    var id: String
    var ok = true
    var error: (code: String, message: String)?
    /// JSON-safe values only (`JSONSerialization`).
    var data: Any?
    /// What the command logged while it ran on the main thread; later lines (from Tasks) stay in the log.
    var log: [String] = []

    /// A distributed notification carries the reply, so it stays small: the newest lines win.
    static let maxLogLines = 200
    static let maxLogBytes = 48_000

    func json() -> String {
        var lines = Array(log.suffix(Self.maxLogLines))
        while lines.reduce(0, { $0 + $1.utf8.count }) > Self.maxLogBytes, !lines.isEmpty { lines.removeFirst() }
        var o: [String: Any] = ["id": id, "ok": ok, "log": lines]
        if let error { o["error"] = ["code": error.code, "message": error.message] }
        if let data, JSONSerialization.isValidJSONObject(["d": data]) { o["data"] = data }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else {
            return #"{"id":"\#(id)","ok":false,"error":{"code":"encode","message":"reply not JSON"}}"#
        }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Lines logged on the main thread while a debug command runs (see `debugLog`).
nonisolated(unsafe) var debugLogCapture: [String]?

/// The command being run: cases mark a failure or hand back data through it.
@MainActor enum DebugRun {
    static var reply: DebugReply?
}

/// A debug command couldn't do what it was asked: logged, and the reply says so (lsctl exits 1).
/// It writes `DebugRun.reply`, so never call it (or what calls it) from the right side of an
/// assignment to `DebugRun.reply?.…`: overlapping access aborts. Build the value first.
@MainActor func debugFail(_ message: String, code: String = "failed") {
    debugLog(message)
    DebugRun.reply?.ok = false
    DebugRun.reply?.error = (code, message)
}

extension AppModel {
    func runDebugCommand(_ cmd: String, id: String?) {
        guard let id else { debugCommand(cmd); return }
        DebugRun.reply = DebugReply(id: id)
        debugLogCapture = []
        debugCommand(cmd)
        var reply = DebugRun.reply ?? DebugReply(id: id)
        reply.log = debugLogCapture ?? []
        debugLogCapture = nil
        DebugRun.reply = nil
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(DevBuild.debugChannel + ".reply"), object: reply.json(), userInfo: nil, deliverImmediately: true)
    }

    /// `state[:section,…]`: what the app is doing now, as JSON, for agents (`lsctl state`, `lsctl --wait`).
    /// Read straight from the engines, never a copy. No keys or tokens, only whether there is one;
    /// what was said only with the debug setting on, as in the log.
    func debugSnapshot(_ only: [String]) -> [String: Any] {
        let content = settings.debug
        var all: [String: () -> Any] = [:]
        all["build"] = { [
            "version": Updates.current, "dev": DevBuild.isDev, "label": DevBuild.label ?? "",
            "channel": DevBuild.channel ?? "", "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ] }
        all["permissions"] = { [
            "systemAudio": self.systemAudioOK, "systemAudioRefused": self.systemAudioRefused, "speech": self.speechOK,
            "mic": String(describing: self.micStatus.rawValue), "talkNeedsPermission": self.talkNeedsPermission,
        ] }
        all["listen"] = { [
            "running": self.listen.isRunning, "status": self.status, "source": self.settings.listenSource,
            "sourceSelection": self.sourceSelection, "lang": self.listen.activeLang?.locale ?? "",
            "target": self.settings.target, "recognizer": Recognition.name, "recordTrack": Recognition.recordTrack,
            "identifyingLanguage": self.identifyingLanguage, "liveID": self.store.liveID ?? "",
            "autoEnded": self.autoEnded, "endPending": self.ending.map { "\($0.reason)" } ?? "",
            "cloud": [
                "service": self.cloud.service ?? "", "offered": self.cloud.offered, "listening": self.cloud.listening,
            ] as [String: Any],
            "modelProblem": self.modelProblem.map { "\($0)" } ?? "",
            "translation": [
                "googleDown": self.translationHealth.googleDown, "googleOff": self.translationHealth.googleOff,
                "sentencesUntranslated": self.translationHealth.sentencesUntranslated,
            ],
        ].merging(content ? ["liveSource": self.liveSource, "liveTranslation": self.liveTranslation] : [:]) { a, _ in a } }
        all["room"] = { [
            "running": self.roomListen.isRunning, "lang": self.roomListen.activeLang?.locale ?? "",
            "echo": String(describing: self.roomListen.echoGate.echo), "echoCancelled": self.roomListen.hearsEchoCancelled,
            "music": self.roomListen.echoGate.playingMusic(), "micSilent": self.roomMicSilent,
            "micLost": self.roomMicLost ?? "", "micDenied": self.hybridMicDenied, "held": self.heldRoom.count,
            "voicedSeconds": self.roomListen.router.stats().voicedTotal,
            // The microphone it hears now, the one chosen beside 打开麦克风 ("" = 自动) and the choices.
            "mic": (self.settings.hearsBoth ? self.roomListen : self.listen).roomMicUID ?? "",
            "micChosen": self.settings.roomMicUID,
            "mics": AudioDevices.roomMicChoices().map { "\($0.device.uid)=\($0.device.name)" },
        ] }
        all["display"] = { [
            "mode": self.settings.displayMode, "notesShown": self.notesShown,
            "notesWindow": [
                "visible": self.notesWindow.isVisible, "layout": "\(self.notesWindow.layout)",
                "frame": self.notesWindow.frame.map { [$0.origin.x, $0.origin.y, $0.width, $0.height] } ?? [],
            ] as [String: Any],
            "overlay": ["shown": self.overlay.isShown, "expanded": self.overlay.expanded],
            "keyWindow": NSApp.keyWindow?.title ?? "",
            "onboardingStep": self.onboardingStep, "mainShow": self.mainShow ?? "",
            "dock": ["shown": NSApp.activationPolicy() == .regular, "setting": self.settings.showInDock, "live": DockIcon.live],
        ] }
        all["notes"] = { [
            "state": "\(self.notes.state)", "topics": self.notes.notes.topics.count,
            "covered": self.notes.notes.covered, "glossary": self.notes.glossary.count, "fresh": self.notes.fresh.count,
        ] }
        all["speak"] = { [
            "enabled": self.settings.speakEnabled, "phase": "\(self.speakPhase)", "mic": self.speak.micDeviceName,
            "output": self.speak.outputDevice()?.name ?? "", "voiceMicInUse": self.voiceMic.inUse,
            "handsFree": self.speak.handsFree,
            "test": ["shown": self.speakTestShown, "phase": "\(self.speakTester.phase)"] as [String: Any],
        ] }
        all["ai"] = { [
            "keyState": "\(self.ling.keyState)", "hasKey": self.ling.hasKey,
            "provider": self.settings.aiConfig.provider.id.rawValue, "model": self.settings.aiConfig.textModel,
            "check": self.ling.aiCheck.summary,
        ] }
        all["import"] = { [
            "current": self.importer.current?.id ?? "", "phase": "\(self.importer.phase)",
            "queue": self.importer.queue.map(\.id),
        ] }
        all["update"] = { [
            "current": Updates.current, "found": self.updates.update?.version ?? "",
            "check": "\(self.updates.check)", "failure": self.updates.failure ?? "",
        ] }
        all["records"] = { [
            "count": self.store.sessions.count, "latest": self.store.sessions.first?.id ?? "",
        ] }
        all["problem"] = { self.problem ?? "" }

        var out: [String: Any] = ["schema": 1, "at": ISO8601DateFormatter().string(from: Date())]
        let keys = only.isEmpty ? Array(all.keys) : only
        for k in keys {
            if let f = all[k] { out[k] = f() } else { debugFail("state: no section \(k) (have \(all.keys.sorted().joined(separator: ",")))", code: "bad_argument") }
        }
        return out
    }
}
