import CommonCrypto
import CryptoKit
import Foundation

/// A meeting shared as a link: what the Mac keeps about it. The manage token (needed to turn the
/// link off) lives only here, in a 0600 file under Application Support (Shares/<record id>.json),
/// never in the record, exports or logs; so does the password, so it can be copied again.
struct ShareRecord: Codable, Equatable {
    var id: String
    var url: String
    var token: String
    var expiresAt: Date
    var scope: String
    var password: String?
    var createdAt: Date
}

/// Where the review found a problem: the notes, or lines `from`…`to` of what was sent.
struct ShareHit: Codable, Equatable {
    var part: String
    var from: Int?
    var to: Int?
    var questions: [String]

    /// The record's line indices behind the hits, given which record lines were sent (`kept`).
    static func recordLines(_ hits: [ShareHit], kept: [Int]) -> Set<Int> {
        var out: Set<Int> = []
        for h in hits where h.part == "lines" {
            guard let a = h.from, let b = h.to, a <= b else { continue }
            for i in a...b where i < kept.count { out.insert(kept[i]) }
        }
        return out
    }
}

enum SharePassword {
    static let iterations = 210_000

    /// PBKDF2-SHA256, 32 bytes: what the browser derives from the password (site/share.js). The
    /// server keeps only its hash, so the password itself never leaves either side.
    static func verifier(_ password: String, salt: Data, iterations: Int = iterations) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    /// "ruby-41-lake": easy to read out and type; the server limits how many can be tried.
    static func make() -> String {
        let w = words.split(separator: " ")
        return "\(w.randomElement()!)-\(Int.random(in: 10...99))-\(w.randomElement()!)"
    }

    private static let words = "amber apple arrow aspen basil beach birch bloom brook cedar cherry cloud coral comet dawn delta dune ember fern field flint frost grove harbor hazel honey iris island jade lake lark lemon lily linen maple meadow mint moss olive orbit pearl pine plum pond quartz rain reed river ruby sage sand shell silk sky slate snow spruce stone storm sun tide tulip velvet willow wind"
}

/// Shares/<record id>.json, 0600 in a 0700 folder.
enum ShareStore {
    nonisolated(unsafe) static var folderOverride: URL?

    static var folder: URL {
        folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder).appendingPathComponent("Shares")
    }

    static func read(_ sessionID: String) -> ShareRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(sessionID + ".json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ShareRecord.self, from: data)
    }

    static func save(_ r: ShareRecord, for sessionID: String) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(r) else { return }
        _ = SecretFile.write(data, to: folder.appendingPathComponent(sessionID + ".json"))
    }

    static func remove(_ sessionID: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(sessionID + ".json"))
    }

    static func all() -> [String: ShareRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var out: [String: ShareRecord] = [:]
        for f in files where f.pathExtension == "json" {
            let id = f.deletingPathExtension().lastPathComponent
            if let r = read(id) { out[id] = r }
        }
        return out
    }
}

/// A file only this user can read, left out of backups (like the AI keys in AIKey).
enum SecretFile {
    static func write(_ data: Data, to file: URL) -> Bool {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            if !fm.fileExists(atPath: file.path) {
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try data.write(to: file)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            debugLog("share: could not write \(file.lastPathComponent)")
            return false
        }
    }
}

/// Talks to the share service on cicada.indaloop.app (server/). There are no accounts: this Mac is
/// an Ed25519 key made on first use (share-device.json, 0600), registered once with a small proof of
/// work, and every write is signed (method, path, time, nonce, body hash), as server/src/auth.js
/// checks. Not an AI call, so not LingClient: the review runs on the server.
@MainActor
final class ShareClient {
    static let shared = ShareClient()

    enum Outcome {
        case shared(ShareRecord)
        case blocked([ShareHit], kept: [Int])
        case failed(code: String, retryAfter: Int?)
    }

    struct Stats: Decodable {
        var id: String
        var expiresAt: Double
        var state: String
        var views: Int
    }

    /// Which app shares (the server keeps it per device and checks the version).
    #if CICADA_IOS
    static let platform = "ios"
    #else
    static let platform = "mac"
    #endif
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// Dev builds can point at a local Worker: `defaults write com.wquguru.cicada.dev shareServer http://127.0.0.1:8787`.
    var base: URL {
        if let s = UserDefaults.standard.string(forKey: "shareServer"), let u = URL(string: s) { return u }
        return URL(string: "https://cicada.indaloop.app")!
    }

    private struct DeviceFile: Codable {
        var key: String
        var device: String?
        var server: String?
    }

    private var deviceFile: URL { ShareStore.folder.deletingLastPathComponent().appendingPathComponent("share-device.json") }

    private func loadDevice() -> (Curve25519.Signing.PrivateKey, DeviceFile) {
        if let data = try? Data(contentsOf: deviceFile), let f = try? JSONDecoder().decode(DeviceFile.self, from: data),
           let raw = Data(base64Encoded: f.key), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return (key, f)
        }
        let key = Curve25519.Signing.PrivateKey()
        let f = DeviceFile(key: key.rawRepresentation.base64EncodedString(), device: nil, server: nil)
        saveDevice(f)
        return (key, f)
    }

    private func saveDevice(_ f: DeviceFile) {
        if let data = try? JSONEncoder().encode(f) { _ = SecretFile.write(data, to: deviceFile) }
    }

    /// The device id, registering this Mac with the server first if needed.
    private func device(force: Bool = false) async throws -> (Curve25519.Signing.PrivateKey, String) {
        var (key, f) = loadDevice()
        if !force, let id = f.device, f.server == base.absoluteString { return (key, id) }
        let pub = key.publicKey.rawRepresentation
        let nonce = await Task.detached(priority: .userInitiated) { Self.proofOfWork(pub) }.value
        let body: [String: Any] = ["key": Self.b64url(pub), "pow": Self.b64url(nonce), "platform": Self.platform, "version": Self.version]
        let (data, status) = try await send("POST", "/api/v1/devices", body: try JSONSerialization.data(withJSONObject: body), signer: nil)
        guard status == 201, let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["device"] as? String else {
            throw Failure(code: Self.code(data) ?? "register_failed", retryAfter: nil)
        }
        f.device = id
        f.server = base.absoluteString
        saveDevice(f)
        (key, _) = loadDevice()
        return (key, id)
    }

    /// 20 leading zero bits of sha256(public key ‖ nonce): about a million hashes, a second or two.
    nonisolated static func proofOfWork(_ pub: Data) -> Data {
        var n: UInt64 = 0
        while true {
            var nonce = Data(count: 8)
            nonce.withUnsafeMutableBytes { $0.storeBytes(of: n.bigEndian, as: UInt64.self) }
            let h = Array(SHA256.hash(data: pub + nonce))
            if h[0] == 0, h[1] == 0, h[2] < 16 { return nonce }
            n += 1
        }
    }

    struct Failure: Error {
        var code: String
        var retryAfter: Int?
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:],
                      signer: (Curve25519.Signing.PrivateKey, String)?) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = method
        req.timeoutInterval = 90
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("\(Self.platform)/\(Self.version)", forHTTPHeaderField: "X-Cicada-Client")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let (key, id) = signer {
            let time = String(Int(Date().timeIntervalSince1970))
            var raw = Data(count: 16)
            _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let nonce = Self.b64url(raw)
            let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
            let message = "\(method)\n\(path)\n\(time)\n\(nonce)\n\(hash)"
            let sig = try key.signature(for: Data(message.utf8))
            req.setValue(id, forHTTPHeaderField: "X-Cicada-Device")
            req.setValue(time, forHTTPHeaderField: "X-Cicada-Time")
            req.setValue(nonce, forHTTPHeaderField: "X-Cicada-Nonce")
            req.setValue(Self.b64url(sig), forHTTPHeaderField: "X-Cicada-Signature")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Failure(code: "network", retryAfter: nil)
        }
    }

    /// A signed call; registers again once if the server no longer knows this Mac.
    private func signed(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var signer = try await device()
        var (data, status) = try await send(method, path, body: body, headers: headers, signer: signer)
        if status == 401, Self.code(data) == "unknown_device" {
            signer = try await device(force: true)
            (data, status) = try await send(method, path, body: body, headers: headers, signer: signer)
        }
        return (data, status)
    }

    struct Options {
        var scope: ShareScope = .notes
        var days = 7
        var names = false
        var password: String?
        var summaryInPreview = false
        var removed: Set<Int> = []
        var dropNotes = false
    }

    func share(_ s: Session, _ o: Options) async -> Outcome {
        let doc = ShareProjection.doc(s, scope: o.scope, names: o.names, removed: o.removed, dropNotes: o.dropNotes)
        let kept = o.scope == .full ? s.lines.indices.filter { !o.removed.contains($0) && !s.lines[$0].src.isEmpty } : []
        var body: [String: Any] = [
            "doc": (try? JSONSerialization.jsonObject(with: ShareProjection.encode(doc))) ?? [:],
            "scope": o.scope.rawValue, "days": o.days, "summaryInPreview": o.summaryInPreview,
        ]
        if let pw = o.password {
            var salt = Data(count: 16)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            let v = await Task.detached { SharePassword.verifier(pw, salt: salt) }.value
            body["password"] = ["salt": Self.b64url(salt), "iter": SharePassword.iterations,
                                "hash": Self.b64url(Data(SHA256.hash(data: v)))]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            // The same meeting, content and settings sent again (the answer was lost) gets the same
            // link back; any other setting makes a new share.
            let settings = "\(o.scope.rawValue)|\(o.days)|\(o.names)|\(o.password ?? "")|\(o.summaryInPreview)"
            let idem = s.id + "-" + SHA256.hash(data: ShareProjection.encode(doc) + Data(settings.utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            let (out, status) = try await signed("POST", "/api/v1/shares", body: data, headers: ["Idempotency-Key": idem])
            let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] ?? [:]
            switch status {
            case 200, 201:
                guard let id = obj["id"] as? String, let url = obj["url"] as? String, let token = obj["token"] as? String,
                      let exp = obj["expiresAt"] as? Double else { return .failed(code: "server_error", retryAfter: nil) }
                if let old = ShareStore.read(s.id), old.id != id { await revoke(old, sessionID: nil) }
                let r = ShareRecord(id: id, url: url, token: token, expiresAt: Date(timeIntervalSince1970: exp),
                                    scope: o.scope.rawValue, password: o.password, createdAt: Date())
                ShareStore.save(r, for: s.id)
                debugLog("share: \(s.id) shared (\(o.scope.rawValue), \(o.days) days\(o.password == nil ? "" : ", password"))")
                return .shared(r)
            case 422:
                let hits = (try? JSONDecoder().decode([ShareHit].self, from: JSONSerialization.data(withJSONObject: obj["hits"] ?? []))) ?? []
                debugLog("share: \(s.id) blocked " + hits.map { h in
                    h.part + (h.from.map { " \($0)-\(h.to ?? $0)" } ?? "") + " " + h.questions.joined(separator: ",")
                }.joined(separator: "; "))
                return .blocked(hits, kept: kept)
            default:
                debugLog("share: \(s.id) failed \(status) \(obj["code"] as? String ?? "?")")
                return .failed(code: obj["code"] as? String ?? "server_error", retryAfter: obj["retryAfter"] as? Int)
            }
        } catch let f as Failure {
            return .failed(code: f.code, retryAfter: f.retryAfter)
        } catch {
            return .failed(code: "server_error", retryAfter: nil)
        }
    }

    /// Turns the link off on the server and forgets it here. `sessionID` nil: the record is being replaced.
    @discardableResult
    func revoke(_ r: ShareRecord, sessionID: String?) async -> Bool {
        let ok: Bool
        if let (data, status) = try? await signed("DELETE", "/api/v1/shares/\(r.id)", headers: ["Authorization": "Bearer \(r.token)"]) {
            // 404: already gone (or never ours); either way nothing to keep.
            ok = status == 204 || status == 404
            if !ok { debugLog("share: revoke \(r.id) failed \(status) \(Self.code(data) ?? "?")") }
        } else {
            ok = false
        }
        if ok, let sessionID { ShareStore.remove(sessionID) }
        return ok
    }

    func stats(_ ids: [String]) async -> [String: Stats] {
        guard !ids.isEmpty, let (data, status) = try? await signed("GET", "/api/v1/shares?ids=\(ids.joined(separator: ","))"),
              status == 200, let list = try? JSONDecoder().decode([String: [Stats]].self, from: data)["shares"] else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    nonisolated static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func code(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String
    }
}
