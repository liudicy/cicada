import SwiftUI
import UniformTypeIdentifiers

/// 存到文件夹's settings on iOS: the Mac's names (`exportOn`, `exportFolder`), plus the folder as a
/// security-scoped bookmark, since an app can reopen a folder picked in Files only through one.
@MainActor
final class FolderPrefs: FolderExportPrefs {
    private let d = UserDefaults.standard
    private static let bookmarkKey = "iosExportBookmark"

    var exportOn: Bool {
        get { d.bool(forKey: "exportOn") }
        set { d.set(newValue, forKey: "exportOn") }
    }
    var exportFolder: String {
        get { d.string(forKey: "exportFolder") ?? "" }
        set { d.set(newValue, forKey: "exportFolder") }
    }

    var exportFolderURL: URL? {
        guard let data = d.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { remember(url) }
        return url
    }

    /// Keeps the picked folder for later launches. Must run while the picker's access is open.
    @discardableResult
    func remember(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            debugLog("folder export: no bookmark for \(url.lastPathComponent)")
            return false
        }
        d.set(data, forKey: Self.bookmarkKey)
        return true
    }
}

/// 设置 › 存到文件夹: on/off, the folder (picked in Files: iCloud Drive, an Obsidian vault, any
/// app's folder), what was saved last or why it wasn't, and the meetings from before.
struct FolderPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var exporter: FolderExporter
    @State private var choosing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { exporter.on }, set: { on in
                            if on {
                                if let f = exporter.folder { exporter.choose(f) } else { choosing = true }
                            } else {
                                exporter.turnOff()
                            }
                            model.objectWillChange.send()
                        })) { Text("存到文件夹") }
                        .tint(Ink.ok)
                        Text("纪要和文字记录存成 Markdown；文件夹同步到哪，内容就到哪")
                            .font(.footnote).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    if let folder = exporter.folder {
                        Hairline()
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(Color(hex: 0x2B4A8B))
                                .frame(width: 40, height: 40).background(Color(hex: 0xE8EEF9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: FolderExporter.shortPath(folder)).foregroundStyle(Ink.ink).lineLimit(2)
                                if exporter.on, let name = exporter.index.lastFile, let at = exporter.index.lastAt {
                                    Text(L("上次存于 \(dateText(at, "MMMdHHmm")) · \(name)")).font(.caption).foregroundStyle(Ink.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Button { choosing = true } label: {
                                Text("更改…").font(.subheadline).foregroundStyle(Ink.ink)
                                    .padding(.horizontal, 12).frame(minHeight: 34).background(Ink.ground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                .padding(.top, 12)

                if exporter.on, let problem = exporter.problem, let folder = exporter.folder {
                    Card {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(Ink.accentText).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                switch problem {
                                case .denied:
                                    Text(L("没有权限写入 \(FolderExporter.shortPath(folder))")).font(.subheadline.weight(.semibold))
                                    Text("换个文件夹后自动补存").font(.footnote).foregroundStyle(Ink.secondary)
                                case .missing:
                                    Text(L("找不到 \(FolderExporter.shortPath(folder))")).font(.subheadline.weight(.semibold))
                                    Text("接上或换个文件夹后自动补存").font(.footnote).foregroundStyle(Ink.secondary)
                                case .failed(let message):
                                    Text("没存上").font(.subheadline.weight(.semibold))
                                    Text(verbatim: message).font(.footnote).foregroundStyle(Ink.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                    }
                    .padding(.top, 12)
                } else if exporter.checking, let folder = exporter.folder {
                    Text(L("正在确认能写入 \(FolderExporter.shortPath(folder))…")).font(.footnote).foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 4).padding(.top, 10)
                }

                let left = exporter.unwritten.count
                if exporter.on, left > 0 {
                    Card {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("以前的会议").foregroundStyle(Ink.ink)
                                Text(L("还有 \(left) 场没存")).font(.footnote).foregroundStyle(Ink.secondary)
                            }
                            Spacer()
                            Button { exporter.writeAll() } label: {
                                Text("也存一份").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(minHeight: 36).background(Ink.ink, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .padding(.top, 12)
                }
                Text("在“文件”里选一次文件夹：iCloud 云盘、Obsidian 库，或其他支持“文件”的 app。")
                    .font(.footnote).foregroundStyle(Ink.secondary).padding(.horizontal, 4).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.bottom, 120)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background(Ink.ground)
        .navigationTitle(Text("存到文件夹"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            if model.folderPrefs.remember(url) { exporter.choose(url) }
            model.objectWillChange.send()
        }
    }
}
