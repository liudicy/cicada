import Foundation

/// A speech model that couldn't be had, and why: what 听不出 says and offers instead of a bare
/// "download failed". Only shown while it blocks listening; a quiet fetch at launch just tries
/// again next time.
struct ModelProblem: Equatable {
    enum Cause: Equatable {
        /// No network: carries on by itself once there is one.
        case offline
        /// The disk is (nearly) full: only the user can make room.
        case disk
        /// macOS keeps five speech models per app: Cicada gives one back and retries by itself,
        /// so this only shows when there is none it can give back.
        case limit
        /// macOS 14/15: the language (or Dictation itself) is added in Dictation settings, by the user.
        case dictation(String)
        /// Anything else; a message of Cicada's own (the Dictation hint on macOS 14/15) when there is one.
        case other(String?)
    }

    let lang: Lang
    let cause: Cause
    /// Picked from 听不出 (retrying picks it again) rather than fetched in the background.
    let picked: Bool

    /// Below this much free space a failed download is put down to the disk.
    static let lowDisk: Int64 = 1_000_000_000

    static func cause(of error: Error, online: Bool, freeBytes: Int64?) -> Cause {
        let chain = errorChain(error as NSError)
        if chain.contains(where: { $0.domain == "SFSpeechErrorDomain" && $0.code == 11 })
            || chain.contains(where: { $0.localizedDescription.contains("Too many allocated locales") }) {
            return .limit
        }
        if let own = chain.first(where: { Recognition.needsUser($0) }) { return .dictation(own.localizedDescription) }
        let offlineCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                            NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        if chain.contains(where: { $0.domain == NSURLErrorDomain && offlineCodes.contains($0.code) }) { return .offline }
        if chain.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
            || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)) }) {
            return .disk
        }
        // The installer's own errors don't always say: what the Mac is like right now does.
        if !online { return .offline }
        if let freeBytes, freeBytes < lowDisk { return .disk }
        if let own = chain.first(where: { $0.domain == "LiveSubsSpeech" }) { return .other(own.localizedDescription) }
        return .other(nil)
    }

    private static func errorChain(_ error: NSError) -> [NSError] {
        var out = [error]
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError { out += errorChain(under) }
        for under in error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? [] { out += errorChain(under) }
        return out
    }

    static func freeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A made-up failure of `kind` (offline, disk, limit, other), for testing the 听不出 card.
    static func simulated(_ kind: String) -> NSError {
        switch kind {
        case "offline": return NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        case "disk": return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        case "limit": return NSError(domain: "SFSpeechErrorDomain", code: 11,
                                     userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, 5 maximum."])
        default: return NSError(domain: "SimulatedModelFailure", code: 1)
        }
    }
}
