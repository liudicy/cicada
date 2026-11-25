import Foundation
import Testing
@testable import Cicada

/// The ports' hearing tests (linux/tests/test_core.py `Hearing`, segmenter tests), same cases.
struct CloudHearingTests {
    @Test func parsesMingReplies() {
        let h = CloudHearing.parse("LANG: en\nORIGINAL: Hello there.\nTRANSLATION: 你好。", target: "zh-CN", hint: nil, seconds: 0)
        #expect(h == CloudHeard(lang: "en", original: "Hello there.", translation: "你好。"))
        #expect(CloudHearing.parse("作为一个人工智能语言模型，这个问题超出我目前的学习范围了", target: "zh-CN", hint: nil, seconds: 0) == nil)
        #expect(CloudHearing.parse("LANG: en\nORIGINAL: NONE\nTRANSLATION: 无", target: "zh-CN", hint: nil, seconds: 0) == nil)
        #expect(CloudHearing.parse("LANG: en\nORIGINAL: ...\nTRANSLATION: …", target: "zh-CN", hint: nil, seconds: 0) == nil)
        let same = CloudHearing.parse("LANG: zh\nORIGINAL: 好的\nTRANSLATION: OK", target: "zh-CN", hint: "en", seconds: 0)
        #expect(same?.lang == "zh-CN" && same?.translation == "好的")
        #expect(CloudHearing.parse("LANG: en\nORIGINAL: Hi\nTRANSLATION: Hi again", target: "zh-CN", hint: nil, seconds: 0)?.translation == nil)
        #expect(CloudHearing.parse("lang: ja-JP\noriginal: はい\ntranslation: 是", target: "zh-CN", hint: nil, seconds: 0)?.lang == "ja")
    }

    /// A gateway answering 502 to every stretch is the service erring, said with its code, not
    /// "can't reach"; the network and the key keep their own words.
    @Test func saysWhyHearingStopped() {
        let erring = CloudHearing.trouble(LingClient.Failure.http(502), service: "ZenMux")
        let away = CloudHearing.trouble(LingClient.Failure.network, service: "ZenMux")
        #expect(erring.contains("ZenMux") && erring.contains("HTTP 502"))
        #expect(away.contains("ZenMux") && !away.contains("HTTP"))
        #expect(CloudHearing.trouble(LingClient.Failure.http(429), service: "ZenMux") == away)
        #expect(CloudHearing.trouble(LingClient.Failure.timeout, service: "ZenMux") == away)
        #expect(CloudHearing.trouble(LingClient.Failure.invalidKey, service: "ZenMux") == L("key 已失效，到设置 › AI 服务里重填"))
    }

    @Test func dropsNoise() {
        for o in ["嗯。", "Mm.", "uh, um", "呃呃呃呃呃", "嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯，嗯。", String(repeating: "滴答", count: 50),
                  "hmmmm", "うーん", "음…", "喂？", "No no no no no no",
                  "（无语音内容）", "[Music]", "♪♪", "这段音频是一段旋律，没有说话声。", "There is no speech in this audio."] {
            #expect(CloudHearing.isNoise(o), "\(o)")
        }
        for o in ["嗯，好的。", "OK.", "Oh no, it crashed.", "对", "对对对", "谢谢谢谢", "喂喂，能听到吗？", "No, no, no.",
                  "えーと、来週の件ですが", "あの人です", "Okay, let's move on to the quarterly numbers.", "（笑）好的"] {
            #expect(!CloudHearing.isNoise(o), "\(o)")
        }
        let spoken = "我们今天讨论一下这个季度的数字和下个季度的计划安排"
        #expect(CloudHearing.isNoise(spoken, seconds: 1))
        #expect(!CloudHearing.isNoise(spoken, seconds: 4))
        #expect([0, 8, 30].map { CloudHearing.tokens(seconds: $0) } == [800, 380, 800])
    }

    @Test func wavHeader() {
        let wav = CloudHearing.wav([1, 2, 3])
        #expect(wav.count == 50 && wav.prefix(4) == Data("RIFF".utf8))
        #expect(LingClient.pcm(fromWAV: wav).count == 6)
    }

    private func tone(_ seconds: Double, _ amp: Double = 0.3, syllables: Bool = true) -> [Int16] {
        (0..<Int(seconds * 16000)).map { i in
            let env = syllables ? 0.55 + 0.45 * sin(2 * .pi * 4 * Double(i) / 16000) : 1
            return Int16(sin(2 * .pi * 300 * Double(i) / 16000) * env * amp * 32767)
        }
    }

    private func silence(_ seconds: Double) -> [Int16] { Array(repeating: 0, count: Int(seconds * 16000)) }

    private func cut(_ parts: [Int16]...) -> [CloudSegmenter.Piece] {
        var got: [CloudSegmenter.Piece] = []
        var seg = CloudSegmenter()
        for p in parts {
            var i = 0
            while i < p.count {
                seg.feed(Array(p[i..<min(p.count, i + 1600)])) { got.append($0) }
                i += 1600
            }
        }
        seg.flush { got.append($0) }
        return got
    }

    @Test func segmentsOnPauses() {
        let got = cut(silence(0.5), tone(2.0), silence(1.0), tone(1.5), silence(1.0))
        #expect(got.count == 2)
        #expect(abs(got[0].start - 0.35) < 0.05 && abs(got[1].start - 3.35) < 0.05)
        #expect((2.1...2.4).contains(got[0].seconds))
    }

    @Test func cutsLongSpeechAtItsQuietestMoment() {
        let got = cut(tone(7.0), tone(0.3, 0.004), tone(4.0), silence(1.0))
        #expect(got.count == 2)
        #expect((6.9...7.4).contains(got[0].seconds))
        #expect(got.allSatisfy { $0.seconds <= 8 })
        #expect(abs(got[1].start - (got[0].start + got[0].seconds)) < 0.001)
    }

    @Test func ignoresClicksAndHum() {
        #expect(cut(silence(1.0), tone(0.1), silence(1.0)).isEmpty)
        #expect(cut(tone(3.0, 0.002)).isEmpty)
        #expect(cut(tone(3.0, 0.02, syllables: false), silence(1.0)).isEmpty)
        #expect(cut(tone(3.0), silence(1.0)).count == 1)
    }

    @Test func aTranscriptKeepsItsLanguageAndLeavesTranslationToText() {
        let zh = CloudHearing.transcript("这个 feature 我们下个 sprint 再做。", reported: nil, hint: "en", target: "en", seconds: 3)
        #expect(zh?.lang == "zh-CN" && zh?.translation == nil)
        let en = CloudHearing.transcript("We ship on Friday.", reported: nil, hint: "zh-CN", target: "zh-CN", seconds: 2)
        #expect(en?.lang == "en" && en?.translation == nil)
        #expect(CloudHearing.transcript("会議は金曜日です。", reported: nil, hint: nil, target: "zh-CN", seconds: 2)?.lang == "ja")
        #expect(CloudHearing.transcript("회의는 금요일입니다.", reported: nil, hint: nil, target: "zh-CN", seconds: 2)?.lang == "ko")
        #expect(CloudHearing.transcript("Hola a todos.", reported: "spanish", hint: nil, target: "zh-CN", seconds: 2)?.lang == "es")
        #expect(CloudHearing.transcript("Bonjour.", reported: "fr", hint: nil, target: "zh-CN", seconds: 2)?.lang == "fr")
        // Already in the language it's translated into: shown as it is.
        let same = CloudHearing.transcript("周五发布。", reported: "zh", hint: nil, target: "zh-CN", seconds: 2)
        #expect(same?.translation == "周五发布。")
        #expect(CloudHearing.transcript("  ", reported: nil, hint: nil, target: "en", seconds: 1) == nil)
        #expect(CloudHearing.transcript("嗯。", reported: nil, hint: nil, target: "en", seconds: 1) == nil)
    }
}
