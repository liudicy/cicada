import SwiftUI
import UIKit

/// 分享链接 at the top of 导出: the Mac's share (ShareClient, cicada.indaloop.app) in one card.
/// 只分享纪要 or 纪要和双语全文, valid 7 days, no password (the Mac's defaults); the server checks
/// for sensitive content first, and flagged parts can be left out and checked again.
struct ShareCard: View {
    let session: Session
    private enum Step: Equatable {
        case idle, working
        case shared(ShareRecord)
        case blocked([ShareHit], kept: [Int])
        case failed(String)
    }
    @State private var step: Step = .idle
    @State private var scope: ShareScope = .notes
    @State private var removed: Set<Int> = []
    @State private var dropNotes = false
    @State private var copied = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "link").font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.accentText)
                        .frame(width: 40, height: 40).background(Ink.accentWash, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("分享链接").font(.headline).foregroundStyle(Ink.ink)
                        Text(subtitle).font(.footnote).foregroundStyle(Ink.secondary).lineLimit(2)
                    }
                }
                content
            }
            .padding(16)
        }
        .onAppear {
            if let r = ShareStore.read(session.id), r.expiresAt > Date() { step = .shared(r) }
            if session.notes == nil { scope = .full }
        }
    }

    private var subtitle: String {
        if case .shared(let r) = step { return validity(r) }
        return L("内容将上传至 cicada.indaloop.app，拿到链接的人都能看。")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .idle:
            PillSwitch(selection: $scope, options: session.notes == nil
                       ? [(.full, "纪要和双语全文")] : [(.notes, "只分享纪要"), (.full, "纪要和双语全文")])
            primary(L("生成链接")) { go() }
        case .working:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在检查有没有敏感内容…").font(.subheadline).foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        case .shared(let r):
            Text(verbatim: r.url).font(.subheadline.monospaced()).foregroundStyle(Ink.ink).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(Ink.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = clipboard(r)
                    copied = true
                    debugLog("share: copied")
                } label: {
                    Label(copied ? L("已复制") : L("复制链接"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46).background(Ink.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                if let url = URL(string: r.url) {
                    ShareLink(item: url, message: Text(verbatim: L("「\(session.displayTitle)」会议记录"))) {
                        Image(systemName: "square.and.arrow.up").font(.headline).foregroundStyle(Ink.ink)
                            .frame(width: 46, height: 46).background(Ink.ground, in: Circle())
                    }
                    .accessibilityLabel(Text("分享"))
                }
            }
        case .blocked(let hits, let kept):
            Text("检测到潜在敏感内容").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.accentText)
            Text("链接尚未生成。请先核对以下内容：").font(.footnote).foregroundStyle(Ink.secondary)
            ForEach(Array(hits.prefix(5).enumerated()), id: \.offset) { _, h in hitRow(h, kept: kept) }
            if hits.count > 5 { Text(L("还有 \(hits.count - 5) 处")).font(.footnote).foregroundStyle(Ink.secondary) }
            if leftAfterRemoving(hits, kept: kept) {
                Text("去掉后再检查一次；你的记录不会改动。").font(.footnote).foregroundStyle(Ink.secondary)
                primary(L("去掉这些内容后分享")) {
                    removed.formUnion(ShareHit.recordLines(hits, kept: kept))
                    if hits.contains(where: { $0.part == "notes" }) { dropNotes = true }
                    go()
                }
            } else {
                Text("去掉这些内容后就没有可分享的了。").font(.footnote).foregroundStyle(Ink.secondary)
            }
        case .failed(let message):
            Text(verbatim: message).font(.footnote).foregroundStyle(Ink.accentText)
            primary(L("重试")) { go() }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46).background(Ink.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func go() {
        step = .working
        copied = false
        let o = ShareClient.Options(scope: scope, days: 7, removed: removed, dropNotes: dropNotes)
        Task {
            switch await ShareClient.shared.share(session, o) {
            case .shared(let r): step = .shared(r)
            case .blocked(let hits, let kept): step = .blocked(hits, kept: kept)
            case .failed(let code, _): step = .failed(Self.message(code))
            }
        }
    }

    private func leftAfterRemoving(_ hits: [ShareHit], kept: [Int]) -> Bool {
        let notesLeft = session.notes != nil && !dropNotes && !hits.contains { $0.part == "notes" }
        guard scope == .full else { return notesLeft }
        let out = removed.union(ShareHit.recordLines(hits, kept: kept))
        return notesLeft || session.lines.indices.contains { !out.contains($0) && !session.lines[$0].src.isEmpty }
    }

    private func hitRow(_ h: ShareHit, kept: [Int]) -> some View {
        let what = ListFormatter.localizedString(byJoining: h.questions.map(Self.category))
        var place = L("纪要"), quote = session.notes?.summary ?? ""
        if h.part != "notes" {
            let lines = ShareHit.recordLines([h], kept: kept).sorted()
            let a = lines.first.map { TranscriptExport.clock(session.lines[$0].t) } ?? ""
            let b = lines.last.map { TranscriptExport.clock(session.lines[$0].t) } ?? ""
            place = a == b ? a : "\(a)–\(b)"
            quote = lines.first.map { session.lines[$0].src } ?? ""
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(what) · \(place)").font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink)
            Text(verbatim: quote).font(.footnote).foregroundStyle(Ink.secondary).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.accentWash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// As the Mac's: an hour's slack, so a fresh 7-day link reads 7, not 8.
    private static func daysLeft(_ r: ShareRecord) -> Int { max(1, Int(ceil((r.expiresAt.timeIntervalSinceNow - 3600) / 86400))) }

    private func validity(_ r: ShareRecord) -> String {
        let left = Self.daysLeft(r)
        return left >= 365 ? L("1 年内有效") : L("\(left) 天内有效")
    }

    /// What 复制链接 puts on the clipboard, as the Mac's: the title, the link, how long it lasts.
    private func clipboard(_ r: ShareRecord) -> String {
        [L("「\(session.displayTitle)」会议记录"), r.url, validity(r)].joined(separator: "\n")
    }

    /// The Mac's wording for the server's codes (ShareViews.swift).
    static func message(_ code: String) -> String {
        switch code {
        case "rate_limited", "too_many_shares": return L("分享得太频繁了，请稍后再试。")
        case "review_unavailable": return L("敏感内容检查暂时不可用，没有检查就不会分享。请稍后再试。")
        case "sharing_off": return L("分享功能暂时关闭了。")
        case "update_required": return L("请先更新知了。")
        case "too_large": return L("这场会议太长，可以只分享纪要。")
        case "bad_document": return L("这场会议没有可分享的内容。")
        case "network": return L("连不上 cicada.indaloop.app，请检查网络。")
        default: return L("服务器出了问题，请稍后再试。")
        }
    }

    static func category(_ q: String) -> String {
        switch q {
        case "credential": return L("密码或密钥")
        case "confidential": return L("未公开的公司信息")
        case "crossborder": return L("不宜跨境传输的信息")
        case "personal": return L("个人身份信息")
        case "harmful": return L("违法或危险内容")
        default: return q
        }
    }
}
