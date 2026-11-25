import Foundation
import Network

/// Tells "macOS won't let Cicada reach the local network" apart from "the server is down": both
/// fail a request the same way, but only one is fixed in System Settings. Asked only after a
/// request to a server on the local network failed, so it never brings up the permission prompt
/// for anyone who doesn't use one.
enum LocalNetworkProbe {
    /// The path to `url`'s host and port is held back because the local network permission is off.
    /// Nothing is sent; the connection is dropped as soon as the path is known, or after 2 s.
    static func denied(_ url: URL) async -> Bool {
        guard let host = url.host, !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let (denied, seen): (Bool, String) = await withCheckedContinuation { cont in
            let once = Once()
            func finish(_ seen: String) {
                guard once.take() else { return }
                let denied = conn.currentPath?.unsatisfiedReason == .localNetworkDenied
                conn.cancel()
                cont.resume(returning: (denied, seen))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting, .failed: finish("\(state)")
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish("timeout") }
        }
        debugLog("local network: \(host):\(port) denied=\(denied) (\(seen))")
        return denied
    }

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
}
