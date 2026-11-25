import SwiftUI
import UniformTypeIdentifiers

// 导出: Markdown and SRT are the Mac's own (TranscriptExport); Word is written here, since the Mac's
// `.officeOpenXML` writer is macOS-only. Same order and content as the Mac's `TranscriptExport.docx`.

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, word, srt
    var id: String { rawValue }

    var ext: String {
        switch self {
        case .markdown: "md"
        case .word: "docx"
        case .srt: "srt"
        }
    }

    /// The file, under a temporary folder, named after the meeting.
    @MainActor func file(_ s: Session) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = s.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent(name.isEmpty ? "Cicada" : name).appendingPathExtension(ext)
        switch self {
        case .markdown: try Data(TranscriptExport.markdown(s).utf8).write(to: url)
        case .srt: try Data(TranscriptExport.srt(s).utf8).write(to: url)
        case .word: try Docx.document(s).write(to: url)
        }
        return url
    }
}

/// A minimal .docx: three XML parts in a zip, stored uncompressed (Word reads that fine), no
/// third-party code.
enum Docx {
    struct Para {
        var text: String
        var size: Int          // points
        var bold = false
        var grey = false
        var after = 4          // points after
    }

    @MainActor static func document(_ s: Session) -> Data {
        var p: [Para] = []
        func add(_ text: String, _ size: Int, bold: Bool = false, grey: Bool = false, after: Int = 4) {
            p.append(Para(text: text, size: size, bold: bold, grey: grey, after: after))
        }
        add(s.displayTitle, 20, bold: true, after: 6)
        add(TranscriptExport.header(s), 10, grey: true, after: 14)
        if let n = s.notes, !n.isEmpty {
            add(L("纪要"), 15, bold: true, after: 6)
            add(n.summary, 11, after: 10)
            for t in n.topics {
                add("\(TranscriptExport.clock(t.start))  \(t.title)", 12, bold: true, after: 3)
                if !t.summary.isEmpty { add(t.summary, 11, grey: true, after: 3) }
                for pt in t.points { add("• \(pt)", 11, after: 2) }
                if let f = t.fishbone {
                    add(f.question, 11, bold: true, after: 2)
                    for b in f.branches { add("  – \(b.label)：\(b.detail)", 11, after: 2) }
                }
                add("", 6, after: 4)
            }
            if !n.conclusions.isEmpty {
                add(L("结论"), 12, bold: true, after: 3)
                for c in n.conclusions { add("• \(c.text)", 11, after: 2) }
            }
            if !n.todos.isEmpty {
                add(L("待办"), 12, bold: true, after: 3)
                for t in n.todos { add("☐ \(t.withOwner)", 11, after: 2) }
            }
            add(L("文字记录"), 15, bold: true, after: 6)
        }
        let numbers = TranscriptExport.speakerNumbers(s), names = SpeakerLabels.names(s)
        for l in s.lines {
            let who = TranscriptExport.saysWho(s, numbers) ? " \(TranscriptExport.speakerName(l, numbers, names))" : ""
            add("[\(TranscriptExport.clock(l.t))]" + who, 9, bold: true, grey: true, after: 2)
            add(l.shown, 11, after: 2)
            if let d = l.dst, d != l.shown { add(d, 11, grey: true, after: 10) }
        }
        return zip([
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", rels),
            ("word/document.xml", body(p)),
        ])
    }

    static func body(_ paras: [Para]) -> String {
        var out = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
        for p in paras {
            out += "<w:p><w:pPr><w:spacing w:after=\"\(p.after * 20)\"/></w:pPr><w:r><w:rPr>"
            if p.bold { out += "<w:b/>" }
            if p.grey { out += "<w:color w:val=\"5A5F6B\"/>" }
            out += "<w:sz w:val=\"\(p.size * 2)\"/></w:rPr><w:t xml:space=\"preserve\">\(escape(p.text))</w:t></w:r></w:p>"
        }
        return out + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>"#
    }

    static func escape(_ s: String) -> String {
        // Control characters other than tab are not allowed in XML 1.0.
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }))
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#
    static let rels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#

    /// A zip with every entry stored (method 0).
    static func zip(_ entries: [(String, String)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8(v >> (8 * UInt32(i)) & 0xFF)) } }
        for (name, text) in entries {
            let data = Data(text.utf8), nameData = Data(name.utf8)
            let crc = crc32(data), offset = UInt32(out.count)
            // Local header: signature, version 2.0, flags (bit 11: UTF-8 names), stored, no time.
            u32(0x0403_4B50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out)
            u16(nameData.count, &out); u16(0, &out)
            out.append(nameData); out.append(data)
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(0x21, &central)
            u32(crc, &central); u32(UInt32(data.count), &central); u32(UInt32(data.count), &central)
            u16(nameData.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central.append(nameData)
        }
        let start = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(start, &out); u16(0, &out)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// 分享和导出: 分享链接 (ShareCard), then the three formats and 分享 (the system share sheet with the file).
struct ExportSheet: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("iosExportFormat") private var format = ExportFormat.markdown.rawValue
    @State private var file: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分享和导出").font(.title3.bold()).foregroundStyle(Ink.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Ink.secondary)
                        .frame(width: 32, height: 32).background(Ink.line, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("关闭"))
            }
            .padding(.horizontal, 4).padding(.top, 16)
            ShareCard(session: session).padding(.top, 8)
            SectionLabel(text: L("存成文件"))
            Card {
                ForEach(Array(ExportFormat.allCases.enumerated()), id: \.element) { i, f in
                    if i > 0 { Hairline(inset: 62) }
                    Button { format = f.rawValue } label: { row(f) }
                        .buttonStyle(RowPress())
                        .accessibilityAddTraits(format == f.rawValue ? .isSelected : [])
                }
            }
            Spacer(minLength: 20)
            Group {
                if let file {
                    ShareLink(item: file) { shareLabel }
                } else {
                    shareLabel.opacity(0.4)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .background(Ink.ground)
        .task(id: format) { make() }
        .presentationDetents([.large])
        .presentationCornerRadius(34)
    }

    private var shareLabel: some View {
        Label("分享", systemImage: "square.and.arrow.up")
            .font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Ink.ink, in: Capsule())
    }

    private func row(_ f: ExportFormat) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: f == .markdown ? "MD" : f == .word ? "W" : "SRT")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(f == .word ? Color(hex: 0x1F4E8C) : Ink.ink)
                .frame(width: 34, height: 34).background(Ink.ground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: f == .markdown ? "Markdown" : f == .word ? "Word" : L("SRT 字幕")).foregroundStyle(Ink.ink)
                Text(f == .markdown ? L("文字记录和纪要") : f == .word ? L("直接发给同事") : L("配原声或视频"))
                    .font(.footnote).foregroundStyle(Ink.secondary)
            }
            Spacer()
            if format == f.rawValue {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Ink.ink)
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 58)
        .contentShape(Rectangle())
    }

    private func make() {
        let f = ExportFormat(rawValue: format) ?? .markdown
        do {
            file = try f.file(session)
            debugLog("export: \(f.rawValue) \(file?.lastPathComponent ?? "") \((try? file?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes")
        } catch {
            file = nil
            debugLog("export: \(f.rawValue) failed: \(error)")
        }
    }
}
