import Foundation

/// 电脑和会议室's last line of defence against hearing a remote sentence twice: once from the Mac's
/// audio, once more from the speakers into the room mic. Echo cancellation and the gate stop most of
/// it; a room line still made mostly of what the Mac played around the same time is dropped. Feishu
/// dedupes across streams the same way (same time, text alike).
///
/// The room's copy is heard worse and cut differently, so it is matched by containment: how much of
/// the room line is found in the Mac's lines near it, in word pairs (characters for Chinese, Japanese
/// and Korean).
enum EchoMatch {
    struct Heard: Equatable {
        var text: String
        /// Wall-clock seconds (`CFAbsoluteTime`).
        var start: Double
        var end: Double
    }

    /// Seconds around the room line where the Mac's lines count.
    static let window = 3.0
    /// How long a room line waits for the Mac's line it may echo (the two recognizers end lines apart).
    static let hold = 2.5
    /// Share of the room line found in the Mac's lines that makes it an echo.
    static let contained = 0.6

    static func isEcho(_ room: Heard, online: [Heard]) -> Bool {
        let near = online.filter { $0.end >= room.start - window && $0.start <= room.end + window }
        guard !near.isEmpty else { return false }
        let r = units(room.text)
        guard !r.isEmpty else { return false }
        let o = near.map { units($0.text) }
        // A word or two ("OK", "对"): the very same words near it.
        if r.count <= 2 { return o.contains { $0 == r } }
        let mine = Set(pairs(r))
        let theirs = Set(o.flatMap(pairs))
        return Double(mine.intersection(theirs).count) / Double(mine.count) >= contained
    }

    /// Lower-case words, each CJK character on its own; punctuation and spacing don't count.
    static func units(_ text: String) -> [String] {
        var out: [String] = [], word = ""
        for c in text.lowercased() {
            if c.unicodeScalars.contains(where: cjk) {
                if !word.isEmpty { out.append(word); word = "" }
                out.append(String(c))
            } else if c.isLetter || c.isNumber {
                word.append(c)
            } else if !word.isEmpty {
                out.append(word)
                word = ""
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    private static func pairs(_ u: [String]) -> [String] {
        u.count < 2 ? u : (1..<u.count).map { u[$0 - 1] + " " + u[$0] }
    }

    private static func cjk(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
}
