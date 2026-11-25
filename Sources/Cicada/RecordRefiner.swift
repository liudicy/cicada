import Foundation
import NaturalLanguage

/// Lays the record recognizer's sentences (`RecordHearing`) over the lines the live recognizer
/// already gave: each line keeps its id, speaker and timestamp and only its words change.
///
/// Time says when a line is covered; the text says where it ends. The live recognizer's line times
/// and the record recognizer's word times disagree by up to a second, so splitting by time moved
/// words between lines ("通 / 知"). The two texts mostly agree, so the record's text is aligned with
/// the lines' (edit distance) and cut where each line's text ends. A word the live recognizer split
/// at a cut goes whole to one side, and words it lost go to the line they were said in.
struct RecordRefiner {
    struct Line {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }

    /// Lines not settled yet, in order.
    private(set) var lines: [Line] = []
    /// The record's text not given to a line yet.
    private var pending = ""
    /// Where the record recognizer's last finished sentence ended.
    private var heardThrough = -Double.infinity

    /// A line whose next one hasn't come yet settles once this much has been heard after it: what
    /// follows could still be the start of the next line.
    static let wait = 2.0

    /// A line the live recognizer finished. Returns the lines that settled: id and text ("" when
    /// the record recognizer heard nothing for it).
    mutating func emitted(id: Int, start: Double, end: Double, text: String) -> [(id: Int, text: String)] {
        guard start.isFinite, end.isFinite else { return [] }
        lines.append(Line(id: id, start: start, end: max(start, end), text: text))
        return settle(final: false)
    }

    /// A sentence the record recognizer finished, through the end of the audio it covers (its
    /// last word, or the pause after it).
    mutating func heard(_ sentence: [Recognition.Run], through: Double? = nil) -> [(id: Int, text: String)] {
        guard let last = sentence.last else { return [] }
        pending += sentence.map(\.text).joined()
        heardThrough = max(heardThrough, through ?? last.end)
        return settle(final: false)
    }

    /// The record recognizer heard everything there was.
    mutating func finish() -> [(id: Int, text: String)] { settle(final: true) }

    private mutating func settle(final: Bool) -> [(id: Int, text: String)] {
        // The lines the record has heard all of, in order.
        var covered = 0
        while covered < lines.count {
            let l = lines[covered]
            let nextKnown = covered + 1 < lines.count
            guard final || heardThrough >= l.end - 0.05 && (nextKnown || heardThrough >= l.end + Self.wait) else { break }
            covered += 1
        }
        guard covered > 0 else { return [] }
        let settling = Array(lines[..<covered])
        lines.removeFirst(covered)
        let record = Array(pending)
        // The next line, when known, helps decide where the last settling one ends.
        let context = settling.map(\.text) + (lines.first.map { [$0.text] } ?? [])
        let ends = Self.split(record, at: context, freeTail: !final)
        var out: [(id: Int, text: String)] = []
        var from = 0
        for (i, l) in settling.enumerated() {
            // Finishing: whatever is left belongs to the last line.
            let to = final && i == settling.count - 1 ? record.count : ends[i]
            out.append((l.id, String(record[from..<max(from, to)])))
            from = max(from, to)
        }
        pending = String(record[from...])
        return out
    }

    /// Where in `record` each of `lines` ends: the record aligned with the lines' text joined, by
    /// edit distance. With `freeTail` the record may run on past the lines (a sentence that goes
    /// into a line not given yet).
    static func split(_ record: [Character], at lines: [String], freeTail: Bool) -> [Int] {
        let live = Array(lines.joined())
        let n = live.count, m = record.count
        var bounds: [Int] = []
        var acc = 0
        for t in lines { acc += t.count; bounds.append(acc) }
        guard n > 0, m > 0 else { return bounds.map { _ in 0 } }
        // d[i][j]: cost of live[..<i] against record[..<j].
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let same = Self.same(live[i - 1], record[j - 1])
                d[i][j] = min(d[i - 1][j - 1] + (same ? 0 : 1), d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        var j = m
        if freeTail { j = (0...m).min { d[n][$0] < d[n][$1] || d[n][$0] == d[n][$1] && $0 > $1 }! }
        // Walk back, noting the record position at each live position (the furthest one).
        // `low`: the nearest one, before the record words inserted there.
        var at = Array(repeating: 0, count: n + 1)
        var low = at
        var i = n
        at[n] = j
        low[n] = j
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (Self.same(live[i - 1], record[j - 1]) ? 0 : 1) {
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
                low[i] = j
                continue
            }
            if at[i] == 0 { at[i] = j }
            low[i] = j
        }
        var ends = bounds.map { b in at[b] }
        // The live lines were often cut mid-sentence for the subtitles: a line ends at the record's
        // nearest punctuation when there is some a few characters away.
        // Otherwise it ends between words: Chinese comes one character per run, and "审 / 计" is no line end.
        let words = Self.wordStarts(record)
        let inside = HeardText.insideConnectives(record)
        // A line the speaker ended a sentence on was not cut: its end is where the next voice may
        // start, and the record often drops the "." ("lock that in" + " Okay,"): snapping there
        // took the next speaker's word. It only takes the mark that ends its last word. Words the
        // live recognizer lost between the two ("Friday." + " Great." + "Let's…") cost the same on
        // either side: its "." is the record's first one there, and they start the next line.
        let mark: (Character) -> Bool = { "。！？.!?".contains($0) }
        for k in ends.indices {
            let closed = lines[k].last.map(mark) ?? false
            var e = ends[k]
            if !closed { e = Self.snap(e, in: record) }
            else if bounds[k] > 0, case let p = low[bounds[k] - 1], p < e - 1, mark(record[p]) { e = p + 1 }
            if e == ends[k], e > 0, e < m, !words.contains(e) {
                let after = (e...m).first { words.contains($0) || $0 == m } ?? m
                let before = (0...e).last { words.contains($0) } ?? 0
                e = after - e <= e - before ? after : before
            }
            if closed, e > 0, e < m, mark(record[e]) { e += 1 }
            // "所 / 以": the tokenizer splits some connectives; the line ends before the whole word.
            if let start = inside[e] { e = start }
            ends[k] = max(e, k > 0 ? ends[k - 1] : 0)
        }
        return ends
    }

    /// Character offsets where a word starts (and the end).
    static func wordStarts(_ record: [Character]) -> Set<Int> {
        let text = String(record)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var starts: Set<Int> = [0, record.count]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            starts.insert(text.distance(from: text.startIndex, to: range.lowerBound))
            starts.insert(text.distance(from: text.startIndex, to: range.upperBound))
            return true
        }
        return starts
    }

    static let snapReach = 6

    /// `e`, or just after the closest sentence mark within `snapReach` characters.
    static func snap(_ e: Int, in record: [Character]) -> Int {
        func mark(_ c: Character) -> Bool { "，。？！；、,.?!;".contains(c) }
        guard e > 0, e < record.count, !mark(record[e - 1]) else { return e }
        for d in 0..<snapReach {
            if e + d < record.count, mark(record[e + d]) { return e + d + 1 }
            if e - 1 - d > 0, mark(record[e - 1 - d]) { return e - d }
        }
        return e
    }

    private static func same(_ a: Character, _ b: Character) -> Bool {
        a == b || a.lowercased() == b.lowercased()
    }
}
