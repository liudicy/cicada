import Foundation
import Testing
@testable import Cicada

@Suite struct CloudASRTests {
    @Test @MainActor func wavHasARiffHeaderAndMatchesTheSamples() {
        let wav = CloudASRClient.wav([0, 0.5, -0.5, 1, -1])
        #expect(wav.count == 44 + 10)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        // 16-bit little-endian samples after the 44-byte header.
        #expect(Array(wav[44..<46]) == [0x00, 0x00])
        #expect(Array(wav[46..<48]) == [0xFF, 0x3F]) // 0.5 → 16383
        #expect(Array(wav[48..<50]) == [0x01, 0xC0]) // -0.5 → -16383
        #expect(Array(wav[50..<52]) == [0xFF, 0x7F]) // 1 → 32767
        #expect(Array(wav[52..<54]) == [0x01, 0x80]) // -1 → -32767
    }

    @Test @MainActor func asrLanguageMapsLocalesToWhatMiMoKnows() {
        #expect(CloudASRClient.asrLanguage("zh-CN") == "zh")
        #expect(CloudASRClient.asrLanguage("zh-Hant-TW") == "zh")
        #expect(CloudASRClient.asrLanguage("en-US") == "en")
        #expect(CloudASRClient.asrLanguage("ja") == "auto")
        #expect(CloudASRClient.asrLanguage("auto") == "auto")
    }

    @Test @MainActor func inventedEnumerationIsDropped() {
        // The cloud sometimes hears a list marker that was never said.
        #expect(CloudASRClient.stripInventedEnumeration("10. Let's lock that in.", original: "Let's lock that in.")
            == "Let's lock that in.")
        #expect(CloudASRClient.stripInventedEnumeration("1、我们先说预算", original: "我们先说预算")
            == "我们先说预算")
        // A marker the original really has (or real numbers) stays.
        #expect(CloudASRClient.stripInventedEnumeration("3. 第三项", original: "3. 第三项") == "3. 第三项")
        #expect(CloudASRClient.stripInventedEnumeration("2026 年计划", original: "2026 年计划") == "2026 年计划")
        // Nothing useful after stripping: keep the cloud text rather than blank the line.
        #expect(CloudASRClient.stripInventedEnumeration("10. ", original: "hello") == "10. ")
    }

    @Test func stepFunASRParsesDoneAndDeltaEvents() {
        let sse = """
        event: transcript.text.delta
        data: {"type":"transcript.text.delta","delta":"你好"}

        event: transcript.text.done
        data: {"type":"transcript.text.done","text":"你好，世界。"}

        """
        #expect(LingClient.parseStepFunASR(Data(sse.utf8)) == "你好，世界。")

        let deltaOnly = """
        data: {"type":"transcript.text.delta","delta":"Hello "}
        data: {"type":"transcript.text.delta","delta":"world"}
        """
        #expect(LingClient.parseStepFunASR(Data(deltaOnly.utf8)) == "Hello world")

        let plain = #"{"text":"直接返回"}"#
        #expect(LingClient.parseStepFunASR(Data(plain.utf8)) == "直接返回")
    }

    @Test func stepFunPresetConfiguresAllCapabilities() {
        let p = AIProvider.stepfun
        #expect(p.base?.absoluteString == "https://api.stepfun.com/step_plan/v1/")
        #expect(p.hasVoices)
        #expect(!p.hasHearing)
        #expect(!p.clones)
        #expect(!p.voices.isEmpty)
        #expect(LingClient.stepFunLanguage("zh-CN") == "zh")
        #expect(LingClient.stepFunLanguage("Chinese") == "zh")
        #expect(LingClient.stepFunLanguage("English") == "en")
        #expect(LingClient.stepFunLanguage("Japanese") == "ja")
        #expect(LingClient.stepFunLanguage("de-DE") == nil)
        let cfg = AIConfig(provider: p, base: p.base, textModel: "step-3.5-flash",
                           voiceModel: "stepaudio-3-tts", voiceBase: p.base)
        #expect(cfg.hasVoices)
        #expect(!cfg.transcribes)
    }
}
