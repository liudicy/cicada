import Foundation
import Testing
@testable import Cicada

struct AICheckTests {
    @Test func eachFailureStopsAtItsStep() {
        #expect(AICheck.classify(.network, at: .text)! == (.reach, .unreachable, nil))
        #expect(AICheck.classify(.timeout, at: .key)! == (.reach, .unreachable, nil))
        #expect(AICheck.classify(.invalidKey, at: .text)! == (.key, .invalidKey, nil))
        #expect(AICheck.classify(.http(402), at: .text)! == (.key, .noCredit, 402))
        #expect(AICheck.classify(.http(404), at: .text)! == (.text, .noModel, 404))
        #expect(AICheck.classify(.http(400), at: .text)! == (.text, .noModel, 400))
        #expect(AICheck.classify(.rateLimited, at: .text)! == (.text, .busy, nil))
        #expect(AICheck.classify(.http(503), at: .key)! == (.key, .serverError, 503))
        #expect(AICheck.classify(.hijacked, at: .text) == nil)
    }

    @Test func aFailedStepSkipsTheRestAndAReplyProvesTheOnesBefore() {
        var c = AICheck()
        c.fail(.key, .invalidKey)
        #expect(c[.reach] == .ok(seconds: nil))
        #expect(c[.key] == .fail(.invalidKey, code: nil))
        #expect(c[.text] == .skipped)
        #expect(c.failure?.step == .key)

        var m = AICheck()
        m.fail(.key, .mgmtKey, reached: false)
        #expect(m[.reach] == .untested)
    }

    @Test func aSuccessClearsAnEarlierFailure() {
        var c = AICheck()
        c.fail(.reach, .unreachable)
        c.proxy = AICheck.ProxyHint.none
        c.pass(upTo: .text, seconds: 1.5)
        #expect(c.failure == nil)
        #expect(c[.reach] == .ok(seconds: nil) && c[.text] == .ok(seconds: 1.5))
        #expect(c.proxy == nil)

        // A key-info request proves reach and key; the text model stays open.
        var k = AICheck()
        k.fail(.reach, .unreachable)
        k.pass(upTo: .key, seconds: 0.3)
        #expect(k[.text] == .untested)
    }

    @Test func busyPassesAndNeedsNobody() {
        var c = AICheck()
        c.pass(upTo: .text, seconds: nil)
        c[.text] = .busy
        c.at = Date()
        #expect(c.passed && c.busy && !c.needsUser)
    }

    @Test func keyPrefixesTellWhoseKeyItIs() {
        #expect(AICheck.owner(ofKey: "sk-or-v1-abc")! == (.openrouter, false))
        #expect(AICheck.owner(ofKey: " sk-payg-abc\n")! == (.zenmux, false))
        #expect(AICheck.owner(ofKey: "sk-mgmt-abc")! == (.zenmux, true))
        #expect(AICheck.owner(ofKey: "sk-abc") == nil)
    }

    @Test func balanceIsTheSmallerOfKeyLimitAndCredits() {
        let key: [String: Any] = ["data": ["limit_remaining": 1.72]]
        let credits: [String: Any] = ["data": ["total_credits": 10.0, "total_usage": 3.92]]
        #expect(AICheck.balance(key: key, credits: credits) == 1.72)
        #expect(abs(AICheck.balance(key: ["data": ["limit_remaining": NSNull()]], credits: credits)! - 6.08) < 0.001)
        #expect(AICheck.balance(key: key, credits: nil) == 1.72)
        #expect(AICheck.balance(key: nil, credits: nil) == nil)
        var c = AICheck()
        c.balance = 0.3
        #expect(c.lowBalance && c.needsUser)
    }

    @Test func listedModelsReadsEveryID() {
        let data = Data(#"{"data":[{"id":"inclusionai/ling-3.0-flash"},{"id":"qwen/qwen3.8-flash"}]}"#.utf8)
        #expect(AICheck.listedModels(data) == ["inclusionai/ling-3.0-flash", "qwen/qwen3.8-flash"])
        #expect(AICheck.listedModels(Data("{}".utf8)) == nil)
        #expect(AICheck.listedModels(Data(#"{"data":[]}"#.utf8)) == nil)
    }

    @Test func messagesNameTheServiceAndTheProxyHintFollowsTheProxy() {
        var c = AICheck()
        c.fail(.reach, .unreachable)
        #expect(c.message(service: "ZenMux", host: "zenmux.ai", model: "m")?.contains("zenmux.ai") == true)
        #expect(c.proxyLine(service: "ZenMux", host: "zenmux.ai") == nil)
        c.proxy = .appRunning(port: 7890)
        #expect(c.proxyLine(service: "ZenMux", host: "zenmux.ai")?.contains("7890") == true)
        c.proxy = .systemOn
        #expect(c.proxyLine(service: "ZenMux", host: "zenmux.ai")?.contains("zenmux.ai") == true)
        var m = AICheck()
        m.fail(.text, .noModel, code: 404)
        #expect(m.message(service: "ZenMux", host: "zenmux.ai", model: "x/y")?.contains("x/y") == true)
    }

    @Test func theLocalNetworkPermissionIsItsOwnFixAndClearsOnTheNextResult() {
        var c = AICheck()
        c.fail(.reach, .unreachable)
        c.localNetworkDenied = true
        #expect(c.needsLocalNetwork)
        #expect(c.message(service: "s", host: "192.168.1.20", model: "m") == "知了没有本地网络权限，连不上 192.168.1.20。")
        #expect(c.proxyLine(service: "s", host: "192.168.1.20") == nil)
        c.pass(upTo: .text, seconds: 1)
        #expect(!c.localNetworkDenied && !c.needsLocalNetwork)
        c.fail(.reach, .unreachable)
        c.localNetworkDenied = true
        c.fail(.text, .noModel)
        #expect(!c.localNetworkDenied)
        var h = AICheck()
        h.hear = .localNetworkDenied
        #expect(h.needsLocalNetwork)
        #expect(h.hearLine(host: "192.168.1.20", model: "m")?.contains("本地网络") == true)
    }
}
