import Foundation
import Testing
@testable import LiveSubs

struct AIProviderTests {
    private func shaped(_ p: AIProvider) -> [String: Any] {
        var body: [String: Any] = [:]
        AIConfig(provider: p, base: p.base, textModel: "m").shape(&body, maxTokens: 50)
        return body
    }

    @Test func eachServiceTurnsThinkingOffItsOwnWay() {
        #expect((shaped(.ling)["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((shaped(.zenmux)["reasoning"] as? [String: Bool])?["enabled"] == false)
        #expect((shaped(.openrouter)["reasoning"] as? [String: Bool])?["enabled"] == false)
        let openai = shaped(.openai)
        #expect(openai["reasoning_effort"] as? String == "none")
        #expect(openai["max_completion_tokens"] as? Int == 50)
        #expect(openai["max_tokens"] == nil && openai["temperature"] == nil)
        let custom = shaped(.custom)
        #expect(custom["max_tokens"] as? Int == 50 && custom["thinking"] == nil && custom["reasoning"] == nil)
    }

    @Test func customAddressNeedsHTTPSExceptOnThisMac() {
        #expect(AIProvider.customBase("https://api.example.com/v1")?.absoluteString == "https://api.example.com/v1/")
        #expect(AIProvider.customBase("api.example.com/v1")?.scheme == "https")
        #expect(AIProvider.customBase("http://localhost:11434/v1")?.absoluteString == "http://localhost:11434/v1/")
        #expect(AIProvider.customBase("localhost:1234/v1")?.scheme == "http")
        #expect(AIProvider.customBase("http://api.example.com/v1") == nil)
        #expect(AIProvider.customBase("  ") == nil)
    }

    @Test func onlyLingClonesAndHearsAudio() {
        for p in AIProvider.all { #expect(p.clones == (p.id == .ling) && p.hearsAudio == (p.id == .ling)) }
        #expect(!AIProvider.openai.hasVoices && AIProvider.zenmux.hasVoices && AIProvider.openrouter.hasVoices)
    }

    @Test func wavHeaderIsStripped() {
        var wav = Data("RIFF".utf8) + Data([36, 0, 0, 0]) + Data("WAVE".utf8)
        wav += Data("fmt ".utf8) + Data([16, 0, 0, 0]) + Data(repeating: 0, count: 16)
        wav += Data("data".utf8) + Data([4, 0, 0, 0]) + Data([1, 2, 3, 4])
        #expect(LingClient.pcm(fromWAV: wav) == Data([1, 2, 3, 4]))
        #expect(LingClient.pcm(fromWAV: Data([9, 9])) == Data([9, 9]))
    }

    @Test func catalogKeepsTextModelsRecommendedFirst() throws {
        let json = """
        {"data":[{"id":"z/chat","output_modalities":["text"]},{"id":"g/tts","output_modalities":["speech"]},
        {"id":"a/chat","architecture":{"output_modalities":["text"]}},{"id":"g/flash:batch"},{"id":"text-embedding-3-small"},
        {"id":"qwen3:14b"},{"id":"rec/one"}]}
        """
        let ids = AIConfig.textModels(fromCatalog: Data(json.utf8), recommended: ["rec/one"])
        #expect(ids == ["rec/one", "a/chat", "qwen3:14b", "z/chat"])
    }
}
