import Foundation
import Testing
@testable import Cicada

@Suite struct SpeakScoreTests {
    @Test func tokensSplitCJKByCharacterAndDropPunctuation() {
        #expect(SpeakScore.tokens("Let's finalize, the PLAN!") == ["let's", "finalize", "the", "plan"])
        #expect(SpeakScore.tokens("下周三，定下来") == ["下", "周", "三", "定", "下", "来"])
        #expect(SpeakScore.tokens("Let’s go") == ["let's", "go"])
    }

    @Test func matchIsOneForSameWordsDespiteCaseAndPunctuation() {
        #expect(SpeakScore.match(sent: "Let's finalize the plan next Wednesday.", heard: "let's finalize the plan next wednesday") == 1)
    }

    @Test func matchCountsMissingAndWrongWords() {
        let m = SpeakScore.match(sent: "one two three four", heard: "one two four")
        #expect(abs(m - 0.75) < 0.001)
        #expect(SpeakScore.match(sent: "hello there", heard: "") == 0)
        #expect(SpeakScore.match(sent: "a b", heard: "x y z w v") == 0)
    }

    @Test func signalFindsOnsetAfterDigitalSilence() {
        let rate = 1000.0
        let tone: [Float] = (0..<300).map { i in Float(sin(Double(i))) * 0.5 }
        var samples = [Float](repeating: 0, count: 500)
        samples += tone
        samples += [Float](repeating: 0, count: 200)
        let s = SpeakScore.signal(samples, rate: rate)
        #expect(s.onset == 0.5)
        #expect(abs(s.voiced - 0.3) < 0.011)
        #expect(s.clipped == 0)
        #expect(s.peakDB < 0 && s.peakDB > -7)
    }

    @Test func signalOfSilenceHasNoOnset() {
        let s = SpeakScore.signal([Float](repeating: 0, count: 4800), rate: 48_000)
        #expect(s.onset == nil)
        #expect(s.voiced == 0)
    }

    @Test func judgeParsesScoreAndIssue() {
        #expect(SpeakScore.parseJudge(#"{"score": 92, "issue": ""}"#)! == (92, ""))
        #expect(SpeakScore.parseJudge("```json\n{\"score\": \"40\", \"issue\": \"date wrong\"}\n```")! == (40, "date wrong"))
        #expect(SpeakScore.parseJudge(#"{"score": 140}"#) == nil)
        #expect(SpeakScore.parseJudge("no json") == nil)
    }
}
