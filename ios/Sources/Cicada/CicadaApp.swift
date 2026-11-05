import SwiftUI

@main
struct CicadaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.ling)
                .environmentObject(model.notes)
                .environmentObject(model.room)
                .onOpenURL { model.open($0) }
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

    /// 对方说 on iOS: one language the user picks (detecting it comes later); the Mac's "auto" reads as English.
    static var sourceLang: Lang {
        let v = UserDefaults.standard.string(forKey: source) ?? "en-US"
        return sourceLanguages.first { $0.locale == v } ?? sourceLanguages[0]
    }

    /// 对方说 in the UI's language ("英语", "English"), as the Mac's menu shows it.
    static func name(of lang: Lang) -> String {
        Locale.current.localizedString(forLanguageCode: lang.code) ?? lang.name
    }
    static var sourceName: String { name(of: sourceLang) }

    /// "英 → 中" for two translation codes, as a meeting row says it.
    static func pairText(_ source: String, _ target: String) -> String {
        let line = TranscriptLine(id: "", t: 0, speaker: "them", src: "", dst: nil, srcLang: source, dstLang: target)
        let s = Session(id: "", title: "", startedAt: Date(), endedAt: nil, lines: [line], hasAudio: false)
        return RecordList.pair(s, short: true) ?? ""
    }

    static var targetCode: String {
        let t = UserDefaults.standard.string(forKey: target) ?? "system"
        return t == "system" ? myLanguage(systemLanguages: Locale.preferredLanguages) : t
    }
}

/// Wires the shared engines to the screens, like the Mac's AppModel. M1: the records, the key and
/// their notes.
@MainActor
final class AppModel: ObservableObject {
    @Published var store = SessionStore()
    let ling = LingClient()
    lazy var notes = NotesEngine(ling: ling, store: store)
    lazy var translator = TranslationService(ling: ling)
    lazy var room: RoomListen = {
        let r = RoomListen(store: store, translator: translator, notes: notes)
        r.onStateChange = { [weak self] in self?.listeningChanged() }
        r.onLine = { [weak self] line in self?.liveActivity.update(line: line) }
        return r
    }()
    let liveActivity = LiveActivityController()
    /// 正在听's 字幕 / 纪要 switch, so a debug command can flip it.
    @Published var livePage: LivePage = .subtitles
    /// The record page's picked speaker (scheme A: only they are drawn in ink).
    @Published var focusSpeaker: Int?
    @Published var tab: AppTab = .records
    @Published var selection: String?
    /// A meeting opened from 搜索 (iPhone).
    @Published var searchPath: [String] = []
    /// The record page's 文字记录 / 纪要 switch, kept here so a debug command can flip it.
    @Published var recordPage: RecordPage = .transcript
    @Published var query = ""
    /// iPad: settings is a sheet over the records.
    @Published var showSettings = false
    /// What the 听会议室 card and the import button would start; they come with M2 and M3.
    @Published var comingSoon: String?
    /// "说话人 6 已改成 David · 撤销", for a few seconds after a speaker edit, as on the Mac.
    @Published var speakerUndo: SpeakerUndo?
    /// The speaker number whose 是谁 prompt is open on the record page.
    @Published var namingSpeaker: Int?
    /// Dev only: the iPad window size `window:` lays the app out at (DevWindow in Debug.swift).
    @Published var devWindow: CGSize?

    init() {
        UserDefaults.standard.register(defaults: [Pref.source: "en-US", Pref.voices: true, Pref.model: LingClient.models[0], Pref.notesLanguage: "mine"])
        TranscriptExport.voices = UserDefaults.standard.bool(forKey: Pref.voices)
        // Ling only for now: the Mac's other services (AIProvider) come to iOS with their settings.
        ling.config = {
            AIConfig(provider: .ling, base: AIProvider.ling.base,
                     textModel: UserDefaults.standard.string(forKey: Pref.model) ?? LingClient.models[0])
        }
        wireNotes()
        #if targetEnvironment(simulator)
        HostRecognizer.install()
        #endif
        DebugChannel.listen(self)
        debugLog("ios launch \(DevBuild.label ?? "release") sessions=\(store.sessions.count) key=\(ling.hasKey)")
        if ling.hasKey { Task { await ling.check() } }
    }

    // MARK: 听会议室

    func startListening() {
        guard !room.isRunning else { return }
        selection = nil
        searchPath = []
        tab = .records
        room.start(source: Pref.sourceLang.locale, target: Pref.targetCode, voices: UserDefaults.standard.bool(forKey: Pref.voices))
    }

    func stopListening() { room.stop() }

    private func listeningChanged() {
        objectWillChange.send()
        if room.isRunning, let start = room.startedAt {
            liveActivity.start(startedAt: start, pair: Pref.pairText(room.languagePair.source, room.languagePair.target))
        } else if !room.isRunning {
            liveActivity.end()
        }
    }

    /// Full notes for a stored meeting, as the Mac's 生成纪要.
    func generateNotes(_ id: String) {
        guard ling.hasKey else { return }
        recordPage = .notes
        notes.generate(for: id)
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
        if selection == id { selection = nil }
        searchPath.removeAll { $0 == id }
        if speakerUndo?.session == id { speakerUndo = nil }
        store.delete(id)
        debugLog("delete \(id) sessions=\(store.sessions.count)")
    }

    // MARK: Speakers (the Mac's AppModel.renameSpeaker / mergeSpeaker / undoSpeakerEdit)

    /// Name a voice ("" keeps 说话人 N, nil goes back to Ling's guess).
    func renameSpeaker(session id: String, voice: Int, _ name: String?) {
        guard let s = store.session(id) else { return }
        let n = SpeakerLabels.voiceNumbers(s.lines)[voice] ?? 0
        let before = SpeakerLabels.label(n, SpeakerLabels.names(s))
        speakerEdit(id) { store.setVoiceName(id, voice: voice, name) }
        let after = store.session(id).map { SpeakerLabels.label(n, SpeakerLabels.names($0)) } ?? before
        if after != before { speakerUndo?.text = L("\(before) 已改成 \(after)") } else { speakerUndo = nil }
    }

    /// Two voices are one person.
    func mergeSpeaker(session id: String, _ from: Int, into: Int) {
        guard let s = store.session(id) else { return }
        let numbers = SpeakerLabels.voiceNumbers(s.lines), names = SpeakerLabels.names(s)
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
