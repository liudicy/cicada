import Foundation
#if !CICADA_IOS
import SwiftUI
#endif

/// Searching a meeting's lines, shared by the notes window, the main window's records and the iOS
/// app's search, so a search finds the same lines (misheard names included) and marks them the same way.
enum TranscriptSearch {
    /// The query, plus every way the notes say that name was heard (江充 also finds 江松).
    static func terms(_ query: String, notes: [NoteTerm]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out = [q]
        for t in notes {
            let forms = [t.name] + t.heard
            if forms.contains(where: { $0.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains($0) }) {
                out += forms.filter { !$0.isEmpty && !out.contains($0) }
            }
        }
        return out
    }

    static func matches(_ l: TranscriptLine, _ terms: [String]) -> Bool {
        terms.contains { l.shown.localizedCaseInsensitiveContains($0) || (l.dst ?? "").localizedCaseInsensitiveContains($0) }
    }

    /// The ids of the lines a search finds, in order.
    static func matches(_ lines: [TranscriptLine], _ terms: [String]) -> [String] {
        guard !terms.isEmpty else { return [] }
        return lines.filter { matches($0, terms) }.map(\.id)
    }

    #if !CICADA_IOS
    /// Every term marked in place; the match being looked at stands out from the rest. iOS marks
    /// them in its own colours (ios/Sources/Cicada/RecordView.swift).
    static func highlighted(_ base: AttributedString, _ terms: [String], current: Bool) -> AttributedString {
        var a = base
        for term in terms where !term.isEmpty {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: term, options: .caseInsensitive) {
                a[r].backgroundColor = current ? Palette.accent : Palette.accentPale
                a[r].foregroundColor = current ? .white : Palette.accentInk
                from = r.upperBound
            }
        }
        return a
    }
    #endif
}
