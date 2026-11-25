import AppKit
import SwiftUI

/// 设置 › 通用 › 会后存一份.
struct FolderExportSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var exporter: FolderExporter
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard {
                SettingsRow(title: L("存到文件夹"), detail: L("纪要和文字记录存成 Markdown；文件夹同步到哪，内容就到哪"),
                            divider: exporter.on) {
                    Toggle("存到文件夹", isOn: Binding(get: { exporter.on }, set: { on in
                        if !on { exporter.turnOff() }
                        else if let folder = exporter.folder { exporter.choose(folder) }
                        else { choosing = true }
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Palette.ink)
                }
                if exporter.on, let folder = exporter.folder {
                    if exporter.checking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在确认能写入 \(FolderExporter.shortPath(folder))…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        Divider().padding(.leading, 16)
                    } else if let problem = exporter.problem {
                        problemRow(problem, folder).padding(.horizontal, 10).padding(.vertical, 8)
                        Divider().padding(.leading, 16)
                    }
                    SettingsRow(title: L("位置"), detail: FolderExporter.shortPath(folder),
                                divider: !exporter.unwritten.isEmpty,
                                mark: nil) {
                        HStack(spacing: 8) {
                            if FolderExporter.vault(of: folder) != nil { Tag(L("Obsidian 库")) }
                            SoftButton(L("打开")) { NSWorkspace.shared.open(folder) }
                            SoftButton(L("更改…")) { choosing = true }
                        }
                    }
                    let left = exporter.unwritten.count
                    if left > 0 {
                        SettingsRow(title: L("以前的会议"), detail: L("还有 \(left) 场没存"), divider: false) {
                            SoftButton(L("也存一份")) { exporter.writeAll() }
                        }
                    }
                }
            }
            if exporter.on, let name = exporter.index.lastFile, let at = exporter.index.lastAt {
                Text("上次存于 \(dateText(at, "MMMdHHmm")) · \(name)")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 4)
            }
        }
        .sheet(isPresented: $choosing) {
            FolderChoice(current: exporter.folder) { url in
                choosing = false
                if let url { exporter.choose(url) }
            }
        }
    }

    @ViewBuilder private func problemRow(_ problem: FolderExporter.Problem, _ folder: URL) -> some View {
        let waiting = exporter.index.pending.count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                switch problem {
                case .denied:
                    Text("没有权限写入 \(FolderExporter.shortPath(folder))").font(.system(size: 13, weight: .semibold))
                    Text(waiting > 0 ? L("\(waiting) 场会议没存上，允许后自动补存") : L("在系统设置里允许知了，或换个文件夹"))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                case .missing:
                    Text("找不到 \(FolderExporter.shortPath(folder))").font(.system(size: 13, weight: .semibold))
                    Text("接上或换个文件夹后自动补存").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                case .failed(let message):
                    Text("没存上").font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
                }
            }
            .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            if problem == .denied { SoftButton(L("去系统设置"), dark: true) { FolderExporter.openPrivacySettings() } }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(problem == .denied ? Palette.accentPale : Palette.ground))
    }
}

/// 存到哪里: an Obsidian vault first (a new Cicada folder in it), then 文稿 › Cicada, or any folder.
struct FolderChoice: View {
    let current: URL?
    let done: (URL?) -> Void
    @State private var pick = 0
    private let options: [(title: String, detail: String?, url: URL?)]

    init(current: URL?, done: @escaping (URL?) -> Void) {
        self.current = current
        self.done = done
        var options: [(String, String?, URL?)] = FolderExportFormat.obsidianVaults.prefix(3).map {
            (L("Obsidian 库「\($0.lastPathComponent)」"), L("在库里新建 Cicada 文件夹"), $0.appendingPathComponent("Cicada", isDirectory: true))
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        options.append((FileManager.default.displayName(atPath: documents.path) + " › Cicada", nil, documents.appendingPathComponent("Cicada", isDirectory: true)))
        options.append((L("其他文件夹…"), nil, nil))
        self.options = options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("存到哪里").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
            VStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    Button { pick = i } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: pick == i ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13)).foregroundStyle(pick == i ? Palette.ink : Palette.tertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(o.title).font(.system(size: 13, weight: pick == i ? .semibold : .regular)).foregroundStyle(Palette.ink)
                                if let d = o.detail { Text(d).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 9).stroke(pick == i ? Palette.ink : Palette.line, lineWidth: pick == i ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("macOS 可能会问一次能不能访问这个位置").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            HStack(spacing: 8) {
                Spacer()
                SoftButton(L("取消")) { done(nil) }.keyboardShortcut(.cancelAction)
                SoftButton(L("存到这里"), dark: true) { confirm() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.white)
    }

    private func confirm() {
        if let url = options[pick].url { done(url); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("存到这里")
        panel.message = L("会后把纪要和文字记录存成 Markdown 到这里")
        panel.directoryURL = current ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        done(panel.runModal() == .OK ? panel.url : nil)
    }
}

/// The record's line under its title: where its file is, or why it isn't there yet.
struct FolderExportLine: View {
    @ObservedObject var exporter: FolderExporter
    @ObservedObject var model: AppModel
    let session: Session

    var body: some View {
        if exporter.on, let folder = exporter.folder, exporter.ready(session) {
            let short = FolderExporter.shortPath(folder)
            HStack(spacing: 4) {
                if let file = exporter.file(for: session.id), !exporter.isPending(session.id) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text("已存到 \(short) ·")
                    Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.plain).foregroundStyle(Palette.link)
                } else if exporter.isPending(session.id), exporter.problem != nil {
                    Text("没存到文件夹 ·")
                    Button(L("去设置")) { model.openSettings(.records) }
                        .buttonStyle(.plain).foregroundStyle(Palette.link)
                } else if exporter.isPending(session.id) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text("整理好后存到 \(short)")
                }
            }
            .font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
        }
    }
}
