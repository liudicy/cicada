import Foundation
import Testing
@testable import LiveSubs

/// The diagnostics list: requests grouped by use, service and model; speak-back to the first sound;
/// partial translations counted in memory.
@MainActor struct DiagnosticsTests {
    private func diag() -> Diagnostics {
        let d = Diagnostics()
        d.enabled = { true }
        d.begin()
        return d
    }

    private func call(_ role: String, _ seconds: Double, outcome: String = "ok", provider: String = "zenmux",
                      model: String = "inclusionai/ling-3.0-flash", tokens: Int = 10, chars: Int = 0,
                      firstAudio: Double? = nil) -> AICall {
        AICall(at: Date(), provider: provider, model: model, role: role, priority: "translate", queue: 0, seconds: seconds,
               outcome: outcome, promptTokens: tokens, completionTokens: 0, chars: chars, firstAudio: firstAudio)
    }

    private func sentence(_ side: String, via: String, fallbacks: [String] = [], recognize: Double = 0.5,
                          translate: Double = 1, firstAudio: Double? = nil) -> SentenceTiming {
        SentenceTiming(at: Date(), side: side, chars: 10, recognize: recognize, queue: 0, translate: translate, voice: nil,
                       failed: 0, via: via, fallbacks: fallbacks, firstAudio: firstAudio)
    }

    @Test func usesGroupByRoleAndModelInOrder() {
        let d = diag()
        d.record(call("notes", 5))
        d.record(call("translate", 1))
        d.record(call("translate", 3))
        d.record(call("translate", 0.1, outcome: "rateLimited"))
        d.record(call("voice", 4, model: "google/gemini-3.8-flash-tts", tokens: 0, chars: 12, firstAudio: 0.9))
        d.record(call("voice", 2, outcome: "cancelled", model: "google/gemini-3.8-flash-tts", tokens: 0, chars: 5))
        d.record(call("test", 1))
        let uses = d.uses
        #expect(uses.map(\.role) == ["translate", "voice", "notes"])   // test scores aren't a use
        let t = uses[0]
        #expect(t.n == 3 && t.failed == 1 && t.tokens == 30)
        #expect(t.reasons.first?.0 == "rateLimited")
        #expect(t.latency?.n == 2)   // only answered requests time the use
        let v = uses[1]
        #expect(v.failed == 0)       // cut short on purpose isn't a failure
        #expect(v.latency?.p50 == 0.9)   // to the first audio, not the whole clip
        #expect(v.chars == 17)
    }

    @Test func aModelSwitchMidMeetingIsItsOwnRow() {
        let d = diag()
        d.record(call("translate", 1, model: "a"))
        d.record(call("translate", 1, model: "b"))
        d.record(call("translate", 1, model: "b"))
        #expect(d.uses.map(\.model) == ["b", "a"])
    }

    @Test func retreatsCountSentencesTheServiceGaveUpOn() {
        let d = diag()
        d.record(sentence("them", via: "zenmux"))
        d.record(sentence("them", via: "google", fallbacks: ["zenmux:rateLimited"]))
        d.record(sentence("them", via: "google", fallbacks: ["zenmux:timeout"]))
        d.record(sentence("them", via: "apple", fallbacks: ["google:rateLimited"]))   // Google's fallback, not the service's
        #expect(d.retreats.map(\.0) == ["google"])
        #expect(d.retreats.first?.1 == 2)
    }

    @Test func speakBackCountsToTheFirstSound() {
        let d = diag()
        d.record(sentence("me", via: "zenmux", recognize: 0.5, translate: 1, firstAudio: 0.9))
        d.record(sentence("me", via: "ming", recognize: 2, translate: 0, firstAudio: 1))
        #expect(d.toRoom?.n == 2)
        // recognize + translate + first sound: 0.5 + 1 + 0.9 and 2 + 0 + 1.
        #expect(abs((d.toRoom?.p95 ?? 0) - 3) < 0.001)
        // Ming hears it on the service: not recognized on this Mac.
        #expect(d.recognizeMine?.n == 1)
    }

    @Test func draftsAreCountedNotTimedWhenTheyFail() {
        let d = diag()
        d.recordDraft(seconds: 0.3, ok: true)
        d.recordDraft(seconds: 0.5, ok: true)
        d.recordDraft(seconds: 8, ok: false)
        #expect(d.drafts.n == 3 && d.drafts.failed == 1)
        #expect(d.draftStat?.n == 2)
        d.begin()
        #expect(d.drafts.n == 0)
    }

    @Test func nothingIsKeptWhileOff() {
        let d = Diagnostics()
        d.recordDraft(seconds: 1, ok: true)
        d.record(call("translate", 1))
        #expect(d.drafts.n == 0 && d.calls.isEmpty)
    }

    @Test func reportNamesTheServiceAndFullModel() {
        let d = diag()
        d.record(call("translate", 1.2))
        d.recordDraft(seconds: 0.3, ok: true)
        let config = AIConfig(provider: .zenmux, base: AIProvider.zenmux.base, textModel: "inclusionai/ling-3.0-flash")
        let text = d.report(version: "9.9.9", service: config)
        #expect(text.contains("AI: zenmux · inclusionai/ling-3.0-flash"))
        #expect(text.contains("translate zenmux inclusionai/ling-3.0-flash p50 1.20s"))
        #expect(text.contains("draft google"))
    }

    @Test func pageShortensTheModel() {
        #expect(DiagnosticsView.short("inclusionai/ling-3.0-flash") == "ling-3.0-flash")
        #expect(DiagnosticsView.short("Ling-3.1-flash") == "Ling-3.1-flash")
    }
}
