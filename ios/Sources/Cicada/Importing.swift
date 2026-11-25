import BackgroundTasks
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// 导入录音或视频: the Mac's FileImporter, fed from Files, Photos or another app's share sheet. Each
// file is copied into the app first (a picked file's access ends with the picker, and Photos hands
// over a temporary copy), and the copy is the record's source. While files are turning into
// records the system keeps the app running behind other apps (BGContinuedProcessingTask) and shows
// its progress.

/// 对方说 and 翻译成 as the iOS app has them: an import is in the language the user listens to
/// (自动识别: FileImporter hears it).
@MainActor
final class ImportPrefs: ImportSettings {
    var importLanguage: String { Pref.sourceAuto ? "auto" : Pref.sourceLang.locale }
    var speakerVoices: Bool { UserDefaults.standard.bool(forKey: Pref.voices) }
    func resolvedTarget(source: String?) -> String { Pref.target(for: source ?? Pref.sourceLang.code) }
}

enum ImportFiles {
    /// The app's own copies of imported files.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder).appendingPathComponent("Imports")
    }

    /// A copy under `folder`, keeping the file's name (it becomes the record's title).
    static func copy(_ url: URL) -> URL? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dir = folder.appendingPathComponent(UUID().uuidString)
        let out = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: out)
            return out
        } catch {
            debugLog("import: can't copy the file: \(error)")
            return nil
        }
    }

    /// The copy goes with its record.
    static func remove(_ path: String?) {
        guard let path, path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}

/// A video from Photos, as a file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            // The received file is gone after this returns: our own copy is what is imported.
            guard let copy = ImportFiles.copy(received.file) else { throw CocoaError(.fileWriteUnknown) }
            return PickedMovie(url: copy)
        }
    }
}

/// The system's progress for imports running behind other apps (iOS 26).
@MainActor
enum ImportBackground {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.indaloop.cicada") + ".import" }
    private static var task: BGContinuedProcessingTask?
    private static var ticker: Timer?
    static weak var importer: FileImporter?

    /// Before the app finishes launching, as BGTaskScheduler requires.
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { t in
            MainActor.assumeIsolated { run(t) }
        }
        debugLog("import: background task registered=\(ok)")
    }

    static func begin(_ title: String) {
        guard task == nil else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L("正在导入"), subtitle: title)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugLog("import: background task not submitted: \(error)")
        }
    }

    private static func run(_ t: BGTask) {
        guard let t = t as? BGContinuedProcessingTask else { t.setTaskCompleted(success: false); return }
        task = t
        t.progress.totalUnitCount = 1000
        t.expirationHandler = {
            // The system wants the time back: what was transcribed stays, the record offers 重新转写.
            MainActor.assumeIsolated {
                debugLog("import: background time expired")
                importer?.cancelAll()
                finish(success: false)
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let importer, let task else { return }
                if !importer.busy { finish(success: true); return }
                task.progress.completedUnitCount = Int64(importer.progress * 1000)
                if let id = importer.current?.id, let s = importer.store.session(id) {
                    task.updateTitle(L("正在导入"), subtitle: s.displayTitle)
                }
            }
        }
        debugLog("import: running in the background")
    }

    private static func finish(success: Bool) {
        ticker?.invalidate()
        ticker = nil
        task?.setTaskCompleted(success: success)
        task = nil
    }
}

extension AppModel {
    /// Files from the picker, Photos or the share sheet: copied, then queued as records.
    func importFiles(_ urls: [URL], copied: Bool = false) {
        let files = urls.filter(FileImporter.importable).compactMap { copied ? $0 : ImportFiles.copy($0) }
        guard !files.isEmpty else {
            if !urls.isEmpty { importProblem = L("只能导入录音或带声音的视频") }
            return
        }
        Task {
            let ids = await importer.add(files)
            debugLog("import: added \(ids.count) files")
            ImportBackground.begin(files[0].deletingPathExtension().lastPathComponent)
        }
    }

    /// A file shared to the app ("用知了打开"): it arrives in the app's Inbox, already a copy.
    func openedFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        importFiles([url])
        try? FileManager.default.removeItem(at: url)
        return true
    }
}

/// The import button's two sources.
struct ImportMenu<Label: View>: View {
    @EnvironmentObject var model: AppModel
    @State private var files = false
    @State private var photo: PhotosPickerItem?
    @State private var photos = false
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            Button { files = true } label: { SwiftUI.Label("从文件导入", systemImage: "folder") }
            Button { photos = true } label: { SwiftUI.Label("从相册导入视频", systemImage: "photo.on.rectangle") }
        } label: { label }
        .accessibilityLabel(Text("导入录音或视频"))
        .fileImporter(isPresented: $files, allowedContentTypes: [.audio, .movie, .audiovisualContent], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .photosPicker(isPresented: $photos, selection: $photo, matching: .videos)
        .onChange(of: photo) {
            guard let item = photo else { return }
            photo = nil
            Task {
                do {
                    if let movie = try await item.loadTransferable(type: PickedMovie.self) { model.importFiles([movie.url], copied: true) }
                } catch {
                    debugLog("import: Photos video failed: \(error)")
                    model.importProblem = L("这个视频读不出来")
                }
            }
        }
    }
}

/// 正在导入, at the top of the records while files are turning into records: the file, how far
/// it has got, and 停止.
struct ImportCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var importer: FileImporter

    var body: some View {
        if let job = importer.current {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: L("正在导入"))
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: job.url.pathExtension.lowercased().isVideo ? "film" : "waveform")
                                .font(.system(size: 18)).foregroundStyle(Ink.ink).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: job.url.lastPathComponent).font(.body.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                                Text(phase).font(.footnote).foregroundStyle(Ink.secondary).lineLimit(1).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            Button { importer.cancel(job.id) } label: {
                                Text("停止").font(.subheadline).foregroundStyle(Ink.ink)
                                    .padding(.horizontal, 12).frame(minHeight: 32)
                                    .background(Ink.ground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                        }
                        ProgressView(value: importer.progress).tint(Ink.ink)
                        Text(importer.queue.isEmpty ? L("切到别的 app 也会继续") : L("还有 \(importer.queue.count) 个文件在排队"))
                            .font(.footnote).foregroundStyle(Ink.tertiary)
                    }
                    .padding(16)
                }
            }
        }
    }

    private var phase: String {
        switch importer.phase {
        case .preparing: L("正在读取文件…")
        case .detecting: L("正在听是哪种语言…")
        case .downloading(let name): L("正在下载 \(name) 语音模型…")
        case .transcribing: L("文字记录已转到 \(TranscriptExport.clock(importer.heard)) / \(TranscriptExport.clock(importer.duration))")
        case .translating:
            model.translationDown ? L("连不上翻译，\(importer.untranslated) 句等连上后再翻") : L("还有 \(importer.untranslated) 句在翻译")
        }
    }
}

private extension String {
    var isVideo: Bool { UTType(filenameExtension: self)?.conforms(to: .movie) ?? false }
}
