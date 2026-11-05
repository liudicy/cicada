import Foundation

/// How meetings are listed in the records window (Mac) and the records tab (iOS).
enum RecordList {
    /// 今天 / 昨天 / 本周 / then one group per month, newest first.
    static func groups(_ sessions: [Session]) -> [(title: String, sessions: [Session])] {
        let cal = Calendar.current
        var out: [(title: String, sessions: [Session])] = []
        for s in sessions {
            let d = s.startedAt
            let title: String
            if cal.isDateInToday(d) { title = L("今天") }
            else if cal.isDateInYesterday(d) { title = L("昨天") }
            else if cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear) { title = L("本周") }
            else if cal.isDate(d, equalTo: Date(), toGranularity: .year) { title = dateText(d, "MMMM") }
            else { title = dateText(d, "yMMMM") }
            if out.last?.title == title { out[out.count - 1].sessions.append(s) } else { out.append((title, [s])) }
        }
        return out
    }
    static func when(_ s: Session) -> String {
        let cal = Calendar.current
        return dateText(s.startedAt, cal.isDateInToday(s.startedAt) || cal.isDateInYesterday(s.startedAt) ? "HHmm"
            : cal.isDate(s.startedAt, equalTo: Date(), toGranularity: .weekOfYear) ? "EEE" : "MMMd")
    }
    /// Notes titles often start with the day ("11月2日 产品周会"); under a 今天 heading that only
    /// pushes the real title out of the row.
    static func listTitle(_ s: Session) -> String {
        let title = s.displayTitle
        for prefix in [dateText(s.startedAt, "MMMd"), dateText(s.startedAt, "MMMMd")] where title.hasPrefix(prefix) {
            let rest = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return title
    }
    /// Still on the stored "会议 <date>" title: not renamed, and no notes title to show.
    static func untitled(_ s: Session) -> Bool {
        !(s.renamed ?? !s.title.hasPrefix("会议 ")) && (s.notes?.title ?? "").isEmpty && s.sourceFile == nil
    }

    static func length(_ s: Session) -> String {
        let mins = Int(s.duration / 60)
        if mins < 1 { return L("不到 1 分钟") }
        return mins < 60 ? L("\(mins) 分钟") : mins % 60 == 0 ? L("\(mins / 60) 小时") : L("\(mins / 60) 小时 \(mins % 60) 分")
    }

    /// "英 → 中" (short) or "英语 → 中文", from the most common pair among the lines.
    static func pair(_ s: Session, short: Bool) -> String? {
        let pairs = Dictionary(grouping: s.lines.filter { $0.speaker != "me" }, by: { "\(lang($0.srcLang))|\(lang($0.dstLang))" })
        guard let top = pairs.max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let p = top.split(separator: "|").map(String.init)
        guard p.count == 2, p[0] != p[1] else { return nil }
        func name(_ c: String) -> String {
            let names = ["en": L("英语"), "ja": L("日语"), "zh-CN": L("中文"), "zh-TW": L("繁中"), "ko": L("韩语"),
                         "es": L("西语"), "fr": L("法语"), "de": L("德语"), "pt": L("葡语")]
            guard let n = names[c] else { return c.uppercased() }
            guard short else { return n }
            return uiIsChinese ? String(n.prefix(1)) : c == "zh-TW" ? "ZH-TW" : String(c.prefix(2)).uppercased()
        }
        return "\(name(p[0])) → \(name(p[1]))"
    }

    private static func lang(_ code: String) -> String {
        let base = String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        return base == "zh" ? (code.contains("Hant") || code.hasSuffix("TW") || code.hasSuffix("HK") ? "zh-TW" : "zh-CN") : base
    }
}
