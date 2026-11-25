import Foundation
import Testing
@testable import Cicada

@Suite struct DebugReplyTests {
    private func decode(_ r: DebugReply) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(r.json().utf8))) as? [String: Any] ?? [:]
    }

    @Test func successCarriesDataAndLog() {
        var r = DebugReply(id: "a1")
        r.data = ["listen": ["running": true]]
        r.log = ["debug command: state"]
        let o = decode(r)
        #expect(o["id"] as? String == "a1")
        #expect(o["ok"] as? Bool == true)
        #expect(o["error"] == nil)
        #expect(((o["data"] as? [String: Any])?["listen"] as? [String: Any])?["running"] as? Bool == true)
        #expect(o["log"] as? [String] == ["debug command: state"])
    }

    @Test func failureHasACode() {
        var r = DebugReply(id: "b2")
        r.ok = false
        r.error = ("unknown_command", "unknown debug command: x")
        let o = decode(r)
        #expect(o["ok"] as? Bool == false)
        #expect((o["error"] as? [String: Any])?["code"] as? String == "unknown_command")
    }

    @Test func dataThatIsNotJSONIsDroppedNotFatal() {
        var r = DebugReply(id: "c3")
        r.data = ["when": Date()]
        let o = decode(r)
        #expect(o["id"] as? String == "c3")
        #expect(o["data"] == nil)
    }

    @Test func longLogKeepsTheNewestLinesWithinTheLimit() {
        var r = DebugReply(id: "d4")
        r.log = (0..<1000).map { "line \($0) " + String(repeating: "x", count: 200) }
        let log = decode(r)["log"] as? [String] ?? []
        #expect(log.count <= DebugReply.maxLogLines)
        #expect(log.reduce(0) { $0 + $1.utf8.count } <= DebugReply.maxLogBytes)
        #expect(log.last?.hasPrefix("line 999 ") == true)
    }
}
