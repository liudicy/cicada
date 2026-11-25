import Foundation
import Testing
@testable import Cicada

@Suite struct SpeakerTests {
    /// 1 s of two tones plus a deterministic ripple; reference values from
    /// torchaudio.compliance.kaldi.fbank(x * 32768, num_mel_bins=80, dither=0).
    private var signal: [Float] {
        (0..<16000).map { n in
            let t = Double(n) / 16000
            return Float(0.3 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 1234 * t)
                         + 0.05 * (Double((n * 7919) % 1000) / 1000 - 0.5))
        }
    }

    @Test func fbankMatchesKaldi() {
        let f = Fbank.compute(signal)
        #expect(f.count == 98 * 80)
        let expected: [(frame: Int, bins: [Float])] = [(0, [14.668, 16.6069, 12.7853, 20.1031]),
                                                       (97, [13.7549, 16.6393, 14.6429, 20.1246])]
        for e in expected {
            for (b, v) in zip([0, 10, 40, 79], e.bins) {
                #expect(abs(f[e.frame * 80 + b] - v) < 0.01, "frame \(e.frame) bin \(b): \(f[e.frame * 80 + b]) vs \(v)")
            }
        }
        #expect(abs(f.reduce(0, +) / Float(f.count) - 16.1517) < 0.01)
    }

    private func unit(_ i: Int, noise: Float = 0) -> [Float] {
        var v = [Float](repeating: noise, count: 256)
        v[i] = 1
        let n = v.map { $0 * $0 }.reduce(0, +).squareRoot()
        return v.map { $0 / n }
    }

    @Test func clustererJoinsStartsAndAbstains() {
        var c = VoiceClusterer()
        #expect(c.label(unit(0), seconds: 3) == 0)
        #expect(c.label(unit(0, noise: 0.02), seconds: 1) == 0)   // similar: joins
        #expect(c.label(unit(1), seconds: 1) == nil)              // new voice, too short to start one
        #expect(c.label(unit(1), seconds: 2.5) == 1)              // long enough: a new voice
        #expect(c.sums.count == 2)
    }

    private func line(_ id: Int, _ voice: Int?, me: Bool = false) -> TranscriptLine {
        TranscriptLine(id: "l\(id)", t: Double(id), speaker: me ? "me" : "them", src: "a full line", dst: nil,
                       srcLang: "en", dstLang: "zh-CN", voice: voice)
    }

    @Test func oneOtherVoiceStaysUnnamed() {
        let lines = (0..<12).map { line($0, 7) } + (12..<16).map { line($0, nil, me: true) }
        #expect(SpeakerLabels.numbers(lines).isEmpty)
    }

    @Test func voicesNamedOnceTwoHaveEnoughLines() {
        // Voice 9 speaks first, then 4; voice 2 has only four lines and stays 对方.
        var lines = (0..<5).map { line($0, 9) } + (5..<10).map { line($0, 4) } + (10..<14).map { line($0, 2) }
        lines.append(line(14, nil))
        let n = SpeakerLabels.numbers(lines)
        #expect(n["l0"] == 1 && n["l4"] == 1)
        #expect(n["l5"] == 2)
        #expect(n["l10"] == nil && n["l14"] == nil)
        #expect(SpeakerLabels.shownCount(lines) == 2)
        // A voice that spoke first but reached five lines later doesn't take an earlier number.
        let late = [line(0, 3)] + (1..<6).map { line($0, 9) } + (6..<11).map { line($0, 4) } + (11..<15).map { line($0, 3) }
        let m = SpeakerLabels.numbers(late)
        #expect(m["l1"] == 1 && m["l6"] == 2 && m["l0"] == 3)
        // Four lines of voice 4 are not enough yet.
        #expect(SpeakerLabels.numbers(Array(lines.prefix(9))).isEmpty)
    }

    @Test func exportNamesFollowNumbers() {
        let l = line(3, 1)
        #expect(TranscriptExport.speakerName(l, ["l3": 2]) == L("说话人 2"))
        #expect(TranscriptExport.speakerName(l) == L("对方"))
        #expect(TranscriptExport.speakerName(line(4, nil, me: true), ["l4": 1]) == L("你 · 同传"))
    }

    /// An imported file names nobody ("对方" means nothing there) until its voices are told apart.
    @Test func importedFilesNameSpeakersOnceTold() {
        var s = Session(id: "i", title: "t", startedAt: Date(), endedAt: nil, lines: [line(0, 1)], hasAudio: false)
        s.sourceFile = "call.m4a"
        #expect(!TranscriptExport.saysWho(s, [:]))
        #expect(TranscriptExport.saysWho(s, ["l0": 1]))
        s.sourceFile = nil
        #expect(TranscriptExport.saysWho(s, [:]))
    }

    private func named(_ voiceNames: [String: String]?) -> Session {
        let lines = (0..<5).map { line($0, 9) } + (5..<10).map { line($0, 4) } + [line(10, nil, me: true)]
        return Session(id: "s", title: "t", startedAt: Date(), endedAt: nil, lines: lines, hasAudio: false,
                       notes: nil, renamed: nil, voiceNames: voiceNames)
    }

    @Test func namesFollowVoicesNotNumbers() {
        let s = named(["4": "George", "7": "Nobody"])
        #expect(SpeakerLabels.names(s) == [2: "George"])
        #expect(SpeakerLabels.label(2, SpeakerLabels.names(s)) == "George")
        #expect(SpeakerLabels.label(1, SpeakerLabels.names(s)) == L("说话人 1"))
        #expect(TranscriptExport.speakerName(s.lines[5], SpeakerLabels.numbers(s.lines), SpeakerLabels.names(s)) == "George")
        #expect(SpeakerLabels.names(named(nil)).isEmpty)
    }

    @Test func nameGuessPromptAndParse() {
        let s = named(nil)
        let content = SpeakerNameGuess.content(s) ?? ""
        #expect(content.contains("[L1 00:00 说话人1] a full line"))
        #expect(content.contains("[L6 00:05 说话人2] a full line"))
        #expect(content.contains("[L11 00:10 你] a full line"))
        let reply = #"{"speakers": [{"speaker": 2, "name": " George ", "evidence": "L6"}, {"speaker": 7, "name": "X"}, {"speaker": 1, "name": ""}]}"#
        let g = SpeakerNameGuess.parse(reply, s)
        #expect(g == [4: VoiceGuess(name: "George", evidence: "00:05 “a full line”")])
        // One name for two voices: the one with more lines keeps it.
        var more = s
        more.lines += (11..<14).map { line($0, 4) }
        #expect(SpeakerNameGuess.parse(#"{"speakers": [{"speaker": 1, "name": "Ann", "evidence": "L1"}, {"speaker": 2, "name": "Ann", "evidence": "L6"}]}"#, more).keys.sorted() == [4])
        #expect(SpeakerNameGuess.parse("not json", s).isEmpty)
        // One voice on show: nothing to ask.
        #expect(SpeakerNameGuess.content(Session(id: "s", title: "t", startedAt: Date(), endedAt: nil,
                                                 lines: (0..<6).map { line($0, 1) }, hasAudio: false, notes: nil, renamed: nil)) == nil)
    }

    /// The end of session 20261103-000911 (Bloomberg TV): voice 0 is the guest, voice 1 the anchor,
    /// then an advert break with other voices.
    private var bloomberg: Session {
        let rows: [(Int?, String)] = [
            (0, "We have to invest in alternative routes to the Strait of Hormuz."), (0, "That is something that financial markets are not used to doing."),
            (1, "Let's talk about financing a little bit."), (1, "I was watching you speak yesterday as well in an interview."),
            (1, "It is still important, and you see the need to still come here."), (1, "lucrative investment opportunities, whether it's in the UAE."),
            (0, "Yes, I think that what we're going to see is a big investment in infrastructure."), (0, "We need to invest in these infrastructure routes to harden them."),
            (0, "And I think the question will be, how do we invest in them?"), (0, "We saw that in the '70s."), (0, "I think we're going to see it again."),
            (1, "Okay, Amos, thank you so much for your time this morning, Amos Hockstein, managing partner."),
            (nil, ".."), (1, "And now, coming up, we will be discussing the outlook for oil markets."), (1, "That is next live from Adipec here in Abu Dhabi."),
            (nil, "This is Bloomberg."), (2, "It's a multi trillion dollar industry."), (3, "Welcome to Bloomer this weekend."),
            (nil, "I'm David Brewer."), (nil, "I'm Lisa Mattay."), (nil, "I'm Christina Raffini."),
            (4, "We're tracking breaking news today from Wall Street to Washington."),
        ]
        let lines = rows.enumerated().map { i, r in
            TranscriptLine(id: "l\(i)", t: Double(i), speaker: "them", src: r.1, dst: nil, srcLang: "en", dstLang: "zh-CN", voice: r.0)
        }
        return Session(id: "s", title: "t", startedAt: Date(), endedAt: nil, lines: lines, hasAudio: false, notes: nil, renamed: nil)
    }

    @Test func aNameNeedsItsSpeakerNearTheEvidence() {
        let s = bloomberg
        #expect(SpeakerLabels.voiceNumbers(s.lines) == [0: 1, 1: 2])
        // Amos (voice 0, 说话人1) is thanked on L12, right after his own L10 and L11: kept.
        // "I'm Christina Raffini." (L21) is an advert, voice 1 last spoke on L15: dropped.
        let reply = #"{"speakers": [{"speaker": 1, "name": "Amos Hochstein", "evidence": "L12"}, {"speaker": 2, "name": "Christina Raffini", "evidence": "L21"}]}"#
        let r = SpeakerNameGuess.read(reply, s)
        #expect(r.found.keys.sorted() == [0] && r.found[0]?.name == "Amos Hochstein")
        #expect(r.found[0]?.evidence.hasPrefix("00:11 “Okay, Amos") == true)
        #expect(r.refuted == [1: "Christina Raffini"])
        // Asked again without JSON mode, the same reply may come in a fence.
        #expect(SpeakerNameGuess.read("```json\n" + reply + "\n```", s).found[0]?.name == "Amos Hochstein")
        // Said by the speaker themselves; "L12, L13" reads as L12; no evidence, or one out of range, is no name.
        #expect(SpeakerNameGuess.parse(#"{"speakers": [{"speaker": 2, "name": "Anchor", "evidence": "L12, L14"}]}"#, s)[1]?.name == "Anchor")
        #expect(SpeakerNameGuess.parse(#"{"speakers": [{"speaker": 2, "name": "Anchor"}]}"#, s).isEmpty)
        #expect(SpeakerNameGuess.parse(#"{"speakers": [{"speaker": 2, "name": "Anchor", "evidence": "L99"}]}"#, s).isEmpty)
        // Two lines away still counts; three doesn't.
        #expect(SpeakerNameGuess.parse(#"{"speakers": [{"speaker": 1, "name": "Amos", "evidence": "L13"}]}"#, s)[0] != nil)
        #expect(SpeakerNameGuess.parse(#"{"speakers": [{"speaker": 1, "name": "Amos", "evidence": "L14"}]}"#, s).isEmpty)
        #expect(SpeakerNameGuess.instruction.contains("misspells"))
        // A guess stored before the check is tested again from its quoted line.
        #expect(!SpeakerNameGuess.holds(VoiceGuess(name: "Christina Raffini", evidence: "00:20 “I'm Christina Raffini.”"), voice: 1, in: s))
        #expect(SpeakerNameGuess.holds(VoiceGuess(name: "Amos", evidence: "00:11 “Okay, Amos, thank you so much for your time this morning, Amos…”"), voice: 0, in: s))
        #expect(SpeakerNameGuess.holds(VoiceGuess(name: "Ann", evidence: "09:59 “Not in this meeting”"), voice: 1, in: s))
    }

    @Test func guessesShowUntilTheUserSaysOtherwise() {
        var s = named(nil)
        s.voiceGuesses = ["9": VoiceGuess(name: "Emma", evidence: ""), "4": VoiceGuess(name: "George", evidence: "")]
        #expect(SpeakerLabels.names(s) == [1: "Emma", 2: "George"])
        #expect(SpeakerLabels.guessed(s).keys.sorted() == [1, 2])
        s.voiceNames = ["9": "Emily", "4": ""]          // corrected, and turned down
        #expect(SpeakerLabels.names(s) == [1: "Emily"])
        #expect(SpeakerLabels.guessed(s).isEmpty)
    }

    @Test func shortLinesDontEarnAName() {
        #expect(SpeakerLabels.substantive("I can take it"))
        #expect(!SpeakerLabels.substantive("Yeah, sure."))
        #expect(!SpeakerLabels.substantive("."))
        #expect(SpeakerLabels.substantive("我们周四上线"))
        #expect(!SpeakerLabels.substantive("好的"))
    }

    @Test func namesOnlyWhereTheSpeakerChanges() {
        let lines = [line(0, 9), line(1, 9), line(2, 4), line(3, nil), line(4, nil), line(5, 9), line(6, nil, me: true), line(7, nil, me: true)]
        let starts = SpeakerLabels.runStarts(lines, ["l0": 1, "l1": 1, "l2": 2, "l5": 1])
        #expect(starts == ["l0", "l2", "l3", "l5", "l6"])
        #expect(TranscriptExport.speakerName(lines[3], ["l0": 1]) == L("未识别"))
        #expect(TranscriptExport.speakerName(lines[3]) == L("对方"))
    }

    @Test func clustererMergeSendsLaterLinesToTarget() {
        var c = VoiceClusterer()
        #expect(c.label(unit(0), seconds: 3) == 0)
        #expect(c.label(unit(1), seconds: 3) == 1)
        c.merge(1, into: 0)
        #expect(c.label(unit(1), seconds: 1) == 0)
    }
}
