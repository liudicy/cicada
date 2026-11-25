import SwiftUI

/// 结束会议 by itself, as on the Mac and Android: the shared `MeetingEndWatch` ticked every two
/// seconds (every second while counting down). iOS can't see another app's microphone, so only
/// silence counts: nothing recognised for 多久算没人说话 → the countdown, then the meeting ends
/// where the words did and its notes are written. A meeting started from the Action Button or the
/// lock screen and forgotten would otherwise listen to an empty room for hours.
extension AppModel {
    var endConfig: MeetingEndWatch.Config {
        let d = UserDefaults.standard
        return MeetingEndWatch.Config(
            followApps: false,
            silence: MeetingEndWatch.Silence(rawValue: d.string(forKey: Pref.silenceEnd) ?? "prompt") ?? .prompt,
            silenceAfter: endTimesOverride?.0 ?? d.double(forKey: Pref.silenceMinutes) * 60,
            countdown: endTimesOverride?.1 ?? 60)
    }

    func watchEnd() {
        guard endWatch == nil else { return }
        endWatch = MeetingEndWatch(config: endConfig, start: Date())
        endHeard = (room.lines.count, room.draft)
        scheduleEndTick(2)
    }

    func stopWatchingEnd() {
        endTimer?.invalidate()
        endTimer = nil
        endWatch = nil
        if ending != nil { ending = nil }
    }

    private func scheduleEndTick(_ seconds: TimeInterval) {
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endTick() }
        }
    }

    private func endTick() {
        guard var w = endWatch, room.isRunning else { return }
        let now = Date()
        w.config = endConfig
        // Words, not sound: a new line, or the line being said changing (paused: nothing counts).
        if !room.paused, room.lines.count != endHeard.lines || (room.draft != endHeard.draft && !room.draft.isEmpty) {
            w.heard(at: now)
        }
        endHeard = (room.lines.count, room.draft)
        // Paused by the user: they chose to stop listening for now, so it isn't silence.
        if room.paused { w.keepGoing(at: now) }
        let reason = w.tick(at: now, calls: [:], said: !room.lines.isEmpty)
        endWatch = w
        if w.pending != ending {
            if let p = w.pending { debugLog("meeting end: pending \(p.reason), ends in \(Int(p.deadline.timeIntervalSince(now))) s") }
            else if ending != nil { debugLog("meeting end: pending cleared") }
            ending = w.pending
        }
        if let reason { autoEnd(reason, w); return }
        scheduleEndTick(w.pending != nil ? 1 : 2)
    }

    /// 继续记录 on the countdown.
    func keepRecording() {
        endWatch?.keepGoing(at: Date())
        ending = nil
        debugLog("meeting end: kept going")
    }

    /// Ends where the meeting really ended: a little after the last words.
    private func autoEnd(_ reason: MeetingEndWatch.Reason, _ w: MeetingEndWatch) {
        stopWatchingEnd()
        if reason == .nobodySpoke {
            debugLog("meeting end: nobody spoke for \(Int(w.config.silenceAfter)) s, stopped")
            room.stop()
            return
        }
        debugLog("meeting end: ended by itself (\(reason)), end time \(Int(Date().timeIntervalSince(w.lastSpeech) - 5)) s ago")
        room.stop(endedAt: w.lastSpeech.addingTimeInterval(5))
    }

    func endingTitle(_ p: MeetingEndWatch.Pending) -> String {
        L("已经 \(max(1, Int((endConfig.silenceAfter / 60).rounded()))) 分钟没人说话")
    }
}

/// The countdown above 正在听's pages: 已经 10 分钟没人说话 · 60 秒后结束会议并整理纪要 · 继续记录.
struct EndingStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let p = model.ending {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.endingTitle(p)).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    // Counts down by itself; the watch decides when it is over.
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        Text(L("\(max(0, Int(p.deadline.timeIntervalSince(t.date).rounded()))) 秒后结束会议并整理纪要"))
                            .font(.footnote).foregroundStyle(Ink.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 8)
                Button { model.keepRecording() } label: {
                    Text("继续记录").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .background(Ink.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
            .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.accent.opacity(0.35), lineWidth: 1.5) }
        }
    }
}
