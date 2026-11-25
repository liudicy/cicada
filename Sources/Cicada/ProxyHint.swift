import CFNetwork
import Foundation
import Network

/// Words the "can't reach the AI service" hint. Read-only on purpose: the app never sets or uses a
/// proxy of its own (URLSession already goes through the system proxy); it only tells the user
/// which of three situations they are in, so the hint says what to do.
enum ProxyProbe {
    /// Ports common proxy apps listen on (Clash 7890, Clash Verge 7897, SOCKS 1080).
    static let ports = [7890, 7897, 1080]

    static func hint() async -> AICheck.ProxyHint {
        if systemProxyOn() { return .systemOn }
        for port in ports where await listening(port) { return .appRunning(port: port) }
        return .none
    }

    /// An HTTPS, SOCKS or auto-config (PAC) proxy in System Settings › Network.
    static func systemProxyOn() -> Bool {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        func on(_ key: CFString) -> Bool { (s[key as String] as? Int ?? 0) == 1 }
        return on(kCFNetworkProxiesHTTPSEnable) || on(kCFNetworkProxiesSOCKSEnable) || on(kCFNetworkProxiesProxyAutoConfigEnable)
    }

    /// Something accepts a TCP connection on 127.0.0.1:`port` within 0.3 s. Nothing is sent.
    static func listening(_ port: Int) async -> Bool {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let conn = NWConnection(host: "127.0.0.1", port: p, using: .tcp)
        return await withCheckedContinuation { cont in
            let once = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { conn.cancel(); cont.resume(returning: true) }
                case .failed, .waiting: if once.take() { conn.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if once.take() { conn.cancel(); cont.resume(returning: false) }
            }
        }
    }

    /// Resumes a continuation exactly once across the connection's callbacks and the timeout.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// The website's proxy help, in the UI language.
    static var helpURL: URL {
        let lang = Bundle.main.preferredLocalizations.first ?? "zh"
        let prefix = ["en", "ja", "ko"].first { lang.hasPrefix($0) }.map { "/\($0)" } ?? ""
        return URL(string: "https://cicada.indaloop.app\(prefix)/start/#proxy")!
    }
}
