import Foundation

// lsctl [--json] [--timeout <s>] <command>          send one debug command, wait for its reply
// lsctl [--timeout <s>] --wait '<path> <op> <value>'  poll `state` until it holds, e.g. 'display.notesWindow.visible == true'
// lsctl --no-reply <command>                          fire and forget, as lsctl always did
//
// Exit: 0 done, 1 the command failed, 2 no reply (app not running, debug control off, old build),
// 3 unknown command, 64 bad usage. stdout: `data` as JSON; stderr: the command's log lines and errors.

var args = Array(CommandLine.arguments.dropFirst())
var json = false, noReply = false, timeout: Double?, waitExpr: String?
while let a = args.first, a.hasPrefix("--") {
    args.removeFirst()
    switch a {
    case "--json": json = true
    case "--no-reply": noReply = true
    case "--timeout": timeout = Double(args.isEmpty ? "" : args.removeFirst())
    case "--wait": waitExpr = args.isEmpty ? nil : args.removeFirst(); if waitExpr == nil { exit(64) }
    default: FileHandle.standardError.write("lsctl: unknown option \(a)\n".data(using: .utf8)!); exit(64)
    }
}
let cmd = args.joined(separator: " ")
// One reply comes in well under a second; a condition may take a while (a model to load, a window).
let limit = timeout ?? (waitExpr == nil ? 3 : 10)
if cmd.isEmpty && waitExpr == nil { FileHandle.standardError.write("usage: lsctl [--json] [--timeout s] [--wait expr] <command>\n".data(using: .utf8)!); exit(64) }

// CICADA_DEBUG_CHANNEL picks one running copy (see DevBuild.debugChannel).
let channel = ProcessInfo.processInfo.environment["CICADA_DEBUG_CHANNEL"].map { $0.isEmpty ? "" : "." + $0 } ?? ""
let name = "com.wquguru.cicada.debug" + channel
let center = DistributedNotificationCenter.default()

var replies: [String: [String: Any]] = [:]
let observer = center.addObserver(forName: Notification.Name(name + ".reply"), object: nil, queue: nil) { note in
    guard let s = note.object as? String, let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["id"] as? String else { return }
    replies[id] = o
}

/// Sends one command and runs the run loop until its reply comes, or nil after `limit` seconds.
func send(_ cmd: String, limit: Double) -> [String: Any]? {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    center.postNotificationName(Notification.Name(name), object: cmd, userInfo: ["id": id], deliverImmediately: true)
    let end = Date().addingTimeInterval(limit)
    while replies[id] == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return replies.removeValue(forKey: id)
}

func jsonText(_ v: Any) -> String {
    if let s = v as? String { return s }
    guard JSONSerialization.isValidJSONObject(["v": v]),
          let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "\(v)" }
    return String(decoding: d, as: UTF8.self)
}

func exitCode(_ r: [String: Any]) -> Int32 {
    if r["ok"] as? Bool == true { return 0 }
    return (r["error"] as? [String: Any])?["code"] as? String == "unknown_command" ? 3 : 1
}

/// `notes.state == idle`, `display.notesWindow.visible == true`, `room.voicedSeconds > 2`.
func holds(_ expr: String, in state: [String: Any]) -> Bool {
    let ops = ["==", "!=", ">=", "<=", ">", "<"]
    guard let op = ops.first(where: { expr.contains($0) }) else { return false }
    let sides = expr.components(separatedBy: op).map { $0.trimmingCharacters(in: .whitespaces) }
    guard sides.count == 2 else { return false }
    var v: Any? = state
    for k in sides[0].split(separator: ".") { v = (v as? [String: Any])?[String(k)] }
    guard let v else { return false }
    let want = sides[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let w = Double(want) {
        let x = n.doubleValue
        switch op { case "==": return x == w; case "!=": return x != w; case ">": return x > w
        case "<": return x < w; case ">=": return x >= w; default: return x <= w }
    }
    let s = (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0.boolValue ? "true" : "false") : $0.stringValue }
        ?? (v as? String) ?? jsonText(v)
    switch op { case "==": return s == want; case "!=": return s != want; default: return false }
}

if noReply {
    center.postNotificationName(Notification.Name(name), object: cmd, userInfo: nil, deliverImmediately: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    exit(0)
}

if !cmd.isEmpty {
    guard let r = send(cmd, limit: limit) else {
        FileHandle.standardError.write("lsctl: no reply in \(limit) s (is the app running with debug control on? channel \(name))\n".data(using: .utf8)!)
        exit(2)
    }
    if json { print(jsonText(r)) } else {
        // stdout is only `data`, so `lsctl state | jq` works; what the command logged goes to stderr.
        for l in r["log"] as? [String] ?? [] { FileHandle.standardError.write((l + "\n").data(using: .utf8)!) }
        if let d = r["data"] { print(jsonText(d)) }
        if let e = r["error"] as? [String: Any] { FileHandle.standardError.write("lsctl: \(e["code"] ?? "") \(e["message"] ?? "")\n".data(using: .utf8)!) }
    }
    if exitCode(r) != 0 || waitExpr == nil { exit(exitCode(r)) }
}

if let waitExpr {
    // A wait is its own budget: --timeout is how long the condition may take, not one reply.
    // The section is the path up to its first dot, space or operator (`problem == x` is top level).
    let section = String(waitExpr.trimmingCharacters(in: .whitespaces).prefix { $0 != "." && $0 != " " && !"=!<>".contains($0) })
    let end = Date().addingTimeInterval(limit)
    var last: [String: Any]?
    repeat {
        if let r = send("state:\(section)", limit: min(2, max(0.1, end.timeIntervalSinceNow))) {
            if r["ok"] as? Bool != true { FileHandle.standardError.write("lsctl: \(jsonText(r["error"] ?? ""))\n".data(using: .utf8)!); exit(64) }
            last = r["data"] as? [String: Any]
            if let last, holds(waitExpr, in: last) { exit(0) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    } while Date() < end
    var v: Any? = last
    for k in waitExpr.split(whereSeparator: { " =!<>".contains($0) }).first?.split(separator: ".") ?? [] { v = (v as? [String: Any])?[String(k)] }
    FileHandle.standardError.write("lsctl: still not \(waitExpr) after \(limit) s (now \(last == nil ? "no reply" : jsonText(v ?? "missing")))\n".data(using: .utf8)!)
    exit(2)
}
_ = observer
