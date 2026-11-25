import Combine
import SwiftUI

@main
struct CicadaApp: App {
    @StateObject private var model = AppModel()

    init() { ImportBackground.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.ling)
                .environmentObject(model.notes)
                .environmentObject(model.room)
                .onOpenURL { if !model.openedFile($0) { model.open($0) } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    model.room.appBecameActive()
                }
                .modifier(DevWindow(model: model))
        }
    }
}

enum AppTab: String { case records, settings, search }

/// Settings the iOS app shares with the Mac by name (AppSettings in Settings.swift), so a record
/// and its languages mean the same thing on both.
enum Pref {
    /// 对方说: "auto" or a `sourceLanguages` locale.
    static let source = "sourceMode"
    /// 翻译成: "system" or a `targetLanguages` code.
    static let target = "target"
    static let model = "aiModel"
    /// 说话人识别.
    static let voices = "speakerVoices"
    /// 纪要语言: "mine" (the language meetings are translated into) or "source" (the meeting's own).
    static let notesLanguage = "notesLanguage"
    /// 会中改正听错的词, and 没见过的名字和专称先问我.
    static let fixMisheard = "fixMisheard"
    static let askNames = "askNames"
    /// 声音来源 (iOS only): "room", people at the table, or "speaker", video this phone plays aloud.
    static let hear = "iosHear"
    /// 面对面's 我说: a `sourceLanguages` locale (对方说 is `source`, as when listening).
    static let myLang = "iosMyLang"
    /// 第一次打开's three steps are done (or skipped).
    static let welcomed = "iosWelcomed"
    /// 保存会议录音, the Mac's and Android's recordAudio.
    static let recordAudio = "recordAudio"
    /// 没人说话时: "prompt" (count down, then end), "end" or "off"; 多久算没人说话 in minutes. The Mac's names.
    static let silenceEnd = "silenceEnd"
    static let silenceMinutes = "silenceMinutes"
    static var speakerMode: Bool { UserDefaults.standard.string(forKey: hear) == "speaker" }

    /// 对方说 is 自动识别: listening and imports hear which language it is (LanguageDetector).
    static var sourceAuto: Bool { (UserDefaults.standard.string(forKey: source) ?? "auto") == "auto" }

    /// 对方说 as one language: the one picked, or with 自动识别 the one heard last (the Mac's
    /// lastDetected), else the likeliest for this phone. Face to face and model downloads use it.
    static var sourceLang: Lang {
        let v = UserDefaults.standard.string(forKey: source) ?? "auto"
        if let lang = sourceLanguages.first(where: { $0.locale == v }) { return lang }
        let last = UserDefaults.standard.string(forKey: lastDetected)
        return likelySourceLanguages(last: last, systemLanguages: Locale.preferredLanguages).first ?? sourceLanguages[0]
    }
    /// The language 自动识别 heard last, as the Mac keeps it.
    static let lastDetected = "lastDetected"

    /// 对方说 in the UI's language ("英语", "English"), as the Mac's menu shows it.
    static func name(of lang: Lang) -> String {
        Locale.current.localizedString(forLanguageCode: lang.code) ?? lang.name
    }
    /// 对方说's code for 翻译成: with 自动识别, none yet (跟随系统 is my language until one is heard).
    static var sourceCode: String { sourceAuto ? "auto" : sourceLang.code }
    static var sourceName: String { sourceAuto ? L("自动识别") : name(of: sourceLang) }

    /// "英 → 中" for two translation codes, as a meeting row says it.
    static func pairText(_ source: String, _ target: String) -> String {
        let line = TranscriptLine(id: "", t: 0, speaker: "them", src: "", dst: nil, srcLang: source, dstLang: target)
        let s = Session(id: "", title: "", startedAt: Date(), endedAt: nil, lines: [line], hasAudio: false)
        return RecordList.pair(s, short: true) ?? ""
    }

    /// What a meeting in `source` is translated into, as the Mac's `AppSettings.resolvedTarget`:
    /// 跟随系统 is my language, unless they speak it; then the next system language (English UI and
    /// an English meeting would otherwise "translate" English into English).
    static func target(for source: String) -> String {
        let t = UserDefaults.standard.string(forKey: target) ?? "system"
        return t == "system" ? followSystemTarget(source: source, systemLanguages: Locale.preferredLanguages) : t
    }

    /// The reader's own language (纪要's 我的语言).
    static var targetCode: String {
        let t = UserDefaults.standard.string(forKey: target) ?? "system"
        return t == "system" ? myLanguage(systemLanguages: Locale.preferredLanguages) : t
    }
}

/// 改正听错的词's two switches, by the Mac's names (AppSettings).
@MainActor
final class FixPrefs: FixSwitches {
    var fixMisheard: Bool { UserDefaults.standard.bool(forKey: Pref.fixMisheard) }
    var askNames: Bool { UserDefaults.standard.bool(forKey: Pref.askNames) }
}

/// Wires the shared engines to the screens, like the Mac's AppModel. M1: the records, the key and
/// their notes.
@MainActor
final class AppModel: ObservableObject {
    @Published var store = SessionStore()
    let ling = LingClient()
    lazy var notes = NotesEngine(ling: ling, store: store)
    lazy var translator: TranslationService = {
        let t = TranslationService(ling: ling)
        t.onHealth = { [weak self] h in self?.translationHealth = h }
        return t
    }()
    /// Whether translation can be reached: the live page, the import card and 面对面 say so.
    @Published var translationHealth = TranslationHealth()
    /// Finished sentences are going untranslated because nothing can be reached (no key, no
    /// Google, no on-device model), so what is on screen is only the original.
    var translationDown: Bool { translationHealth.googleDown && translationHealth.sentencesUntranslated }
    lazy var room: RoomListen = {
        let r = RoomListen(store: store, translator: translator, notes: notes)
        r.onStateChange = { [weak self] in self?.listeningChanged() }
        r.onLine = { [weak self] line in self?.showOnLockScreen(line) }
        // The floating window follows the 字幕 page: what is being said, else the newest line.
        roomWatch = r.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.showInPiP() }
        }
        return r
    }()
    /// 导入录音或视频: the Mac's importer, with the iOS app's languages.
    let importPrefs = ImportPrefs()
    /// 存到文件夹 (FolderPage.swift): the Mac's exporter, writing into a folder picked in Files.
    let folderPrefs = FolderPrefs()
    lazy var folderExport = FolderExporter(store: store, settings: folderPrefs)
    @Published var showFolder = false
    lazy var importer: FileImporter = {
        // 记住的人 name the voices of imported files too.
        let i = FileImporter(store: store, settings: importPrefs, translator: translator, profiles: profiles)
        // As on the Mac: a file transcribed to the end gets its notes when there is a key.
        i.onFinished = { [weak self] id in
            guard let self else { return }
            self.folderExport.ended(id)
            for ref in self.store.session(id)?.voiceProfiles?.values ?? [:].values { self.profiles.markSeen(id: ref.id) }
            self.speakerProfiles = self.profiles.all()
            guard self.ling.hasKey else { return }
            self.notes.generate(for: id)
        }
        ImportBackground.importer = i
        return i
    }()
    /// 面对面同声传译 (FaceView), over everything while it is open.
    lazy var face = FaceToFace(store: store, translator: translator, ling: ling)
    @Published var showFace = false
    /// 记住的人 (PeoplePage.swift): the Mac's voiceprint store, what it holds, and the last problem.
    let profiles = SpeakerProfileStore()
    @Published var speakerProfiles: [SpeakerProfile] = []
    @Published var speakerMemoryBusy = false
    @Published var speakerProblem: (String, String)?
    @Published var showPeople = false
    /// The notes piece open for editing (NotesEdit.swift), and the meeting whose notes were just copied.
    @Published var noteEdit: NoteEdit?
    @Published var copiedNotes: String?
    /// 设置 › AI 服务, pushed (a debug command opens it).
    @Published var showAIService = false
    /// 设置 › 念给对方的声音, pushed (a debug command opens it).
    @Published var showVoices = false
    /// 设置 › 快速开始, pushed (a debug command opens it).
    @Published var showQuickStart = false
    /// The meeting whose 导出 sheet is open.
    @Published var exporting: String?
    /// Why a picked file wasn't imported.
    @Published var importProblem: String?
    let pip = PiPSubtitles()
    private var roomWatch: AnyCancellable?
    let liveActivity = LiveActivityController()
    /// 词表 and 改正听错的词, the Mac's own engines.
    let vocabulary = Vocabulary(url: Vocabulary.defaultURL)
    lazy var fixes = makeFixes()
    /// 结束会议 by itself (AutoEnd.swift): the countdown on screen, and the watch behind it.
    @Published var ending: MeetingEndWatch.Pending?
    var endWatch: MeetingEndWatch?
    var endTimer: Timer?
    var endHeard = (lines: 0, draft: "")
    /// Debug (`endTimes:<silence>,<countdown>`): seconds instead of minutes, to test it.
    var endTimesOverride: (Double, Double)?
    /// 正在听's 字幕 / 纪要 switch, so a debug command can flip it.
    @Published var livePage: LivePage = .subtitles
    /// The record page's picked speaker (scheme A: only they are drawn in ink).
    @Published var focusSpeaker: Int?
    @Published var tab: AppTab = .records
    @Published var selection: String? { didSet { if selection != oldValue { recordPage = firstPage(selection) } } }
    /// A meeting opened from 搜索 (iPhone).
    @Published var searchPath: [String] = [] { didSet { if searchPath.last != oldValue.last { recordPage = firstPage(searchPath.last) } } }
    /// The record page's 文字记录 / 纪要 switch, kept here so a debug command can flip it.
    @Published var recordPage: RecordPage = .transcript
    @Published var query = ""
    /// Which of the open meeting's matches the search is on (#33: a search opens the line, not just the meeting).
    @Published var searchMatch = 0
    /// iPad: settings is a sheet over the records.
    @Published var showSettings = false
    /// What the 听会议室 card and the import button would start; they come with M2 and M3.
    @Published var comingSoon: String?
    /// "说话人 6 已改成 David · 撤销", for a few seconds after a speaker edit, as on the Mac.
    @Published var speakerUndo: SpeakerUndo?
    /// The speaker number whose 是谁 prompt is open on the record page.
    @Published var namingSpeaker: Int?
    /// 改正听错的词: the line being rewritten (改这句…), the record line tapped open, and 设置 › 词表's
    /// state (pushed, 粘贴导入's text, the word being edited, the word just deleted).
    @Published var editingLine: LineEdit?
    @Published var openLine: String?
    @Published var showWordList = false
    @Published var wordImport: String?
    @Published var editingWord: String?
    @Published var deletedWord: DeletedWord?
    @Published var wordConflict: WordConflict?
    /// 第一次打开 (Welcome.swift) and its step.
    @Published var showWelcome = !UserDefaults.standard.bool(forKey: Pref.welcomed)
    @Published var welcomeStep = 0
    /// Dev only: the iPad window size `window:` lays the app out at (DevWindow in Debug.swift).
    @Published var devWindow: CGSize?

    init() {
        UserDefaults.standard.register(defaults: [Pref.source: "auto", Pref.voices: true, Pref.model: LingClient.models[0], Pref.notesLanguage: "mine",
                                                  Pref.fixMisheard: true, Pref.askNames: true, Pref.recordAudio: true,
                                                  Pref.silenceEnd: "prompt", Pref.silenceMinutes: 10.0])
        TranscriptExport.voices = UserDefaults.standard.bool(forKey: Pref.voices)
        // 设置 › AI 服务 (AIServicePage.swift): the Mac's services and settings.
        ling.config = { AIPrefs.config }
        AIPrefs.applyVoices()
        wireNotes()
        // 存到文件夹, as the Mac's AppModel: a meeting is written once settled and rewritten when it changes.
        folderExport.settling = { [weak self] id in self?.notes.settling(id) ?? false }
        store.onSave = { [weak self] id in self?.folderExport.saved(id) }
        notes.finalDone = { [weak self] id in self?.folderExport.settled(id) }
        room.onEnded = { [weak self] id in self?.folderExport.ended(id) }
        room.profiles = profiles
        speakerProfiles = profiles.all()
        folderExport.retry()
        wireFixes()
        #if targetEnvironment(simulator)
        HostRecognizer.install()
        #endif
        DebugChannel.listen(self)
        IntentHub.run = { [weak self] action in self?.intent(action) }
        debugLog("ios launch \(DevBuild.label ?? "release") sessions=\(store.sessions.count) key=\(ling.hasKey)")
        if ling.hasKey { Task { await ling.check() } }
    }

    // MARK: 听会议室

    func startListening() {
        guard !room.isRunning else { return }
        selection = nil
        searchPath = []
        tab = .records
        // 纪要 first, as the Mac's notes window; without a key there are none, so 字幕.
        livePage = ling.hasKey ? .notes : .subtitles
        fixes.meetingStarted()
        room.start(source: Pref.sourceAuto ? "auto" : Pref.sourceLang.locale, target: Pref.target(for: Pref.sourceCode), voices: UserDefaults.standard.bool(forKey: Pref.voices),
                   speaker: Pref.speakerMode)
    }

    private func showInPiP() {
        guard room.isRunning, room.speakerMode else { return }
        let last = room.lines.last
        let shown = last.flatMap { l in store.session(room.sessionID)?.lines.first { $0.id == l.id }?.shown } ?? last?.src
        if room.paused || !room.status.isEmpty {
            pip.show(src: "", dst: "", note: room.paused ? L("已暂停，结束后接着听") : room.status)
        } else if !room.draft.isEmpty {
            pip.show(src: room.draft, dst: room.draftTranslation, note: L("正在听外放…"))
        } else {
            pip.show(src: shown ?? "", dst: last?.dst ?? "", note: shown == nil ? L("正在听外放…") : "")
        }
    }

    func stopListening() { room.stop() }

    /// The Live Activity shows the line as fixed (改正听错的词), like the 字幕 page.
    func showOnLockScreen(_ line: RoomListen.Line) {
        var shown = line
        if let rec = store.session(room.sessionID)?.lines.first(where: { $0.id == line.id }) { shown.src = rec.shown }
        liveActivity.update(line: shown)
    }

    /// 快速开始 and the Live Activity's buttons.
    func intent(_ action: IntentHub.Action) {
        debugLog("intent: \(action)")
        switch action {
        case .start:
            if showFace { closeFace() }
            showWelcome = false
            startListening()
        case .stop: stopListening()
        case .togglePause: room.setPaused(!room.paused)
        }
    }

    private func listeningChanged() {
        objectWillChange.send()
        liveActivity.setPaused(room.paused)
        pip.setEnabled(room.isRunning && room.speakerMode)
        if room.isRunning, let start = room.startedAt {
            liveActivity.start(startedAt: start, pair: Pref.pairText(room.languagePair.source, room.languagePair.target))
            watchEnd()
        } else if !room.isRunning {
            liveActivity.end()
            stopWatchingEnd()
        }
    }

    /// 纪要 first, as on the Mac; a meeting without notes opens on its 文字记录.
    private func firstPage(_ id: String?) -> RecordPage {
        store.session(id)?.notes == nil ? .transcript : .notes
    }

    /// Full notes for a stored meeting, as the Mac's 生成纪要.
    func generateNotes(_ id: String) {
        guard ling.hasKey else { return }
        recordPage = .notes
        notes.generate(for: id)
    }

    /// Each finished sentence's translation also asks which words were misheard (Ling only); the
    /// word list's known forms are fixed as soon as a line is written. As the Mac's AppModel.
    func wireFixes() {
        translator.fixContext = { [weak self] text in self?.fixes.context(for: text) }
        translator.onFixes = { [weak self] text, edits in self?.fixes.received(text, edits) }
        room.onHeard = { [weak self] session, line in self?.fixes.applyKnown(lineID: line, in: session) }
    }

    func makeFixes() -> LiveFixes {
        let f = LiveFixes(store: store, vocabulary: vocabulary, settings: FixPrefs())
        f.onChange = { [weak self] in self?.objectWillChange.send() }
        // The lock screen follows a fix on the line it shows.
        f.onLineFixed = { [weak self] session, line in
            guard let self, session == self.room.sessionID, let last = self.room.lines.last, last.id == line.id else { return }
            self.showOnLockScreen(last)
        }
        vocabulary.onChange = { [weak self] in self?.objectWillChange.send() }
        return f
    }

    func wireNotes() {
        notes.language = { [weak self] id in TranslationService.englishName(self?.notesLanguageCode(id) ?? Pref.targetCode) }
    }

    // MARK: Notes language (the Mac's AppModel.notesLanguageCode)

    /// The language the other side spoke most in a meeting.
    func meetingLanguage(_ id: String) -> String? {
        let heard = store.session(id)?.lines.filter { $0.speaker != "me" }.map(\.srcLang) ?? []
        return Dictionary(heard.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    func notesLanguageCode(_ id: String) -> String {
        UserDefaults.standard.string(forKey: Pref.notesLanguage) == "source" ? (meetingLanguage(id) ?? Pref.targetCode) : Pref.targetCode
    }

    // MARK: Editing a record (the Mac's rules live in SessionStore)

    /// An unchanged title isn't a rename; an empty one goes back to the automatic title.
    func rename(_ id: String, to title: String) {
        store.rename(id, to: title)
        debugLog("rename \(id) renamed=\(store.session(id)?.renamed ?? false)")
    }

    func deleteSession(_ id: String) {
        importer.cancel(id)
        ImportFiles.remove(store.session(id)?.sourcePath)
        if selection == id { selection = nil }
        searchPath.removeAll { $0 == id }
        if speakerUndo?.session == id { speakerUndo = nil }
        store.delete(id)
        folderExport.deleted(id)
        debugLog("delete \(id) sessions=\(store.sessions.count)")
    }

    // MARK: 词表

    /// Swiped away: 撤销 in its place for a few seconds, as on the Mac.
    func deleteWord(_ t: Vocabulary.Term) {
        let index = vocabulary.terms.firstIndex(of: t) ?? 0
        vocabulary.remove(t.word)
        let d = DeletedWord(term: t, index: index)
        deletedWord = d
        if editingWord == t.word { editingWord = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.deletedWord == d { self?.deletedWord = nil }
        }
    }

    /// A heard form typed on a word: added, or, when another word has it, asked about (改给 / 两个都留).
    func addHeard(_ text: String, to t: Vocabulary.Term) {
        let h = text.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.count <= 40 else { return }
        if let owner = vocabulary.owners(ofHeard: h, except: t.word).first {
            wordConflict = WordConflict(word: t.word, heard: h, owner: owner)
        } else {
            vocabulary.confirm(heard: h, word: t.word, source: t.source)
        }
    }

    // MARK: Speakers (the Mac's AppModel.renameSpeaker / mergeSpeaker / undoSpeakerEdit)

    /// Name a voice ("" keeps 说话人 N, nil goes back to Ling's guess).
    func renameSpeaker(session id: String, voice: Int, _ name: String?) {
        guard let s = store.session(id) else { return }
        let n = SpeakerLabels.voiceNumbers(s)[voice] ?? 0
        let before = SpeakerLabels.label(n, SpeakerLabels.names(s))
        speakerEdit(id) { store.setVoiceName(id, voice: voice, name) }
        let after = store.session(id).map { SpeakerLabels.label(n, SpeakerLabels.names($0)) } ?? before
        if after != before { speakerUndo?.text = L("\(before) 已改成 \(after)") } else { speakerUndo = nil }
    }

    /// Two voices are one person.
    func mergeSpeaker(session id: String, _ from: Int, into: Int) {
        guard let s = store.session(id) else { return }
        let numbers = SpeakerLabels.voiceNumbers(s), names = SpeakerLabels.names(s)
        let a = SpeakerLabels.label(numbers[from] ?? 0, names), b = SpeakerLabels.label(numbers[into] ?? 0, names)
        speakerEdit(id) { store.mergeVoice(id, from, into: into) }
        speakerUndo?.text = L("\(a) 已并入 \(b)")
    }

    func undoSpeakerEdit() {
        guard let u = speakerUndo else { return }
        speakerUndo = nil
        store.restore(u.session, u.snapshot)
        debugLog("speakers: undo \(u.session)")
    }

    private func speakerEdit(_ id: String, _ change: () -> Void) {
        guard let snap = store.voiceSnapshot(id) else { return }
        change()
        let undo = SpeakerUndo(session: id, snapshot: snap, text: "")
        speakerUndo = undo
        debugLog("speakers: edit \(id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.speakerUndo?.id == undo.id { self?.speakerUndo = nil }
        }
    }

    /// cicada-dev://debug?cmd=… (dev builds only).
    func open(_ url: URL) {
        guard DevBuild.isDev, url.scheme == "cicada-dev", url.host == "debug",
              let cmd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cmd" })?.value else { return }
        debugCommand(cmd)
    }
}
