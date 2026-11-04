import Foundation
import Testing
@testable import LiveSubs

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

    @Test func providerBaseURLGetsATrailingSlash() {
        #expect(AIProvider(id: "x", name: "X", baseURL: "https://a.example/v1", model: "m").base
            == URL(string: "https://a.example/v1/"))
        #expect(AIProvider(id: "x", name: "X", baseURL: "https://a.example/v1/", model: "m").base
            == URL(string: "https://a.example/v1/"))
        #expect(AIProvider.ling.isLing)
        #expect(AIProvider.ling.base == URL(string: "https://api.ant-ling.com/v1/"))
    }
}
