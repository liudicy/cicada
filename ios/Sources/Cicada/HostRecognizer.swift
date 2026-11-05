import AVFoundation
import Foundation

#if targetEnvironment(simulator)
/// The simulator's speech models are empty placeholders (every recognizer answers "model not
/// available"), so a dev build there sends its audio to the Mac it runs on: `ios/tools/host-recognizer`
/// reads it from the app's container and recognizes it on device with the Mac's own `Recognition`,
/// writing the pieces back. Same clock as any `RecognitionStream`: seconds of audio appended.
/// Only for testing in the simulator; an iPhone recognizes on itself.
enum HostRecognizer {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("host-recognizer", isDirectory: true)
    }

    static func install() {
        guard DevBuild.isDev else { return }
        Recognition.host = { locale, drafts in try HostStream(locale: locale, drafts: drafts) }
        debugLog("recognizer: the Mac's (ios/tools/host-recognizer)")
    }
}

final class HostStream: RecognitionStream, @unchecked Sendable {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let results: AsyncThrowingStream<Recognition.Piece, Error>
    private let out: AsyncThrowingStream<Recognition.Piece, Error>.Continuation
    private let dir: URL
    private let audio: FileHandle
    private let queue = DispatchQueue(label: "com.wquguru.cicada.host-recognizer")
    private var reader: Task<Void, Never>?
    private var done = false

    private struct Line: Decodable {
        var text: String?
        var isFinal: Bool?
        var start: Double?
        var end: Double?
        var confidence: Double?
        var done: Bool?
        var error: String?
    }

    init(locale: String, drafts: Bool) throws {
        dir = HostRecognizer.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent("audio.f32")
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("results.jsonl").path, contents: nil)
        audio = try FileHandle(forWritingTo: audioURL)
        (results, out) = AsyncThrowingStream.makeStream(of: Recognition.Piece.self)
        // Written last: the host starts on a folder once its request is there.
        let request = try JSONSerialization.data(withJSONObject: ["locale": locale, "drafts": drafts])
        try request.write(to: dir.appendingPathComponent("request.json"))
        let resultsURL = dir.appendingPathComponent("results.jsonl")
        let out = self.out
        reader = Task.detached { [weak self] in
            var offset: UInt64 = 0, pending = Data()
            let started = Date()
            var heard = false
            while !Task.isCancelled {
                if let h = try? FileHandle(forReadingFrom: resultsURL) {
                    try? h.seek(toOffset: offset)
                    let data = h.readDataToEndOfFile()
                    try? h.close()
                    offset += UInt64(data.count)
                    pending.append(data)
                    while let nl = pending.firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        heard = true
                        guard let line = try? JSONDecoder().decode(Line.self, from: lineData) else { continue }
                        if line.done == true { out.finish(); return }
                        if let e = line.error { out.finish(throwing: NSError(domain: "HostRecognizer", code: 1, userInfo: [NSLocalizedDescriptionKey: e])); return }
                        if let text = line.text {
                            out.yield(.init(text: text, isFinal: line.isFinal ?? false, start: line.start ?? 0, end: line.end ?? 0, confidence: line.confidence))
                        }
                    }
                }
                if !heard, Date().timeIntervalSince(started) > 8, self?.claimed == false {
                    out.finish(throwing: NSError(domain: "HostRecognizer", code: 2, userInfo: [NSLocalizedDescriptionKey: "host-recognizer isn't running on the Mac"]))
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private var claimed: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("claimed").path) }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let p = buffer.floatChannelData?[0] else { return }
        let data = Data(bytes: p, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        queue.async { [audio] in try? audio.write(contentsOf: data) }
    }

    func finalize(through seconds: Double) async throws {}

    func finish() async {
        queue.sync { try? audio.close() }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("end").path, contents: nil)
        // The host finishes the last line and says done; don't wait forever on it.
        for _ in 0..<100 where reader?.isCancelled == false {
            if (try? String(contentsOf: dir.appendingPathComponent("results.jsonl"), encoding: .utf8))?.contains("\"done\"") == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        reader?.cancel()
        out.finish()
        try? FileManager.default.removeItem(at: dir)
    }

    func cancel() async {
        queue.sync { try? audio.close() }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("end").path, contents: nil)
        reader?.cancel()
        out.finish()
    }
}
#endif
