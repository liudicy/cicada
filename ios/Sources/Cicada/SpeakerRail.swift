import SwiftUI

/// Scheme A of the speaker colours (the design page 说话人配色): everyone's stretch of the meeting
/// is the same light grey, so a strip shows how many turns and how long; only the person you are
/// looking for, picked on a chip or the one the recording is at, is drawn in ink. Names stay ink
/// or grey text. The accent keeps meaning "live" and the playhead.
enum SpeakerRail {
    static let rest = Color(hex: 0xD5D8DE)
    static let focus = Ink.ink

    /// One person's unbroken stretch: consecutive lines of the same voice are one run.
    struct Run: Equatable {
        var number: Int?
        var start: Double
        var length: Double
    }

    /// The meeting as runs, by its lines' times (a line lasts until the next one starts).
    static func runs(_ s: Session, numbers: [String: Int]) -> [Run] {
        let lines = s.lines
        guard !lines.isEmpty else { return [] }
        let end = max(s.duration, (lines.last?.t ?? 0) + 3)
        var out: [Run] = []
        for (i, l) in lines.enumerated() {
            let next = i + 1 < lines.count ? lines[i + 1].t : end
            let n = numbers[l.id]
            let len = max(0.5, next - l.t)
            if var lastRun = out.last, lastRun.number == n {
                lastRun.length = next - lastRun.start
                out[out.count - 1] = lastRun
            } else {
                out.append(Run(number: n, start: l.t, length: len))
            }
        }
        return out
    }

    /// What a strip can draw: a turn under `minShare` of the meeting joins the one before it (a
    /// strip beside a row is a few dozen points tall), and neighbours of the same person merge.
    static func compact(_ runs: [Run], minShare: Double) -> [Run] {
        let total = runs.reduce(0) { $0 + $1.length }
        guard total > 0 else { return runs }
        var out: [Run] = []
        for r in runs {
            if var prev = out.last, prev.number == r.number || r.length < total * minShare {
                prev.length += r.length
                out[out.count - 1] = prev
            } else if out.isEmpty || r.length >= total * minShare {
                out.append(r)
            }
        }
        // A short first turn swallowed nothing before it: fold it into the next.
        if out.count > 1, out[0].length < total * minShare {
            out[1].start = out[0].start
            out[1].length += out[0].length
            out.removeFirst()
        }
        var merged: [Run] = []
        for r in out {
            if var prev = merged.last, prev.number == r.number { prev.length += r.length; merged[merged.count - 1] = prev } else { merged.append(r) }
        }
        return merged
    }

    /// Each speaker number's share of the time (0–1).
    static func shares(_ runs: [Run]) -> [Int: Double] {
        let total = runs.reduce(0) { $0 + $1.length }
        guard total > 0 else { return [:] }
        var out: [Int: Double] = [:]
        for r in runs { if let n = r.number { out[n, default: 0] += r.length / total } }
        return out
    }
}

/// The strip: across under a meeting's title, or upright beside a row.
struct RailView: View {
    enum Axis { case across, upright }
    let runs: [SpeakerRail.Run]
    var focus: Int? = nil
    var axis: Axis = .across
    var thickness: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            let length = axis == .across ? g.size.width : g.size.height
            let runs = SpeakerRail.compact(self.runs, minShare: axis == .across ? 0.01 : 0.08)
            let total = max(0.001, runs.reduce(0) { $0 + $1.length })
            // Too many turns for the room: no gaps, rather than a dotted line.
            let gap: CGFloat = CGFloat(runs.count) > length / 5 ? 0 : 2
            let room = length - gap * CGFloat(max(0, runs.count - 1))
            let layout = axis == .across ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
            layout {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                    let size = max(1, room * r.length / total)
                    RoundedRectangle(cornerRadius: min(3, thickness / 2), style: .continuous)
                        .fill(focus != nil && r.number == focus ? SpeakerRail.focus : SpeakerRail.rest)
                        .frame(width: axis == .across ? size : thickness, height: axis == .across ? thickness : size)
                }
            }
        }
        .frame(width: axis == .upright ? thickness : nil, height: axis == .across ? thickness : nil)
        .clipShape(RoundedRectangle(cornerRadius: min(3, thickness / 2), style: .continuous))
        .animation(.easeOut(duration: 0.18), value: focus)
        .accessibilityHidden(true)
    }
}

/// The record page's strip with the playhead: an accent mark where the recording is.
struct MeetingRail: View {
    let runs: [SpeakerRail.Run]
    let focus: Int?
    /// 0–1, nil before playing.
    let playhead: Double?

    var body: some View {
        RailView(runs: runs, focus: focus, thickness: 10)
            .overlay(alignment: .leading) {
                if let p = playhead {
                    GeometryReader { g in
                        Capsule().fill(Ink.accent)
                            .frame(width: 3, height: 18)
                            .overlay(Capsule().stroke(.white, lineWidth: 2))
                            .offset(x: g.size.width * min(1, max(0, p)) - 1.5, y: -4)
                    }
                }
            }
            .frame(height: 10)
    }
}
