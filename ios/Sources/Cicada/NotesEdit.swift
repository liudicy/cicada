import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 复制纪要 and changing a finished meeting's notes in place, as on the Mac (RichCopy.swift,
/// NotesEditing.swift): the summary, a conclusion or a to-do; topics are the AI's to rewrite.
extension AppModel {
    /// Not while the meeting is being written, nor while an import is still transcribing.
    func canEditNotes(_ s: Session) -> Bool {
        s.id != store.liveID && importer.current?.id != s.id && !(s.notes?.isEmpty ?? true)
    }

    func editHooks(_ s: Session) -> NotesEditHooks? {
        guard canEditNotes(s) else { return nil }
        return NotesEditHooks(
            current: noteEdit?.session == s.id ? noteEdit?.target : nil,
            open: { [weak self] t in self?.noteEdit = t.map { NoteEdit(session: s.id, target: $0) } },
            save: { [weak self] t, text, owner in self?.saveNote(s.id, t, text: text, owner: owner) })
    }

    func saveNote(_ id: String, _ target: NoteEdit.Target, text: String, owner: String?? = nil) {
        guard var next = store.session(id)?.notes?.editing(target, text: text, owner: owner) else { return }
        next.updatedAt = Date()
        store.setNotes(id, next)
        notes.applyEdited(next, id: id)
        noteEdit = nil
        debugLog("notes edit: saved \(target) in \(id)")
    }

    /// 复制纪要: HTML for document apps (Feishu, DingTalk, Notion, Notes), the Markdown as plain text
    /// for chats; each app takes the one it reads.
    func copyNotes(_ s: Session) {
        let n = s.notes.map { SpeakerLabels.named($0, SpeakerLabels.names(s)) }
        let html = TranscriptExport.htmlDocument("<h1>\(TranscriptExport.esc(s.displayTitle))</h1>\n" + TranscriptExport.notesHTML(n))
        let markdown = "# \(s.displayTitle)\n\n" + TranscriptExport.notesMarkdown(n)
        UIPasteboard.general.setItems([[UTType.html.identifier: html, UTType.utf8PlainText.identifier: markdown]])
        copiedNotes = s.id
        debugLog("notes: copied \(html.count) chars of HTML, \(markdown.count) of Markdown")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if self.copiedNotes == s.id { self.copiedNotes = nil }
        }
    }
}

/// One editable piece of the notes: the text, a tap opens a field in place with 取消 and 完成.
struct EditableNote<Label: View>: View {
    let target: NoteEdit.Target
    let text: String
    let hooks: NotesEditHooks?
    @ViewBuilder let label: () -> Label
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let hooks, hooks.current == target {
            VStack(alignment: .trailing, spacing: 8) {
                TextField(text: $draft, axis: .vertical) { Text(verbatim: "") }
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.ink, lineWidth: 1.5) }
                    .onAppear { draft = text; focused = true }
                HStack(spacing: 8) {
                    Button { hooks.open(nil) } label: {
                        Text("取消").font(.subheadline).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 14).frame(minHeight: 36).background(Ink.ground, in: Capsule())
                    }
                    Button { hooks.save(target, draft, nil) } label: {
                        Text("完成").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(minHeight: 36).background(Ink.ink, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
            }
        } else if let hooks {
            label()
                .contentShape(Rectangle())
                .onTapGesture { hooks.open(target) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("改这一条"))
        } else {
            label()
        }
    }
}

/// 已复制纪要, dark above the player for a few seconds.
struct CopiedToast: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Color(hex: 0x7DD3A0))
            Text("已复制纪要，贴进飞书、钉钉、Notion 就是排好的").font(.subheadline).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Ink.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
