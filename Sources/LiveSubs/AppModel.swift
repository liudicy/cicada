import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Wires the engines, the meeting store, the subtitle bar and the UI together.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let store = SessionStore()
    let overlay = OverlayController()
    let talkCombo = HotKey(id: 1, shortcut: .defaultTalk)
    let talkRight = RightOptionKey()
    let toggleKey = HotKey(id: 2, shortcut: .defaultToggle)
    lazy var listen = ListenEngine(settings: settings)
    lazy var speak = SpeakEngine(settings: settings)
    lazy var speakTester = SpeakTester(speak: speak, ling: ling, settings: settings)
    /// Key released → the room heard the first sound, from the latest real press or sound test.
    @Published var lastSpeakLatency: Double? = UserDefaults.standard.object(forKey: "lastSpeakLatency") as? Double {
        didSet { UserDefaults.standard.set(lastSpeakLatency, forKey: "lastSpeakLatency") }
    }
    /// The 试一句 sheet in settings.
    @Published var speakTestShown = false
    /// The panel is asking, the first time, what turning 同声传译 on changes.
    @Published var speakAsking = false
    /// Meeting apps and the microphone each reads; refreshed every second once the virtual mic exists.
    @Published var micUsers: [MicUser] = []
    lazy var systemMic = SystemMic(settings: settings)
    /// Whether the system default input is the virtual mic, and anything left to put back.
    @Published private(set) var systemMicState: SystemMic.State = .off
    /// The app whose "怎么改" sheet is open in Settings.
    @Published var micGuide: MicUser?
    /// Settings › 同声传译: the voice list under "对方听到" is open.
    @Published var voicePickerOpen = false

    @Published var running = false
    /// The meeting is about to end by itself (a hang-up or a long silence) unless someone keeps it going.
    @Published private(set) var ending: MeetingEndWatch.Pending?
    /// The last meeting ended by itself: the menu says so, and the next call in a meeting app starts a new one.
    @Published private(set) var autoEnded = false
    /// The notes window is on screen: the menu bar panel's 显示 / 收起 follows it.
    @Published private(set) var notesShown = false
    private var endWatch: MeetingEndWatch?
    private var endTimer: Timer?
    /// Debug: meeting apps in a call instead of what Core Audio says, and shorter waits.
    private var fakeCalls: [String: String]?
    private var endTimesOverride: (silence: Double, countdown: Double, grace: Double)?
    @Published var status = L("准备就绪")
    @Published var summary = ""
    @Published var installed: Set<String> = []
    @Published var candidates: [Lang] = []
    @Published var outputs: [OutputDevice] = []
    @Published var speakPhase: SpeakEngine.Phase = .idle
    @Published var settingsSection: SettingsSection =
        SettingsSection(rawValue: UserDefaults.standard.string(forKey: "settingsSection") ?? "") ?? .speak {
        didSet {
            UserDefaults.standard.set(settingsSection.rawValue, forKey: "settingsSection")
            // People pick a voice and move on: don't greet them with the list still open next time.
            if settingsSection != oldValue { voicePickerOpen = false }
        }
    }
    @Published var systemAudioOK = false
    @Published var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var liveSource = ""
    @Published var liveTranslation = ""
    @Published var onboardingStep = 1
    /// Step 3 is showing what skipping the key leaves out (debug: `onboarding:3,skip`).
    @Published var onboardingKeySkip = false
    /// Step 4's yes/no (false) or checklist (true); nil follows whether speaking is on
    /// (debug: `onboarding:4,ask` / `onboarding:4,setup`).
    @Published var onboardingSpeakSetup: Bool?
    /// Debug: which meeting and tab the main window shows ("<id>" or "<id>,transcript").
    @Published var mainShow: String?
    /// Hold right ⌥ is chosen but "输入监控" isn't allowed yet.
    @Published var talkNeedsPermission = false
    @Published var toggleKeyTaken = false
    private var permissionPoll: Timer?
    private var shortcutsSuspended = false
    let installer = VirtualMicInstaller()
    let ling = LingClient()
    let cloudASR = CloudASRClient()
    lazy var translator = TranslationService(ling: ling)
    let diagnostics = Diagnostics()
    let updates = Updates()
    let loginItem = LoginItem()
    lazy var notes = NotesEngine(ling: ling, store: store)
    lazy var notesWindow = NotesWindowController(model: self)
    let sample = SamplePlayer()
    let speakers = SpeakerTagger()
    lazy var speakerNamer = SpeakerNamer(ling: ling, store: store)
    /// Set by the notes window; the records window's people row opens that voice's editor.
    @Published var speakerEdit: SpeakerEditRequest?
    private var speakerSetting: AnyCancellable?
    private var asrSetting: AnyCancellable?
    var openOnboarding: (() -> Void)?

    var openMainWindow: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var showPanel: (() -> Void)?

    private var lineForSegment: [Int: String] = [:]
    private var lineCounter = 0
    /// The other side's last recorded line, which the next one may carry on (`HeardText.continues`).
    private var lastHeard: (seg: Segment, line: String)?
    /// A line that may carry on `lastHeard`, waiting to hear whose voice it is; its translation if
    /// that comes first.
    private var heldJoin: (seg: Segment, t: Double, translation: String?)?

    init() {
        listen.onSubtitle = { [weak self] src, dst in
            self?.liveSource = src
            self?.liveTranslation = dst
            if !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self?.heardSpeech(); self?.heardWords() }
            guard let self, self.settings.displayMode == "bar" else { return }
            self.overlay.clearStatus()
            let shown = self.displayed(src, dst)
            self.overlay.setSubtitle(source: shown.source, translation: shown.translation)
        }
        listen.onStatus = { [weak self] text in
            self?.status = text
            self?.overlay.setStatus(text)
        }
        listen.onStateChange = { [weak self] in self?.refresh() }
        listen.onFinal = { [weak self] seg, duration in self?.recordHeard(seg, duration: duration) }
        speakers.onVoice = { [weak self] line, voice in
            guard let self else { return }
            self.store.setVoice(lineID: line, voice)
            if let id = self.store.liveID { self.speakerNamer.guess(id) }
        }
        speakerSetting = settings.$speakerVoices.sink { [weak self] on in
            guard let self else { return }
            TranscriptExport.voices = on
            // Cloud proofreading also needs the sentence audio (see CloudASRClient).
            self.listen.router.setVoiceCapture(on || self.settings.cloudASREnabled)
        }
        listen.onTranslated = { [weak self] segID, text in
            guard let self else { return }
            if self.heldJoin?.seg.id == segID { self.heldJoin?.translation = text }
            guard let line = self.lineForSegment[segID] else { return }
            self.store.setTranslation(lineID: line, text)
        }

        diagnostics.enabled = { [weak self] in self?.settings.diagnostics ?? false }
        diagnostics.folder = { [weak self] in
            guard let self, let id = self.store.liveID else { return nil }
            return self.store.folder(id)
        }
        listen.onTiming = { [weak self] in self?.diagnostics.record($0) }
        speak.onTiming = { [weak self] in self?.diagnostics.record($0) }
        speak.onLatency = { [weak self] in self?.lastSpeakLatency = $0 }
        speakTester.onLatency = { [weak self] in self?.lastSpeakLatency = $0 }
        speakTester.translate = { [weak self] text, from, to in
            await self?.listen.translate(text, source: from, target: to, kind: .speak, trace: TranslateTrace())
        }
        ling.onCall = { [weak self] in self?.diagnostics.record($0) }

        ling.provider = { [weak self] in self?.activeAIProvider ?? .ling }
        ling.model = { [weak self] in self?.activeAIProvider.model ?? "Ling-3.1-flash" }
        cloudASR.base = { [weak self] in self?.settings.cloudASRBase ?? CloudASRClient.defaultBase }
        cloudASR.model = { [weak self] in self?.settings.cloudASRModel ?? CloudASRClient.defaultModel }
        asrSetting = settings.$cloudASREnabled.sink { [weak self] on in
            guard let self else { return }
            self.listen.router.setVoiceCapture(on || self.settings.speakerVoices)
        }
        listen.translator = translator
        translator.glossary = { [weak self] in self?.notes.glossary ?? [] }
        notes.language = { [weak self] id in
            TranslationService.englishName(self?.notesLanguageCode(id) ?? "zh-CN")
        }
        listen.translationOff = { [weak self] in self?.subtitles == "original" }
        // Room meetings record a real microphone, never the virtual one (our own voice).
        listen.micDevice = { [weak self] in self?.systemMic.recordingDevice }
        if ling.hasKey { Task { await ling.check() } }

        installer.speakThrough = { [weak self] text, lang, device in
            await self?.speak.speak(text, language: lang, device: device)
        }
        installer.onLoaded = { [weak self] in self?.virtualMicInstalled() }

        speak.translate = { [weak self] text, from, to, trace in
            await self?.listen.translate(text, source: from, target: to, kind: .speak, trace: trace)
        }
        speak.interpret = { [weak self] wav, from, to, trace in
            await self?.translator.interpret(wav: wav, source: from, target: to, trace: trace)
        }
        speak.roomLanguage = { [weak self] in self?.listen.activeLang?.code }
        speak.inputDevice = { [weak self] in self?.systemMic.recordingDevice }
        applyVoice()
        speak.onStatus = { [weak self] text in self?.status = text }
        speak.onLive = { [weak self] phase, src, dst in
            guard let self else { return }
            self.speakPhase = phase
            // A 试一句 rehearsal shows in its own sheet: no notes window, caption or subtitle bar.
            if self.speakTester.busy { return }
            if phase == .listening && !src.isEmpty { self.heardSpeech(); self.heardWords() }
            guard self.settings.displayMode == "bar" else {
                // The notes window's caption line shows what you are saying.
                if phase != .idle || !src.isEmpty {
                    self.liveSource = src.isEmpty ? L("你正在说…") : L("你：\(src)")
                    self.liveTranslation = dst
                }
                return
            }
            if !self.overlay.isShown { self.overlay.show() }
            if phase == .idle && src.isEmpty {
                self.overlay.setSpeaking(nil)
            } else {
                self.overlay.setSpeaking(.init(phase: phase, source: src, translation: dst))
            }
        }
        speak.onUtterance = { [weak self] src, dst, from, to, ago in
            self?.recordSaid(src, dst, from: from, to: to, secondsAgo: ago)
        }

        let began: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speak.pressBegan() } }
        }
        let ended: () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speak.pressEnded() } }
        }
        talkCombo.onDown = began
        talkCombo.onUp = ended
        talkRight.onDown = began
        talkRight.onUp = ended
        talkRight.onCancel = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.speak.pressCancelled() } }
        }
        overlay.onCollapsed = { [weak self] in
            self?.listen.clearDisplay()
            self?.overlay.setSubtitle(source: "", translation: "")
        }
        overlay.mode = { [weak self] in
            (self?.settings.overlayAuto ?? true, self?.settings.overlayHideAfter ?? 4)
        }
        toggleKey.onDown = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.cycleDisplay() } }
        }
        applyToggleKey()
        refreshOutputs()
        let watch = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchEnd() }
        }
        endTimer = watch
        RunLoop.main.add(watch, forMode: .common)
    }

    func setOverlayAuto(_ on: Bool) {
        settings.overlayAuto = on
        overlay.modeChanged()
        objectWillChange.send()
    }

    func launch() async {
        await listen.refreshInstalledLocales()
        refresh()
        start()
        if settings.speakEnabled { enableSpeaking(true) }
    }

    func refresh() {
        running = listen.isRunning
        // Once the tap has run, the permission is there: pausing doesn't take it away.
        systemAudioOK = systemAudioOK || listen.isRunning
        summary = listen.languageSummary()
        candidates = listen.candidates
        installed = listen.installedLocales
        if running { status = listen.statusText }
    }

    func refreshOutputs() {
        outputs = AudioDevices.outputs()
    }

    var virtualMic: OutputDevice? { outputs.first(where: \.isVirtualMic) }

    // MARK: Permissions (all from the UI, no Terminal)

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micStatus { micStatus = mic }
        let devices = AudioDevices.outputs()
        if devices.map(\.uid) != outputs.map(\.uid) { outputs = devices }
        if listen.isRunning && !systemAudioOK { systemAudioOK = true }
        refreshMicUsers()
        refreshSystemMic()
    }

    // MARK: System microphone

    /// Switching the system mic only helps when our voice goes into the virtual mic.
    var wantsSystemMic: Bool {
        guard settings.speakEnabled, settings.autoSystemMic, virtualMic != nil else { return false }
        return settings.speakOutput.isEmpty || (outputs.first { $0.uid == settings.speakOutput }?.isVirtualMic ?? true)
    }

    func refreshSystemMic() {
        let state = systemMic.refresh(wanted: wantsSystemMic)
        if state != systemMicState { systemMicState = state }
    }

    /// Switches or lets go to match the settings (同声传译, 自动切换, 声音输出到).
    func applySystemMic() {
        // Speaking off: turning it off already put the mic back; a crash leftover waits for 还原.
        if wantsSystemMic { systemMic.engage(wanted: true) } else if settings.speakEnabled { systemMic.release() }
        refreshSystemMic()
    }

    /// 还原: the real mic back now. While speaking it stays back until 换回 or the next time speaking starts.
    func restoreSystemMic() {
        systemMic.release()
        refreshSystemMic()
    }

    /// 换回 / 切换: the virtual mic as the system default again.
    func switchSystemMic() {
        systemMic.engage(wanted: true)
        refreshSystemMic()
    }

    func setAutoSystemMic(_ on: Bool) {
        settings.autoSystemMic = on
        applySystemMic()
    }

    func refreshMicUsers() {
        // Compare against where our voice actually goes: 高级 › 声音输出到 can point elsewhere.
        let target = outputs.first { !settings.speakOutput.isEmpty && $0.uid == settings.speakOutput } ?? virtualMic
        let users = virtualMic != nil ? target.map { MicUsers.current(virtualMic: $0.id) } ?? [] : []
        if users != micUsers { micUsers = users }
    }

    /// Opens the "怎么改" sheet for an app, from the panel or Settings.
    func showMicGuide(_ user: MicUser) {
        micGuide = user
        openSettings(.speak)
    }

    /// Brings a meeting app forward so the user can change its microphone.
    func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Starting the tap triggers the system prompt; if it still fails, open the pane.
    func requestSystemAudio() {
        if !listen.isRunning { start() }
        if !listen.isRunning {
            openSettingsPane("Privacy_ScreenCapture")
        }
        refreshPermissions()
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.refreshPermissions()
                // The engine opened the mic before the grant and reads silence: reopen it.
                if granted, self.settings.listenSource == "mic" { self.listen.reconnectAudio() }
            } }
        }
    }

    func openMicrophoneSettings() { openSettingsPane("Privacy_Microphone") }

    private func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings(_ section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        // The 诊断 tab only exists while its switch is on.
        if settingsSection == .diagnostics && !settings.diagnostics { settingsSection = .overlay }
        openSettingsWindow?()
    }

    func ensureListening() {
        if !listen.isRunning { start() }
    }

    func virtualMicInstalled() {
        refreshOutputs()
        // Core Audio restarted to load the driver: device IDs changed, reattach the
        // system-audio tap and rebuild the voice output.
        speak.resetOutput()
        listen.reconnectAudio()
        if settings.speakEnabled { applySystemMic() }
        objectWillChange.send()
    }

    // MARK: Start / stop

    func start() {
        guard !listen.isRunning else { return }
        let session = store.begin()
        diagnostics.begin()
        speakers.reset()
        lineForSegment = [:]
        lastHeard = nil
        heldJoin = nil
        speechHeard = false
        meetingSubtitles = nil
        autoEnded = false
        endWatch = MeetingEndWatch(config: endConfig, start: Date())
        setEnding(nil)
        if settings.recordAudio {
            listen.router.setRecording(store.systemAudioURL(session.id))
            speak.setRecording(store.micAudioURL(session.id))
        }
        listen.start()
        notes.begin(session.id)
        if listen.isRunning {
            showDisplay()
        } else {
            store.end()
        }
        refresh()
    }

    /// `endedAt`: when a meeting that ends by itself really ended (see `autoEnd`).
    func stop(endedAt: Date? = nil) {
        autoEnded = false
        endWatch = nil
        setEnding(nil)
        diagnostics.end()
        listen.stop()
        listen.router.setRecording(nil)
        speak.setRecording(nil)
        if let held = heldJoin {
            heldJoin = nil
            appendHeard(held.seg, t: held.t, translation: held.translation)
        }
        // Read the whole meeting for names once more (the id outlives store.end).
        let ended = store.liveID
        store.end(at: endedAt)
        if settings.speakerVoices, let ended { speakerNamer.guess(ended, force: true) }
        notes.finish()
        overlay.hide()
        refresh()
    }

    func setRunning(_ on: Bool) {
        if on { askListenSource(); return }
        requestStop()
    }

    /// Every start asks where the meeting is: the Mac's sound (online) or a microphone (in the
    /// room). The last choice is the default button; the menu bar panel's 声源 row switches
    /// mid-meeting without asking.
    private func askListenSource() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("记录哪里的声音？")
        alert.informativeText = L("线上会议选系统音频，收录 Mac 播放的声音；现场会议选麦克风，收录房间里的说话声。开会中也可以在菜单栏面板的“声源”一行切换。")
        let system = alert.addButton(withTitle: L("系统音频（线上会议）"))
        let mic = alert.addButton(withTitle: L("麦克风（现场会议）"))
        alert.addButton(withTitle: L("取消"))
        (settings.listenSource == "mic" ? mic : system).keyEquivalent = "\r"
        switch alert.runModal() {
        case .alertFirstButtonReturn: setListenSource("system"); start()
        case .alertSecondButtonReturn: setListenSource("mic"); start()
        default: break
        }
    }

    /// The 声源 row in the panel (and the question when listening starts). Switching mid-meeting
    /// restarts only the capture; the meeting and its notes carry on.
    func setListenSource(_ source: String) {
        guard source == "system" || source == "mic" else { return }
        settings.listenSource = source
        if source == "mic" { requestMicrophone() }
        listen.sourceChanged()
        refresh()
        objectWillChange.send()
    }

    /// The menu (⌘R) and the panel switch: a meeting with lines is ended only after asking, with
    /// "继续记录" as the default so a stray Return keeps it going. An empty one just stops.
    func requestStop() {
        guard listen.isRunning, let id = store.liveID, let s = store.session(id), !s.lines.isEmpty else { stop(); return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("结束这场会议？")
        alert.informativeText = L("已记录 \(NotesEngine.clock(Date().timeIntervalSince(s.startedAt))) · \(s.lines.count) 句。结束后停止收听，并整理一份完整版纪要。")
        let end = alert.addButton(withTitle: L("结束会议"))
        let keep = alert.addButton(withTitle: L("继续记录"))
        end.hasDestructiveAction = true
        end.keyEquivalent = ""
        keep.keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn { stop() }
    }

    /// The bottom-left 诊断 switch in settings: shows or hides the 诊断 tab.
    func setDiagnostics(_ on: Bool) {
        settings.diagnostics = on
        if !on && settingsSection == .diagnostics { settingsSection = .overlay }
        objectWillChange.send()
    }

    // MARK: Languages

    /// This meeting's 字幕 choice from the notes window's language chip (nil: the settings').
    @Published var meetingSubtitles: String?
    /// Notes language chosen for one meeting (the chip during it, 重新整理 after it).
    @Published private(set) var notesLanguageFor: [String: String] = [:]

    var subtitles: String { meetingSubtitles ?? settings.subtitles }

    func notesChoice(_ id: String) -> String { notesLanguageFor[id] ?? settings.notesLanguage }

    /// The language the other side spoke most in a meeting (the detected one while nothing is recorded yet).
    func meetingLanguage(_ id: String?) -> String? {
        let heard = id.flatMap { store.session($0) }?.lines.filter { $0.speaker != "me" }.map(\.srcLang) ?? []
        let counts = Dictionary(heard.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? (id == store.liveID ? listen.activeLang?.code : nil)
    }

    func notesLanguageCode(_ id: String) -> String {
        notesChoice(id) == "source" ? (meetingLanguage(id) ?? settings.myLanguage) : settings.myLanguage
    }

    /// The subtitle as the 字幕 choice shows it: both lines, the translation alone, or the
    /// original alone as the main line.
    func displayed(_ src: String, _ dst: String) -> (source: String, translation: String) {
        switch subtitles {
        case "original": return ("", src)
        case "translation": return dst.isEmpty ? (src, "") : ("", dst)
        default: return (src, dst)
        }
    }

    func setSubtitles(_ mode: String, meetingOnly: Bool = false) {
        let wasOff = subtitles == "original"
        if meetingOnly { meetingSubtitles = mode } else { settings.subtitles = mode; meetingSubtitles = nil }
        if wasOff && subtitles != "original" { listen.translationResumed() }
        debugLog("subtitles=\(subtitles) meetingOnly=\(meetingOnly)")
        objectWillChange.send()
    }

    /// A different notes language during a meeting rewrites the notes in it right away.
    func setNotesLanguage(_ choice: String, meetingOnly: Bool = false) {
        let live = store.liveID
        let before = live.map(notesLanguageCode)
        if meetingOnly, let live { notesLanguageFor[live] = choice } else { settings.notesLanguage = choice }
        if let live, notesLanguageCode(live) != before { notes.rewrite() }
        debugLog("notesLanguage=\(live.map(notesLanguageCode) ?? settings.notesLanguage) meetingOnly=\(meetingOnly)")
        objectWillChange.send()
    }

    /// After a meeting: write its notes again in the other language.
    func regenerateNotes(_ id: String, choice: String) {
        notesLanguageFor[id] = choice
        notes.generate(for: id)
    }

    // MARK: Display (live notes / subtitle bar / nothing)

    /// 录屏时可见: every place that shows it (settings, menu bar panel, 显示 menu, the notes
    /// window's badge) flips this one setting.
    func setNotesCapturable(_ on: Bool) {
        settings.notesCapturable = on
        notesWindow.setCapturable(on)
        objectWillChange.send()
    }

    func setDisplayMode(_ mode: String) {
        settings.displayMode = mode
        objectWillChange.send()
        showDisplay(force: true)
    }

    /// ⌃⌥S: notes → subtitle bar → nothing → notes.
    func cycleDisplay() {
        let order = ["notes", "bar", "none"]
        let i = order.firstIndex(of: settings.displayMode) ?? 0
        setDisplayMode(order[(i + 1) % order.count])
    }

    /// Set at the first words of a meeting: until then listening stays out of sight.
    private var speechHeard = false

    private func heardSpeech() {
        guard !speechHeard, listen.isRunning else { return }
        speechHeard = true
        if settings.displayMode == "notes" { notesWindow.show() }
    }

    /// `force`: the user asked for this mode, show it even before anyone speaks.
    private func showDisplay(force: Bool = false) {
        switch settings.displayMode {
        case "bar":
            notesWindow.hide()
            if listen.isRunning { overlay.show() }
        case "none":
            notesWindow.hide()
            overlay.hide()
        default:
            overlay.hide()
            // The notes window waits for someone to speak, so launching or a silent tab
            // doesn't put an empty window on screen.
            if listen.isRunning && (speechHeard || force) { notesWindow.show() }
        }
    }

    /// The user closed the notes window: show the same meeting in the records window.
    func notesWindowClosed() {
        let id = store.liveID ?? notes.shownID
        openMainWindow?()
        if let id {
            mainShow = nil
            mainShow = "\(id),notes"
        }
    }

    func openNotesWindow() {
        if settings.displayMode != "notes" { setDisplayMode("notes") }
        notesWindow.show()
    }

    /// 收起 in the menu bar panel: out of the way for now, still in 实时纪要 mode
    /// (unlike the close button, it doesn't open the records window).
    func hideNotesWindow() { notesWindow.hide() }

    func notesVisibilityChanged(_ shown: Bool) {
        if notesShown != shown { notesShown = shown }
    }

    // MARK: Settings actions

    var sourceSelection: String {
        get {
            if case .fixed(let l) = settings.sourceMode { return l.locale }
            return "auto"
        }
        set {
            settings.sourceMode = newValue == "auto" ? .auto
                : .fixed(sourceLanguages.first(where: { $0.locale == newValue }) ?? sourceLanguages[0])
            listen.sourceModeChanged()
            refresh()
            objectWillChange.send()
        }
    }

    var targetSelection: String {
        get { settings.target }
        set {
            settings.target = newValue
            listen.targetChanged()
            refresh()
            objectWillChange.send()
        }
    }

    func enableSpeaking(_ on: Bool) {
        settings.speakEnabled = on
        if on { settings.speakConfirmed = true }
        objectWillChange.send()
        if on {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted { debugLog("microphone permission denied") }
            }
            if settings.talkKey.isRightOption && !RightOptionKey.allowed { RightOptionKey.requestAccess() }
            applyTalkKey()
            refreshOutputs()
            applySystemMic()
            Task { await speak.prepare() }
        } else {
            applyTalkKey()
            restoreSystemMic()
            Task { await speak.teardownAnalyzer() }
        }
    }

    // MARK: Shortcuts

    enum ShortcutRole { case talk, toggle }

    /// Arms the talk key for the current setting. Right ⌥ waits for "输入监控" and
    /// arms itself as soon as it's allowed (no relaunch).
    func applyTalkKey() {
        talkCombo.unregister()
        talkRight.stop()
        var needsPermission = false
        if settings.speakEnabled && !shortcutsSuspended {
            if settings.talkKey.isRightOption {
                needsPermission = !talkRight.start()
            } else {
                talkCombo.register(settings.talkKey)
            }
        }
        if talkNeedsPermission != needsPermission { talkNeedsPermission = needsPermission }
        if needsPermission, permissionPoll == nil {
            permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if RightOptionKey.allowed || !self.settings.speakEnabled || !self.settings.talkKey.isRightOption {
                        self.permissionPoll?.invalidate()
                        self.permissionPoll = nil
                        self.applyTalkKey()
                    }
                }
            }
        }
    }

    func applyToggleKey() {
        toggleKey.unregister()
        guard !shortcutsSuspended else { return }
        let ok = toggleKey.register(settings.toggleKey)
        if toggleKeyTaken == ok { toggleKeyTaken = !ok }
    }

    func allowTalkKey() {
        RightOptionKey.requestAccess()
        RightOptionKey.openSystemSettings()
    }

    /// While a shortcut field is recording, our own shortcuts must not swallow the keys.
    func suspendShortcuts(_ on: Bool) {
        shortcutsSuspended = on
        applyTalkKey()
        applyToggleKey()
    }

    /// Validates and saves a new shortcut. Returns why it was refused, or nil.
    func setShortcut(_ s: Shortcut, for role: ShortcutRole) -> String? {
        if role == .toggle && s.isRightOption { return L("右 ⌥ 只能用于“按住说话”") }
        if let p = s.typingProblem { return p }
        let other = role == .talk ? settings.toggleKey : settings.talkKey
        if s == other { return L("与另一个快捷键冲突") }
        if s.isSystemShortcut { return L("\(s.display) 是系统快捷键，换一个吧") }
        // The one already in use is registered by us: probing it would always fail.
        let current = role == .talk ? settings.talkKey : settings.toggleKey
        if !s.isRightOption && s != current {
            // Probe: Carbon refuses a combo another app already registered.
            let probe = HotKey(id: 9, shortcut: s)
            let free = probe.register()
            probe.unregister()
            if !free { return L("\(s.display) 已被其他应用占用，换一个吧") }
        }
        switch role {
        case .talk:
            settings.talkKey = s
            if s.isRightOption && settings.speakEnabled && !RightOptionKey.allowed { RightOptionKey.requestAccess() }
        case .toggle:
            settings.toggleKey = s
        }
        applyTalkKey()
        applyToggleKey()
        objectWillChange.send()
        return nil
    }

    // MARK: - Chat provider

    /// The provider translation and notes use. Ling takes its model choice from `settings.aiModel`;
    /// custom providers carry their own.
    var activeAIProvider: AIProvider {
        if settings.aiActiveProvider == "ling" {
            var ling = AIProvider.ling
            ling.model = settings.aiModel
            return ling
        }
        return settings.aiProviders.first { $0.id == settings.aiActiveProvider } ?? .ling
    }

    func setActiveProvider(_ id: String) {
        guard id == "ling" || settings.aiProviders.contains(where: { $0.id == id }) else { return }
        settings.aiActiveProvider = id
        Task { await ling.check() }
    }

    /// Adds (or, with the same id, replaces) a custom OpenAI-compatible provider and switches to it.
    func saveProvider(_ provider: AIProvider) {
        guard !provider.isLing, !provider.name.isEmpty, provider.base != nil, !provider.model.isEmpty else { return }
        if let i = settings.aiProviders.firstIndex(where: { $0.id == provider.id }) {
            settings.aiProviders[i] = provider
        } else {
            settings.aiProviders.append(provider)
        }
        setActiveProvider(provider.id)
    }

    func removeProvider(_ id: String) {
        guard id != "ling" else { return }
        settings.aiProviders.removeAll { $0.id == id }
        AIKey.remove(id)
        if settings.aiActiveProvider == id { setActiveProvider("ling") }
    }

    /// The room hears the voice chosen for its language (looked up each time it speaks).
    func applyVoice() {
        speak.route = { [weak self] language in
            guard let self else { return .system(nil) }
            return self.voiceRoute(id: self.voiceID(for: language), language: language)
        }
    }

    /// The chosen voice for a language, or its default (Ming's first with a key, else the Mac's).
    func voiceID(for language: String) -> String? {
        if let id = settings.speakVoices[VoiceCatalog.key(for: language)] {
            if id == "clone" && !VoiceReference.exists { return VoiceCatalog.defaultID(for: language, hasKey: ling.speechCapable) }
            return id
        }
        return VoiceCatalog.defaultID(for: language, hasKey: ling.speechCapable)
    }

    func setVoice(_ id: String, for language: String) {
        settings.speakVoices[VoiceCatalog.key(for: language)] = id
    }

    /// Ming's voices need a working Ling key; without one the Mac's voice speaks.
    func voiceRoute(id: String?, language: String) -> SpeakEngine.VoiceRoute {
        guard let id else { return .system(nil) }
        if id.hasPrefix("system:") { return .system(String(id.dropFirst("system:".count))) }
        guard ling.speechCapable else { return .system(nil) }
        let lang = VoiceCatalog.mingLanguage(for: language)
        if id == "clone" {
            guard let ref = VoiceReference.reference() else { return .system(nil) }
            return .stream { [weak self] text in
                self?.ling.speech(text, voice: nil, reference: ref, language: lang)
                    ?? AsyncThrowingStream { $0.finish(throwing: LingClient.Failure.noKey) }
            }
        }
        let voice = String(id.dropFirst("ming:".count))
        return .stream { [weak self] text in
            self?.ling.speech(text, voice: voice, language: lang)
                ?? AsyncThrowingStream { $0.finish(throwing: LingClient.Failure.noKey) }
        }
    }

    /// Plays a voice on the speakers (not into the room) with a line in that language.
    @Published var previewing: String?

    func previewVoice(_ id: String, language: String, text: String? = nil) {
        previewing = id
        let route = voiceRoute(id: id, language: language)
        Task {
            let started = Date()
            await speak.speak(text ?? VoiceCatalog.sample(for: language), language: language,
                              device: AudioDevices.defaultOutput, route: route)
            debugLog("voice preview \(id) \(language) took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            if previewing == id { previewing = nil }
        }
    }

    func speakFromChanged() {
        objectWillChange.send()
        if settings.speakEnabled { Task { await speak.prepare() } }
    }

    // MARK: Meeting end

    private var endConfig: MeetingEndWatch.Config {
        var c = MeetingEndWatch.Config()
        c.followApps = settings.endWithApp
        c.silence = MeetingEndWatch.Silence(rawValue: settings.silenceEnd) ?? .prompt
        c.silenceAfter = settings.silenceMinutes * 60
        if let o = endTimesOverride { (c.silenceAfter, c.countdown, c.appGrace) = (o.silence, o.countdown, o.grace) }
        return c
    }

    private func heardWords() {
        endWatch?.heard(at: Date())
        setEnding(endWatch?.pending)
    }

    /// Every 2 s: while listening, whether the meeting is over; after one ended by itself, whether
    /// a meeting app started the next call.
    private func watchEnd() {
        if listen.isRunning, var w = endWatch {
            w.config = endConfig
            let said = store.liveID.flatMap { store.session($0) }.map { !$0.lines.isEmpty } ?? false
            let calls = w.config.followApps ? (fakeCalls ?? MicUsers.currentCalls()) : [:]
            let reason = w.tick(at: Date(), calls: calls, said: said)
            endWatch = w
            setEnding(w.pending)
            if let reason { autoEnd(reason, watch: w) }
        } else if !listen.isRunning, autoEnded, settings.endWithApp, !(fakeCalls ?? MicUsers.currentCalls()).isEmpty {
            debugLog("meeting end: a meeting app started a call, starting a new meeting")
            start()
        }
    }

    private func setEnding(_ p: MeetingEndWatch.Pending?) {
        guard p != ending else {
            if p != nil { showEndingOnBar() }
            return
        }
        if let p { debugLog("meeting end: pending \(p.reason), ends in \(Int(p.deadline.timeIntervalSinceNow)) s") }
        else if ending != nil { debugLog("meeting end: pending cleared"); overlay.clearStatus() }
        ending = p
        showEndingOnBar()
    }

    /// The subtitle bar has no buttons: it says what will happen, and speaking keeps a silent meeting going.
    private func showEndingOnBar() {
        guard settings.displayMode == "bar", let p = ending else { return }
        let left = max(0, Int(p.deadline.timeIntervalSinceNow.rounded()))
        overlay.notice(endingTitle(p) + " · " + L("\(left) 秒后结束"))
    }

    func endingTitle(_ p: MeetingEndWatch.Pending) -> String {
        switch p.reason {
        case .appLeft(let name): L("\(name) 已挂断")
        case .silence, .nobodySpoke: L("已经 \(max(1, Int((endConfig.silenceAfter / 60).rounded()))) 分钟没人说话")
        }
    }

    func endingDetail(_ p: MeetingEndWatch.Pending, now: Date = Date()) -> String {
        L("\(max(0, Int(p.deadline.timeIntervalSince(now).rounded()))) 秒后结束会议并整理纪要")
    }

    /// "继续记录" on the ending prompt.
    func keepRecording() {
        endWatch?.keepGoing(at: Date())
        setEnding(nil)
        debugLog("meeting end: kept going")
    }

    /// Ends where the meeting really ended: a little after the last words, or at the hang-up if
    /// that was later. Never before a line that was kept, or its audio would be cut.
    private func autoEnd(_ reason: MeetingEndWatch.Reason, watch w: MeetingEndWatch) {
        if reason == .nobodySpoke {
            // Nothing to keep or summarise: back to "开始听", not "会议已自动结束".
            debugLog("meeting end: nobody spoke for \(Int(w.config.silenceAfter)) s, stopped")
            stop()
            return
        }
        var at = w.lastSpeech.addingTimeInterval(5)
        if case .appLeft = reason { at = max(at, Date().addingTimeInterval(-w.config.appGrace)) }
        debugLog("meeting end: ended by itself (\(reason)), end time \(Int(Date().timeIntervalSince(at))) s ago")
        stop(endedAt: at)
        autoEnded = true
    }

    // MARK: Meeting record

    /// Names are typed in the records window: the notes window never takes focus.
    func editSpeaker(session: String, voice: Int) {
        speakerEdit = SpeakerEditRequest(session: session, voice: voice)
        mainShow = nil
        mainShow = "\(session),transcript"
        openMainWindow?()
    }

    private func recordHeard(_ seg: Segment, duration: Double) {
        guard let start = store.liveStart else { return }
        let t = max(0, Date().timeIntervalSince(start) - duration)
        // A line still waiting for its voice is overtaken: it stands on its own.
        if let held = heldJoin {
            heldJoin = nil
            appendHeard(held.seg, t: held.t, translation: held.translation)
        }
        guard let prev = lastHeard, store.session(store.liveID ?? "")?.lines.last?.id == prev.line,
              prev.seg.clock == seg.clock, prev.seg.sourceCode == seg.sourceCode,
              HeardText.continues(prev.seg.text, seg.text, gap: seg.start - prev.seg.end, cut: prev.seg.cut) else {
            appendHeard(seg, t: t, tag: true)
            return
        }
        // Two voices never share a line: hear whose this is first (a few hundredths of a second).
        if settings.speakerVoices, let samples = seg.voiceSamples, seg.text.filter(\.isLetter).count >= 2 {
            heldJoin = (seg, t, nil)
            speakers.voice(of: samples) { [weak self] voice in self?.heardVoice(seg, voice) }
            return
        }
        join(seg, onto: prev)
    }

    private func heardVoice(_ seg: Segment, _ voice: Int?) {
        guard let held = heldJoin, held.seg.id == seg.id else {
            // Already recorded on its own (another line came first).
            if let voice, let line = lineForSegment[seg.id] { speakers.onVoice?(line, voice) }
            return
        }
        heldJoin = nil
        let lines = store.session(store.liveID ?? "")?.lines ?? []
        if let prev = lastHeard, let last = lines.last, last.id == prev.line,
           voice == nil || last.voice == nil || voice == last.voice {
            join(seg, onto: prev)   // the earlier line's voice stays
        } else {
            appendHeard(seg, t: held.t, translation: held.translation)
            if let voice, let line = lineForSegment[seg.id] { speakers.onVoice?(line, voice) }
        }
    }

    /// One sentence a pause cut in two: the earlier line takes the rest and is translated again whole.
    private func join(_ seg: Segment, onto prev: (seg: Segment, line: String)) {
        let text = HeardText.join(prev.seg.text, seg.text)
        var joined = prev.seg
        joined.text = text
        joined.end = seg.end
        joined.cut = seg.cut
        lastHeard = (joined, prev.line)
        store.setSource(lineID: prev.line, text)
        listen.join(seg.id, into: prev.seg.id, text: text)
        contentLog("JOIN \(prev.line) += \(seg.text)")
        heardWords()
    }

    private func appendHeard(_ seg: Segment, t: Double, translation: String? = nil, tag: Bool = false) {
        lineCounter += 1
        let id = "h\(lineCounter)-\(seg.id)"
        lineForSegment[seg.id] = id
        store.append(TranscriptLine(id: id, t: t, speaker: "them", src: seg.text, dst: translation ?? seg.translation,
                                    srcLang: seg.sourceCode, dstLang: listen.resolvedTarget))
        var kept = seg
        kept.voiceSamples = nil
        lastHeard = (kept, id)
        // A line with hardly a letter ("." from a breath or a click) gets no voiceprint.
        if tag, settings.speakerVoices, let samples = seg.voiceSamples, seg.text.filter(\.isLetter).count >= 2 {
            speakers.tag(lineID: id, samples: samples)
        }
        if settings.cloudASREnabled, cloudASR.hasKey, seg.voiceSamples != nil,
           seg.text.filter(\.isLetter).count >= 2 {
            proofread(lineID: id, seg: seg)
        } else if settings.cloudASREnabled {
            debugLog("asr: skip \(id) key=\(cloudASR.hasKey) samples=\(seg.voiceSamples?.count ?? -1)")
        }
        heardWords()
    }

    /// The record gets the cloud's more accurate transcript once it answers; the live subtitles
    /// keep the on-device text. If the line moved on meanwhile (a join), this pass is dropped.
    private func proofread(lineID: String, seg: Segment) {
        guard let samples = seg.voiceSamples, !samples.isEmpty else { return }
        let original = seg.text
        Task { [weak self] in
            guard let self else { return }
            let text: String
            do {
                text = try await cloudASR.transcribe(samples: samples, language: seg.sourceCode)
                contentLog("asr: \(lineID) heard “\(text)”")
            } catch {
                debugLog("asr: \(lineID) failed: \(error)")
                return
            }
            guard text != original else { return }
            // The line must still say what we sent off; a join would have rewritten it.
            guard let session = store.session(store.liveID ?? ""),
                  let line = session.lines.first(where: { $0.id == lineID }),
                  line.src == original else { return }
            store.setSource(lineID: lineID, text)
            if let dst = await listen.translate(text, source: seg.sourceCode, target: listen.resolvedTarget,
                                                kind: .sentence, trace: TranslateTrace()) {
                store.setTranslation(lineID: lineID, dst)
            }
            debugLog("asr: line \(lineID) proofread")
        }
    }

    private func recordSaid(_ src: String, _ dst: String, from: String, to: String, secondsAgo: Double) {
        guard let start = store.liveStart else { return }
        lineCounter += 1
        let t = max(0, Date().timeIntervalSince(start) - secondsAgo)
        store.append(TranscriptLine(id: "m\(lineCounter)", t: t, speaker: "me", src: src, dst: dst,
                                    srcLang: from, dstLang: to))
        heardWords()
    }

    // MARK: Export

    func export(_ session: Session, kind: String) {
        if kind == "copy" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TranscriptExport.markdown(session), forType: .string)
            return
        }
        let panel = NSSavePanel()
        let ext = kind == "word" ? "docx" : kind == "srt" ? "srt" : "md"
        panel.nameFieldStringValue = "\(session.displayTitle.replacingOccurrences(of: "/", with: "-")).\(ext)"
        panel.canCreateDirectories = true
        if let w = NSApp.keyWindow, !(w is NSPanel), w.isVisible {
            panel.beginSheetModal(for: w) { [weak self] r in
                guard r == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { _ = self?.writeExport(session, kind: kind, to: url) }
            }
            return
        }
        NSApp.activate()
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeExport(session, kind: kind, to: url)
    }

    @discardableResult
    func writeExport(_ session: Session, kind: String, to url: URL) -> Bool {
        do {
            switch kind {
            case "word": try TranscriptExport.docx(session).write(to: url)
            case "srt": try TranscriptExport.srt(session).write(to: url, atomically: true, encoding: .utf8)
            default: try TranscriptExport.markdown(session).write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            debugLog("export failed: \(error)")
            return false
        }
    }

    // MARK: Debug control (only with `defaults write com.wquguru.cicada debug -bool true`)

    func installDebugControl() {
        guard settings.debug || DevBuild.isDev else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(DevBuild.debugChannel), object: nil, queue: .main
        ) { [weak self] note in
            let cmd = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.debugCommand(cmd) }
        }
        debugLog("debug control ready")
    }

    private func debugCommand(_ cmd: String) {
        debugLog("debug command: \(cmd)")
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "start": start()
        case "stop": stop()
        case "open": openMainWindow?()
        case "panel": showPanel?()
        case "onboarding":
            // onboarding:<step>[,skip|setup]: the step, optionally in its second state.
            let p = arg.split(separator: ",").map(String.init)
            onboardingStep = min(max(Int(p.first ?? "") ?? 1, 1), OnboardingView.done)
            onboardingKeySkip = p.contains("skip")
            onboardingSpeakSetup = p.contains("setup") ? true : p.contains("ask") ? false : nil
            openOnboarding?()
        case "step": onboardingStep = Int(arg) ?? 1
        case "samplePlay": ensureListening(); sample.play()
        case "speakers": settings.speakerVoices = arg == "on"
        case "speakerGuess": speakerNamer.guess(arg, force: true)
        case "speakersRender":
            // speakersRender:<session id>=<png>[@width]: the people strip and the first lines with their labels.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let s = store.session(p[0]) else { break }
            let out = p[1].split(separator: "@").map(String.init)
            let width = out.count > 1 ? CGFloat(Double(out[1]) ?? 360) : 360
            let r = ImageRenderer(content: SpeakerPreview(model: self, session: s).environment(\.speakerNames, SpeakerLabels.names(s)).frame(width: width).background(Color.white))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out[0]))
            }
        case "voiceprintFile":
            // voiceprintFile:<audio>=<json>: the app's voiceprint of a whole file, to compare with the reference model.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { break }
            DispatchQueue.global().async {
                let samples = Voiceprints.samples(of: URL(fileURLWithPath: p[0]))
                let v = samples.flatMap { s in (try? Voiceprints.load())?.embed(s) }
                let data = try? JSONSerialization.data(withJSONObject: ["seconds": Double(samples?.count ?? 0) / 16000, "v": v ?? []])
                try? data?.write(to: URL(fileURLWithPath: p[1]))
                debugLog("voiceprintFile: \(v == nil ? "failed" : "ok") \(p[0])")
            }
        case "micVerify": installer.install(verifyOnly: true)
        case "settings":
            settingsSection = SettingsSection(rawValue: arg) ?? settingsSection
            openSettings(settingsSection)
        case "diagnostics":
            setDiagnostics(arg != "off")
            debugLog("diagnostics \(settings.diagnostics ? "on" : "off")")
        case "diagReport":
            debugLog("diag report:\n" + diagnostics.report(version: "", model: settings.aiModel))
        case "micTest": installer.runTest()
        case "micNext": installer.next()
        case "sysMic":
            refreshSystemMic()
            debugLog("system mic state=\(systemMicState) default=\(AudioDevices.defaultInput?.name ?? "-") saved=\(AudioDevices.inputs().first { $0.uid == settings.savedSystemInput }?.name ?? "-") recording=\(systemMic.recordingDevice?.name ?? "-") engine=\(speak.micDeviceName) auto=\(settings.autoSystemMic) wanted=\(wantsSystemMic)")
        case "sysMicSet":
            // Simulates another app or the user moving the system mic (part of a device name).
            if let d = AudioDevices.inputs().first(where: { $0.name.localizedCaseInsensitiveContains(arg) }) { AudioDevices.setDefaultInput(d) }
            refreshSystemMic()
        case "sysMicRestore": restoreSystemMic()
        case "sysMicSwitch": switchSystemMic()
        case "sysMicAuto": setAutoSystemMic(arg != "off")
        case "speakMic":
            settings.speakMic = arg.isEmpty ? "" : systemMic.realInputs.first { $0.name.localizedCaseInsensitiveContains(arg) }?.uid ?? ""
        case "micUsers":
            refreshMicUsers()
            debugLog("mic users virtual=\(virtualMic?.id ?? 0) readers=\(MicUsers.readers().map { "\($0.bundleID)\($0.inputs)" }) users=\(micUsers.map { "\($0.name)=\($0.state)" })")
        case "micGuide":
            refreshMicUsers()
            if let user = micUsers.first(where: { $0.bundleID == arg || $0.name == arg }) { showMicGuide(user) } else { micGuide = nil }
        case "talkKey", "toggleKey":
            let s = arg == "right" ? Shortcut.rightOption : Shortcut(stored: arg)
            let refusal = s.map { setShortcut($0, for: parts[0] == "talkKey" ? .talk : .toggle) } ?? "bad shortcut"
            debugLog("\(parts[0]) \(arg): \(refusal ?? "ok")")
        case "shortcuts":
            debugLog("shortcuts talk=\(settings.talkKey.display) armed=\(talkRight.isRunning || talkCombo.isRegistered) needsPermission=\(talkNeedsPermission) inputMonitoring=\(RightOptionKey.allowed) toggle=\(settings.toggleKey.display) taken=\(toggleKeyTaken)")
        case "aiKeyFile":
            // Dev testing: the key comes from a file so it never passes through the log.
            if let k = try? String(contentsOfFile: arg, encoding: .utf8) { Task { await ling.setKey(k) } }
        case "aiCheck": Task { await ling.check() }
        case "voice":
            // voice:<lang>=<id> chooses ("voice:en=ming:UK_George", "voice:zh=clone"); voice:<lang> logs the choice.
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { setVoice(kv[1], for: kv[0]) }
            debugLog("voice \(kv[0]) → \(voiceID(for: kv[0]) ?? "none") options=\(VoiceCatalog.options(for: kv[0]).map(\.id)) clone=\(VoiceReference.exists)")
        case "voiceCloneFile":
            // voiceCloneFile:<wav> uses a recording as "my voice", transcribing it like the sheet does.
            Task {
                let url = URL(fileURLWithPath: arg)
                guard let f = try? AVAudioFile(forReading: url),
                      let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                      (try? f.read(into: buf)) != nil else { debugLog("voiceCloneFile: unreadable"); return }
                let text = await LoopbackTest.transcribe([buf], locale: settings.speakFromLang.locale)
                do { try VoiceReference.save(wav: url, text: text) } catch { debugLog("voiceCloneFile: \(error)") }
                debugLog("voiceCloneFile: saved, transcript \(text.count) chars")
            }
        case "voicePreview":
            // voicePreview:<lang>=<id>
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { previewVoice(kv[1], language: kv[0]) }
        case "notesNow": notes.updateNow()
        case "endSim":
            // endSim:<app name>[,<app name>] pretends those meeting apps are in a call; endSim: none; endSim:off real.
            fakeCalls = arg == "off" ? nil : Dictionary(arg.split(separator: ",").map { ("sim.\($0)", String($0)) }) { a, _ in a }
            debugLog("meeting end: simulated calls \(fakeCalls.map { $0.values.sorted().description } ?? "off")")
        case "endTimes":
            // endTimes:<silence>,<countdown>,<grace> in seconds; endTimes: back to the settings.
            let v = arg.split(separator: ",").compactMap { Double($0) }
            endTimesOverride = v.count == 3 ? (v[0], v[1], v[2]) : nil
        case "endKeep": keepRecording()
        case "endState":
            debugLog("meeting end: running=\(listen.isRunning) autoEnded=\(autoEnded) pending=\(ending.map { "\($0.reason) in \(Int($0.deadline.timeIntervalSinceNow)) s" } ?? "none") inCall=\(endWatch?.inCall.values.sorted() ?? []) silent=\(endWatch.map { Int(Date().timeIntervalSince($0.lastSpeech)) } ?? -1) s config=\(endConfig)")
        case "updateFeed":
            // updateFeed:<release json url>: check a fake release (file:// works), even in a dev build.
            if let url = URL(string: arg) { updates.checker.feed = url }
            updates.checkNow()
        case "updateCheck": updates.checkNow()
        case "updateInstall": updates.install(model: self)
        case "updateState": debugLog("update current=\(Updates.current) found=\(updates.update?.version ?? "-") check=\(updates.check) progress=\(updates.progress.map { String($0) } ?? "-") failure=\(updates.failure ?? "-")")
        case "loginItem":
            if !arg.isEmpty { loginItem.set(arg == "on") }
            loginItem.refresh()
            debugLog("login item enabled=\(loginItem.enabled) needsApproval=\(loginItem.needsApproval)")
        case "about": AboutPanel.show()
        case "display": setDisplayMode(arg)
        case "source":
            // source:<system|mic>: the 声源 choice, as in the menu bar panel.
            if arg == "system" || arg == "mic" { setListenSource(arg) }
            debugLog("listen source=\(settings.listenSource) running=\(listen.isRunning)")
        case "sourceAsk":
            // sourceAsk: the first-start 声源 question, as if the panel switch was flipped.
            askListenSource()
        case "notesWindow":
            let v = arg.split(separator: ",").compactMap { Double($0) }
            openNotesWindow()
            if v.count == 4 { notesWindow.place(NSRect(x: v[0], y: v[1], width: v[2], height: v[3])) }
        case "notesFrame": debugLog("notes window frame=\(String(describing: notesWindow.frame)) visible=\(notesWindow.isVisible) policy=\(NSApp.activationPolicy() == .regular ? "regular" : "accessory")")
        case "notesReplay": Task { await notes.replay(arg) }
        case "notesShow": notes.show(arg)
        case "notesCapturable": notesWindow.setCapturable(arg != "off")
        case "notesClose": notesWindow.performClose()
        case "closeWindow":
            // closeWindow:<main|settings|onboarding>: what the window's close button does.
            let w = NSApp.windows.first { w in
                switch arg {
                case "main": w.contentView is NSHostingView<MainWindowView>
                case "settings": w.contentView is NSHostingView<SettingsView>
                default: w.contentView is NSHostingView<OnboardingView>
                }
            }
            w?.performClose(nil)
        case "notesRender":
            // The whole notes column as a PNG, for checking what is below the fold.
            let view = NotesContentView(notes: notes.notes, fresh: notes.fresh, live: store.liveID != nil,
                                        updating: notes.state == .updating)
                .padding(24).frame(width: 460).background(Color.white)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arg))
            }
        case "mainShow": mainShow = arg
        case "mainRender":
            // The main window as drawn, for checking it without Screen Recording permission.
            guard let view = NSApp.windows.first(where: { $0.contentView is NSHostingView<MainWindowView> })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            // And the shown meeting's whole notes page beside it, for what is below the fold.
            if let id = mainShow?.split(separator: ",").first.map(String.init), let n = store.session(id)?.notes {
                let r = ImageRenderer(content: NotesContentView(notes: n, document: true).padding(32).frame(width: 744).background(Color.white))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let full = NSBitmapImageRep(data: tiff) {
                    try? full.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg + ".notes.png"))
                }
            }
        case "panelRender":
            // The menu bar panel drawn offscreen with real AppKit controls: the popover closes
            // as soon as another app is active, so it can't be caught by windowsRender.
            let host = NSHostingView(rootView: MenuPanelView(model: self, settings: settings))
            let size = host.fittingSize
            let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            w.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                }
                w.orderOut(nil)
            }
        case "settingsRender":
            // settingsRender:<section>=<png>: one settings page in full, scroll view or not.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let section = SettingsSection(rawValue: p[0]) else { break }
            settingsSection = section
            let r = ImageRenderer(content: SettingsView(model: self, settings: settings, installer: installer).page
                .frame(width: 530).background(Color(red: 0.965, green: 0.969, blue: 0.976)))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
            }
        case "windowsRender":
            // Every visible window as drawn (<dir>/<n>-<class>.png), without Screen Recording permission.
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView, view.bounds.width > 40,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = "\(i)-\(String(describing: type(of: w)).prefix(24)).png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg).appendingPathComponent(name))
            }
        case "notesState": debugLog("notes state=\(notes.state) topics=\(notes.notes.topics.count) covered=\(notes.notes.covered) glossary=\(notes.glossary.count) timedPoints=\(notes.notes.topics.reduce(0) { $0 + ($1.pointTimes?.compactMap { $0 }.count ?? 0) })/\(notes.notes.topics.reduce(0) { $0 + $1.points.count }) fresh=\(notes.fresh.count)")
        case "lingSimulate":
            ling.simulate = ["429": .rateLimited, "hijack": .hijacked, "timeout": .timeout][arg]
            debugLog("ling simulate=\(String(describing: ling.simulate))")
        case "aiRemove": ling.removeKey()
        case "aiHide":
            // aiHide:<on|off>: the key file stays; the app behaves as if there were none (for screenshots).
            ling.hideKey = arg != "off"
            Task { await ling.check() }
        case "aiState": debugLog("ai state=\(ling.keyState) hasKey=\(ling.hasKey) provider=\(activeAIProvider.id) model=\(activeAIProvider.model)")
        case "aiProvider":
            // aiProvider:add:name|base|model adds a provider and switches to it; aiProvider:<id> switches.
            if arg.hasPrefix("add:") {
                let parts = arg.dropFirst(4).split(separator: "|").map(String.init)
                if parts.count == 3 {
                    saveProvider(AIProvider(id: "debug-" + parts[0], name: parts[0], baseURL: parts[1], model: parts[2]))
                }
            } else {
                setActiveProvider(arg)
            }
            debugLog("ai provider=\(activeAIProvider.id) model=\(activeAIProvider.model) hasKey=\(ling.hasKey)")
        case "subtitles": setSubtitles(arg)
        case "meetingSubtitles": setSubtitles(arg, meetingOnly: true)
        case "notesLang": setNotesLanguage(arg)
        case "meetingNotesLang": setNotesLanguage(arg, meetingOnly: true)
        case "notesRegenerate":
            let p = arg.split(separator: "=").map(String.init)
            if p.count == 2 { regenerateNotes(p[0], choice: p[1]) }
        case "speakAsk":
            // speakAsk[:off]: the panel's one-time question, as if the switch was flipped for the first time.
            speakAsking = arg != "off"
        case "speakConfirmed": settings.speakConfirmed = arg != "off"
        case "speakOn": enableSpeaking(true)
        case "speakOff": enableSpeaking(false)
        case "speakOut": speak.debugOutputURL = arg.isEmpty ? nil : URL(fileURLWithPath: arg)
        case "speakFile": speak.speakFile(URL(fileURLWithPath: arg))
        case "speakTest":
            // speakTest:<sample|voice>: open settings › 同声传译 with the 试一句 sheet and run it.
            settingsSection = .speak
            openSettingsWindow?()
            speakTestShown = true
            speakTester.start(arg == "voice" ? .voice : .sample)
        case "speakOutput":
            // speakOutput:<part of a device name>, or empty for the virtual mic (automatic).
            settings.speakOutput = arg.isEmpty ? "" : AudioDevices.outputs().first { $0.name.localizedCaseInsensitiveContains(arg) }?.uid ?? ""
            applySystemMic()
            speak.resetOutput()
            debugLog("speak output=\(speak.outputDevice()?.name ?? "-")")
        case "voicePicker": voicePickerOpen = arg != "off"
        case "speakTestBegin": speakTester.beginTalking()
        case "speakTestEnd": speakTester.endTalking()
        case "speakTestClose": speakTester.cancel(); speakTestShown = false
        case "speakTestState":
            debugLog("speak test phase=\(speakTester.phase) reached=\(String(describing: speakTester.reached)) result=\(speakTester.result?.report.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
        case "micGuideRender":
            // micGuideRender:<bundle id>=<png>: the 怎么改 sheet for an app in the list.
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let user = micUsers.first(where: { $0.bundleID == p[0] }) else { break }
            let r = ImageRenderer(content: MicGuideView(model: self, bundleID: user.bundleID, name: user.name, close: {}).background(Color.white))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p[1]))
            }
        case "speakTestRender":
            let r = ImageRenderer(content: SpeakTestView(model: self, tester: speakTester, close: {}).background(Color.white))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
            }
        case "place":
            let n = arg.split(separator: ",").compactMap { Double($0) }
            if n.count == 4 { overlay.place(x: n[0], y: n[1], width: n[2], fontSize: n[3]) }
        case "overlayState": debugLog("overlay \(overlay.stateDescription)")
        case "overlayToggle": overlay.toggleManual()
        case "overlayAuto": setOverlayAuto(arg != "off")
        case "hideAfter": settings.overlayHideAfter = Double(arg) ?? 4
        case "frame":
            debugLog("overlay frame=\(overlay.barFrame) font=\(overlay.currentFontSize)")
        case "export":
            guard let s = store.sessions.first(where: { $0.id != store.liveID }) ?? store.sessions.first else { return }
            let dir = URL(fileURLWithPath: arg)
            for (kind, ext) in [("md", "md"), ("srt", "srt"), ("word", "docx")] {
                let ok = writeExport(s, kind: kind, to: dir.appendingPathComponent("export.\(ext)"))
                debugLog("export \(ext) ok=\(ok)")
            }
        default: break
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var deviceWork: DispatchWorkItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var runningObserver: Any?
    private var popoverClickMonitor: Any?
    private lazy var menu = AppMenu(model: model)
    /// Held here: a toolbar keeps only a weak reference to its delegate.
    private lazy var mainToolbar = MainToolbar(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.showMainWindow = { [weak self] in self?.showMainWindow() }
        menu.showOnboarding = { [weak self] in self?.showOnboarding() }
        menu.install()
        setupStatusItem()
        model.openMainWindow = { [weak self] in self?.showMainWindow() }
        model.openSettingsWindow = { [weak self] in self?.showSettingsWindow() }
        model.showPanel = { [weak self] in self?.togglePopover() }
        model.openOnboarding = { [weak self] in self?.showOnboarding() }
        runningObserver = model.$running.combineLatest(model.updates.$update).sink { [weak self] live, update in
            self?.statusItem.button?.image = BrandImage.menuBar(live: live, badge: update != nil)
        }
        let poll = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
        }
        pollTimer = poll
        RunLoop.main.add(poll, forMode: .common)
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.showOnboarding() }
            }
        } else if !Self.launchedAsLoginItem {
            // Opened by hand (Finder, Launchpad, Spotlight): show something, like the Dock icon does.
            showMainWindow()
        }
        model.installDebugControl()
        installDeviceListener()
        Task { await model.launch() }
        model.updates.start()
    }

    /// Started by the system at login: stay in the menu bar.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        // Other apps would be left on the virtual mic, hearing nothing.
        model.systemMic.release()
    }

    /// Dock icon or Finder: bring back what is open; the main window only when nothing is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let open = [mainWindow, settingsWindow, onboardingWindow].compactMap { $0 }.filter { $0.isVisible || $0.isMiniaturized }
        if open.isEmpty { showMainWindow() } else { open.forEach { $0.deminiaturize(nil) }; NSApp.activate() }
        return false
    }

    /// Quitting ends the meeting being recorded: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.updates.installing, model.running, let id = model.store.liveID, !(model.store.session(id)?.lines.isEmpty ?? true) else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("正在记录会议")
        alert.informativeText = L("退出会结束这场记录，已记下的内容会保存。")
        alert.addButton(withTitle: L("退出"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = BrandImage.menuBar(live: false)
            if DevBuild.isDev {
                button.imagePosition = .imageLeading
                button.attributedTitle = NSAttributedString(string: " DEV", attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                    .baselineOffset: 1,
                ])
                button.toolTip = "\(appDisplayName) · \(DevBuild.label ?? "")"
            }
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover.behavior = .transient
        popover.animates = false
        let panel = NSHostingController(rootView: MenuPanelView(model: model, settings: model.settings))
        // The popover follows the panel's height as it changes (a status line, the virtual-mic
        // warning). Without this the hosting view resized the popover window from its bottom
        // edge, pushing the top of the panel above the screen.
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        // .transient closes on focus changes, but the notes panel and the subtitle bar never take
        // focus: a click on them would leave the popover open on top. Close it ourselves.
        popoverClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, self.popover.isShown, let w = e.window, w !== self.popover.contentViewController?.view.window,
               w !== self.statusItem.button?.window {
                self.popover.performClose(nil)
            }
            return e
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshOutputs()
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: Main window

    func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = appDisplayName
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.delegate = self
            w.contentView = NSHostingView(rootView: MainWindowView(model: model, store: model.store, settings: model.settings))
            w.toolbar = mainToolbar.make()
            w.toolbarStyle = .unified
            w.titlebarSeparatorStyle = .none
            w.center()
            w.setFrameAutosaveName("LiveSubsMain")
            mainWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showSettingsWindow() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L("设置")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model, settings: model.settings, installer: model.installer))
            w.center()
            w.setFrameAutosaveName("LiveSubsSettings")
            settingsWindow = w
        }
        model.refreshOutputs()
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showOnboarding() {
        popover.performClose(nil)
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L("欢迎使用\(appDisplayName)")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingView(
                model: model, settings: model.settings, installer: model.installer, sample: model.sample,
                onFinish: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    self?.onboardingWindow?.close()
                }))
            w.center()
            onboardingWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        let w = notification.object as? NSWindow
        updateActivationPolicy(closing: w)
        if w == onboardingWindow {
            model.sample.stop()
            UserDefaults.standard.set(true, forKey: "onboarded")
            // Done (or 稍后): land on the records window rather than nothing but the menu bar icon.
            if mainWindow?.isVisible != true {
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.showMainWindow() } }
            }
        }
    }

    /// A regular app (name and menus top left, Dock icon, ⌘Tab) while the main, settings or
    /// onboarding window is open; only the menu bar item otherwise. The notes window doesn't
    /// count: it floats beside the meeting app and never takes focus from it.
    func updateActivationPolicy(closing: NSWindow? = nil) {
        let open = [mainWindow, onboardingWindow, settingsWindow].contains { $0 != nil && $0 != closing && $0!.isVisible }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        debugLog("activation policy → \(open ? "regular" : "accessory")")
    }

    // MARK: Output device changes

    private func installDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputDeviceChanged() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func outputDeviceChanged() {
        deviceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // The tap follows the default output; a microphone capture doesn't care.
                if self?.model.settings.listenSource != "mic" {
                    debugLog("default output device changed → reconnecting tap")
                    self?.model.listen.reconnectAudio()
                }
                self?.model.refreshOutputs()
            }
        }
        deviceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

@main
struct LiveSubsMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-dmg-background"), args.count > i + 1 {
            let scale = args.count > i + 2 ? Int(args[i + 2]) ?? 1 : 1
            do {
                try DMGBackground.render(to: URL(fileURLWithPath: args[i + 1]), scale: scale)
                exit(0)
            } catch {
                FileHandle.standardError.write("render failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        // AppKit adds "进入全屏幕" to a menu titled 显示 (View) unless told before launch;
        // no Live Subs window goes full screen.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
