import AppKit
import SwiftUI

/// The record's big title, edited in place: hovering shows it can be clicked, and leaving the field
/// saves as Return does (people clicked away and lost the change). Cleared, it goes back to the
/// automatic title; Esc puts back what was there.
struct RecordTitleField: View {
    let session: Session
    @ObservedObject var store: SessionStore
    /// What the field holds while editing; nil shows the record's title.
    @State private var draft: String?
    /// The title as editing began: saving it unchanged must not rename (the field shows `listTitle`,
    /// which can differ from the stored title).
    @State private var original = ""
    @State private var cancelled = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("标题", text: Binding(
                    // The date is on the line above; a notes title that starts with it shows without.
                    get: { draft ?? RecordList.listTitle(session) },
                    set: { draft = $0 }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .semibold))
                .focused($focused)
                .onSubmit { focused = false }
                .onExitCommand {
                    cancelled = true
                    focused = false
                }
                if hovering, !focused {
                    Image(systemName: "pencil").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && !focused ? Palette.fill : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.ink, lineWidth: focused ? 2 : 0))
            .padding(.horizontal, -8)
            .onHover { hovering = $0 }
            .help(focused ? "" : L("点击改标题"))
            if focused {
                Text("回车保存，Esc 取消").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
        }
        .background(GeometryReader { g in Color.clear.preference(key: TitleFrameKey.self, value: g.frame(in: .global)) })
        .onPreferenceChange(TitleFrameKey.self) { frame in clicks.frame = frame }
        .onChange(of: focused) { _, now in
            if now {
                original = RecordList.listTitle(session)
                draft = original
                cancelled = false
                // A click on the page around it doesn't take focus from a text field on macOS: watch for it.
                clicks.start { focused = false }
            } else {
                clicks.stop()
                commit()
            }
        }
        // Picking another meeting replaces this view before focus is lost: save what was typed.
        .onDisappear {
            clicks.stop()
            if draft != nil { commit() }
        }
    }

    @StateObject private var clicks = ClickOutside()

    @MainActor private func commit() {
        defer { draft = nil; cancelled = false }
        guard !cancelled, let d = draft?.trimmingCharacters(in: .whitespacesAndNewlines), d != original else { return }
        store.rename(session.id, to: d)
    }
}

private struct TitleFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// While the title is being edited: a click in the same window outside it ends the editing.
@MainActor final class ClickOutside: ObservableObject {
    /// The field in SwiftUI global space (the window's content, top-left origin).
    var frame: CGRect = .zero
    private var monitor: Any?

    func start(_ outside: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, window === NSApp.keyWindow, let content = window.contentView else { return event }
            let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if !self.frame.contains(p) { DispatchQueue.main.async { outside() } }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
