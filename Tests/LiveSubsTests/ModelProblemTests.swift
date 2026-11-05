import Foundation
import Testing
@testable import LiveSubs

@Suite struct ModelProblemTests {
    private func cause(_ e: Error, online: Bool = true, free: Int64? = 50_000_000_000) -> ModelProblem.Cause {
        ModelProblem.cause(of: e, online: online, freeBytes: free)
    }

    @Test func fiveModelLimit() {
        #expect(cause(NSError(domain: "SFSpeechErrorDomain", code: 11)) == .limit)
        // The limit wins even offline: giving a model back needs no network.
        #expect(cause(ModelProblem.simulated("limit"), online: false) == .limit)
    }

    @Test func offlineFromTheErrorOrTheMac() {
        #expect(cause(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .offline)
        let wrapped = NSError(domain: "AssetInventory", code: 7,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)])
        #expect(cause(wrapped) == .offline)
        #expect(cause(NSError(domain: "Whatever", code: 1), online: false) == .offline)
    }

    @Test func diskFromTheErrorOrFreeSpace() {
        #expect(cause(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .disk)
        #expect(cause(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .disk)
        #expect(cause(NSError(domain: "Whatever", code: 1), free: 200_000_000) == .disk)
    }

    @Test func dictationOnOlderMacs() {
        let own = NSError(domain: "LiveSubsSpeech", code: 4, userInfo: [NSLocalizedDescriptionKey: "add it in Dictation"])
        // Offline or short of space doesn't matter: only Dictation settings help.
        #expect(cause(own, online: false) == .dictation("add it in Dictation"))
    }

    @Test func otherKeepsCicadasOwnMessage() {
        let own = NSError(domain: "LiveSubsSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "not on this Mac"])
        #expect(cause(own) == .other("not on this Mac"))
        #expect(cause(NSError(domain: "Whatever", code: 1)) == .other(nil))
        #expect(cause(NSError(domain: "Whatever", code: 1), free: nil) == .other(nil))
    }
}
