import ActivityKit
import Foundation

/// Starts the Live Activity when listening starts, sends it each translated line (at most every
/// 1.5 s: the system throttles more anyway) and ends it with the meeting.
@MainActor
final class LiveActivityController {
    private var activity: Activity<ListenActivity>?
    private var lastSent = Date.distantPast
    private var pending: ListenActivity.ContentState?
    private var people = 0
    private var paused = false
    private var last = ListenActivity.ContentState(line: "", source: "", people: 0)

    func start(startedAt: Date, pair: String) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            debugLog("live activity: not enabled")
            return
        }
        people = 0
        paused = false
        let state = ListenActivity.ContentState(line: "", source: "", people: 0)
        do {
            activity = try Activity.request(attributes: ListenActivity(startedAt: startedAt, pair: pair),
                                            content: .init(state: state, staleDate: nil))
            debugLog("live activity: started \(activity?.id ?? "-")")
        } catch {
            debugLog("live activity: request failed: \(error)")
        }
    }

    func update(line: RoomListen.Line, people: Int? = nil) {
        guard let activity else { return }
        if let people { self.people = people }
        let state = ListenActivity.ContentState(line: line.dst ?? "", source: line.src, people: self.people, paused: paused)
        last = state
        let wait = 1.5 - Date().timeIntervalSince(lastSent)
        if wait > 0 {
            let first = pending == nil
            pending = state
            if first {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    MainActor.assumeIsolated { self?.flush() }
                }
            }
            return
        }
        lastSent = Date()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    private func flush() {
        guard let activity, let state = pending else { return }
        pending = nil
        lastSent = Date()
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// 暂停 / 继续, shown at once (not held back by the line throttle).
    func setPaused(_ on: Bool) {
        guard let activity, paused != on else { return }
        paused = on
        last.paused = on
        pending = nil
        lastSent = Date()
        let state = last
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        pending = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        debugLog("live activity: ended")
    }
}
