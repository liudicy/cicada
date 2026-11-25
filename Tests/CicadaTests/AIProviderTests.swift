import Foundation
import Testing
@testable import Cicada

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
        // Qwen3 on vLLM / SGLang / llama.cpp: thinking off through the chat template.
        #expect((custom["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
        var plain: [String: Any] = [:]
        AIConfig(provider: .custom, base: nil, textModel: "m").shape(&plain, maxTokens: 50, templateKwargs: false)
        #expect(plain["chat_template_kwargs"] == nil)
    }

    @Test func aThinkingModelIsSeenFromItsReply() {
        func reply(_ message: [String: Any], usage: [String: Any]? = nil) -> [String: Any] {
            var r: [String: Any] = ["choices": [["message": message]]]
            if let usage { r["usage"] = usage }
            return r
        }
        #expect(!AIConfig.thought(reply(["content": "周五发布。"])))
        #expect(AIConfig.thought(reply(["content": "周五发布。", "reasoning_content": "The user wants…"])))
        // A reasoning parser on the server: the answer itself sits in reasoning_content.
        #expect(AIConfig.thought(reply(["content": "", "reasoning_content": "周五发布。"])))
        #expect(AIConfig.thought(reply(["content": "<think>hmm</think>周五发布。"])))
        #expect(AIConfig.thought(reply(["content": "周五发布。"], usage: ["completion_tokens_details": ["reasoning_tokens": 212]])))
        #expect(!AIConfig.thought(reply(["content": "周五发布。", "reasoning_content": "  "], usage: ["completion_tokens_details": ["reasoning_tokens": 0]])))
    }

    @Test func aSlowSentenceIsFlagged() {
        #expect(!AICheck.Speed(seconds: 0.4, thinks: false).slow)
        #expect(AICheck.Speed(seconds: 0.4, thinks: true).slow)
        #expect(AICheck.Speed(seconds: 6.4, thinks: false).slow)
    }

    @Test func customAddressNeedsHTTPSExceptOnThisMac() {
        #expect(AIProvider.customBase("https://api.example.com/v1")?.absoluteString == "https://api.example.com/v1/")
        #expect(AIProvider.customBase("api.example.com/v1")?.scheme == "https")
        #expect(AIProvider.customBase("http://localhost:11434/v1")?.absoluteString == "http://localhost:11434/v1/")
        #expect(AIProvider.customBase("localhost:1234/v1")?.scheme == "http")
        #expect(AIProvider.customBase("http://api.example.com/v1") == nil)
        #expect(AIProvider.customBase("  ") == nil)
    }

    @Test func theLocalNetworkMayUsePlainHTTP() {
        for ok in ["http://192.168.1.20:8000/v1", "10.0.0.5:8000/v1", "http://172.20.1.1/v1", "http://100.101.102.103:8000/v1",
                   "http://169.254.3.4/v1", "http://gpu.local:30000/v1", "http://[fd12:3456::1]:8000/v1", "http://[::1]:8000/v1"] {
            #expect(AIProvider.customBase(ok)?.scheme == "http", "\(ok)")
        }
        for no in ["http://172.32.0.1/v1", "http://100.128.0.1/v1", "http://8.8.8.8/v1", "http://192.169.1.1/v1",
                   "http://gpu.example.com/v1", "http://10.0.0.5.evil.com/v1"] {
            #expect(AIProvider.customBase(no) == nil, "\(no)")
        }
        #expect(AIProvider.customBase("192.168.1.20:8000/v1")?.scheme == "http")
        #expect(AIProvider.isNearby("http://192.168.1.20:8000/v1/") && !AIProvider.isLocal("http://192.168.1.20:8000/v1/"))
    }

    @Test func recognitionOnTheServiceNeedsAModel() {
        let c = AIConfig(provider: .custom, base: URL(string: "http://localhost:8000/v1/"), textModel: "m",
                         hearModel: "qwen3-asr", hearBase: URL(string: "http://localhost:8002/v1/"))
        #expect(c.transcribes)
        #expect(!AIConfig(provider: .custom, base: c.base, textModel: "m").transcribes)
        #expect(!AIConfig(provider: .ling, base: c.base, textModel: "m", hearModel: "x", hearBase: c.base).transcribes)
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
