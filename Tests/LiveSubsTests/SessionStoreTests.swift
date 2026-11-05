import Foundation
import Testing
@testable import LiveSubs

/// Ending a meeting: an empty one goes, one whose recording holds speech stays (issue #5).
@MainActor @Suite struct SessionStoreTests {
    func store() -> SessionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cicada-store-\(UUID().uuidString)")
        return SessionStore(root: root)
    }

    /// The partial file the recorder writes while the meeting runs.
    func record(_ store: SessionStore, _ id: String) {
        FileManager.default.createFile(atPath: AudioFileWriter.partial(store.systemAudioURL(id)).path, contents: Data(count: 1024))
    }

    @Test func aMeetingWithNothingSaidIsDropped() {
        let s = store()
        let id = s.begin().id
        record(s, id)
        s.end()
        #expect(s.session(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: s.folder(id).path))
    }

    @Test func aRecordingWithSpeechIsKeptWithoutLines() {
        let s = store()
        let id = s.begin().id
        record(s, id)
        s.end(heardSpeech: true)
        #expect(s.session(id)?.hasAudio == true)
        #expect(FileManager.default.fileExists(atPath: AudioFileWriter.partial(s.systemAudioURL(id)).path))
    }

    @Test func speechWithoutARecordingLeavesNothingToKeep() {
        let s = store()
        let id = s.begin().id
        s.end(heardSpeech: true)
        #expect(s.session(id) == nil)
    }
}
