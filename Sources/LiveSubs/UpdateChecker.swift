import AppKit
import Foundation

/// Checks GitHub Releases for a version newer than the running one: at launch, every 4 hours,
/// after the Mac wakes and when the menu bar panel opens (those two only once the last check is an
/// hour old). Failures (offline, rate-limited, or the repository not public: the API answers 404)
/// are silent.
@MainActor
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        /// The release page, the fallback when the update can't be installed in place.
        let url: URL
        /// The app zip and its checksums, when the release has them.
        let zip: URL?
        let checksums: URL?
        /// The zip's size in bytes, 0 when unknown.
        let size: Int
    }

    static var repository: URL { DevBuild.isDev ? forkRepository : upstreamRepository }
    static let upstreamRepository = URL(string: "https://github.com/wquguru/cicada")!
    /// The fork publishes the dev build ("Cicada Dev") as prereleases; a fork-packaged dev
    /// build (DevBuild.fork) watches those instead of upstream's.
    static let forkRepository = URL(string: "https://github.com/liudicy/cicada")!

    /// `CICADA_UPDATE_FEED` (or the `updateFeed:` debug command) points at another release JSON,
    /// a list or a single release; a file:// URL works, for testing.
    /// The list, not `releases/latest`: every platform shares one version, and a release that only
    /// ships Windows, Android or Linux has no Mac zip, so the newest Mac release may be further down.
    var feed = ProcessInfo.processInfo.environment["CICADA_UPDATE_FEED"].flatMap(URL.init(string:))
        ?? (DevBuild.isDev
            ? URL(string: "https://api.github.com/repos/liudicy/cicada/releases?per_page=20")!
            : URL(string: "https://api.github.com/repos/wquguru/cicada/releases?per_page=20")!)
    private let onUpdate: (Update?) -> Void
    private var timer: Timer?
    private var wakeObserver: Any?
    private var checking = false

    /// How often a running app checks, and how old the last check must be before waking or
    /// opening the panel checks again. GitHub allows 60 anonymous API calls an hour.
    static let every: TimeInterval = 4 * 60 * 60
    static let stale: TimeInterval = 60 * 60

    /// The last time the feed answered, kept across launches.
    private(set) var lastChecked = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date {
        didSet { UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked") }
    }

    init(onUpdate: @escaping (Update?) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        Task { await check() }
        // A short tick that checks when due, not one 4-hour timer: a timer doesn't count while
        // the Mac sleeps, so a laptop that is often closed would hardly ever check.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.checkIfDue(after: Self.every) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            // The network takes a moment to come back after waking.
            Task { try? await Task.sleep(for: .seconds(15)); await self?.checkIfDue(after: Self.stale) }
        }
    }

    /// Checks only when the last successful check is at least `age` old.
    func checkIfDue(after age: TimeInterval) async {
        guard Self.due(last: lastChecked, now: Date(), after: age) else { return }
        await check()
    }

    nonisolated static func due(last: Date?, now: Date, after age: TimeInterval) -> Bool {
        guard let last else { return true }
        // A clock set back leaves `last` in the future: check rather than wait for it.
        return now.timeIntervalSince(last) >= age || last > now
    }

    /// Returns false when the feed couldn't be reached or answered with something unexpected.
    @discardableResult
    func check() async -> Bool {
        guard !checking else { return true }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              let releases = Self.decode(data) else { return false }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // A fork-packaged dev build reads the fork's feed: prereleases named Cicada-Dev-…,
        // checksummed in checksums-dev.txt.
        let dev = DevBuild.isDev
        let update = dev
            ? Self.newestMac(in: releases, zipPrefix: "Cicada-Dev-", checksumsName: "checksums-dev.txt", allowPrerelease: true)
            : Self.newestMac(in: releases)
        lastChecked = Date()
        debugLog("update: checked, latest Mac \(update?.version ?? "none"), running \(current)")
        onUpdate(update.flatMap { Self.isNewer($0.version, than: current) ? $0 : nil })
        return true
    }

    nonisolated static func decode(_ data: Data) -> [Release]? {
        let decoder = JSONDecoder()
        return (try? decoder.decode([Release].self, from: data))
            ?? (try? decoder.decode(Release.self, from: data)).map { [$0] }
    }

    /// The newest published release that ships the Mac app. A release without the Mac zip only
    /// carries other platforms (the Mac app had no change), so it is skipped, not offered.
    nonisolated static func newestMac(in releases: [Release]) -> Update? {
        newestMac(in: releases, zipPrefix: "Cicada-", checksumsName: "checksums.txt", allowPrerelease: false)
    }

    /// The general form, so the fork's dev feed (Cicada-Dev-… prereleases, checksums-dev.txt)
    /// and tests can use the same matching.
    nonisolated static func newestMac(in releases: [Release], zipPrefix: String, checksumsName: String,
                                      allowPrerelease: Bool) -> Update? {
        let shipped = releases.compactMap { release -> Update? in
            guard release.draft != true, allowPrerelease || release.prerelease != true,
                  let url = URL(string: release.html_url),
                  let zip = release.assets.first(where: { $0.name.hasPrefix(zipPrefix) && $0.name.hasSuffix("-macOS-AppleSilicon.zip") })
            else { return nil }
            let checksums = release.assets.first { $0.name == checksumsName }
            return Update(version: release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v")), url: url,
                          zip: URL(string: zip.browser_download_url),
                          checksums: checksums.flatMap { URL(string: $0.browser_download_url) },
                          size: zip.size ?? 0)
        }
        return shipped.max { isNewer($1.version, than: $0.version) }
    }

    /// Compares dotted numeric versions: "2.10.0" is newer than "2.9.1".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]
        var draft: Bool? = nil
        var prerelease: Bool? = nil
    }

    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int?
    }
}
