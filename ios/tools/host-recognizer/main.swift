import AVFoundation
import Foundation

// Recognizes speech for the iOS simulator's dev build, whose speech models are empty placeholders
// (ios/Sources/Cicada/HostRecognizer.swift). Watches each app container's Caches/host-recognizer:
// a folder with request.json is one stream; its audio.f32 (16 kHz mono Float32, growing) goes
// through the Mac's own Recognition.swift, and every piece is appended to results.jsonl.
//   ios/scripts/host-recognizer.sh   (builds this and watches the booted simulators)

enum DevBuild { static let isDev = true }
func debugLog(_ message: String) { print("\(Date()) \(message)") }
func contentLog(_ message: @autoclosure () -> String) {}
func L(_ s: String.LocalizationValue) -> String { String(localized: s) }

let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

func write(_ obj: [String: Any], to url: URL) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0A)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
}

func serve(_ dir: URL) async {
    let results = dir.appendingPathComponent("results.jsonl")
    guard let req = try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("request.json"))) as? [String: Any],
          let locale = req["locale"] as? String else { return }
    let drafts = req["drafts"] as? Bool ?? true
    debugLog("stream \(dir.lastPathComponent) locale=\(locale) drafts=\(drafts)")
    do {
        try await Recognition.install(locale)
        let stream = try await Recognition.start(locale, drafts: drafts, confidence: true)
        let reader = Task {
            do {
                for try await p in stream.results {
                    var o: [String: Any] = ["text": p.text, "isFinal": p.isFinal, "start": p.start, "end": p.end]
                    if let c = p.confidence { o["confidence"] = c }
                    write(o, to: results)
                    if p.isFinal { debugLog("final: \(p.text)") }
                }
            } catch { write(["error": "\(error)"], to: results) }
        }
        let conv = PCMConverter()
        var offset: UInt64 = 0
        let audioURL = dir.appendingPathComponent("audio.f32")
        while true {
            let ended = FileManager.default.fileExists(atPath: dir.appendingPathComponent("end").path)
            if let h = try? FileHandle(forReadingFrom: audioURL) {
                try? h.seek(toOffset: offset)
                var data = h.readDataToEndOfFile()
                try? h.close()
                data = data.prefix(data.count - data.count % 4)
                offset += UInt64(data.count)
                let frames = data.count / 4
                if frames > 0, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) {
                    b.frameLength = AVAudioFrameCount(frames)
                    data.withUnsafeBytes { raw in
                        b.floatChannelData![0].update(from: raw.bindMemory(to: Float.self).baseAddress!, count: frames)
                    }
                    if let c = conv.convert(b, to: stream.format) { stream.append(c) }
                }
            } else if !FileManager.default.fileExists(atPath: dir.path) {
                await stream.cancel(); break
            }
            if ended {
                await stream.finish()
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = await reader.value
        write(["done": true], to: results)
        debugLog("stream \(dir.lastPathComponent) done")
    } catch {
        debugLog("stream failed: \(error)")
        write(["error": "\(error)"], to: results)
    }
}

/// Every simulator app container's Caches/host-recognizer, found again on each pass: reinstalling
/// the app moves its container.
func roots(_ devices: [String]) -> [URL] {
    let fm = FileManager.default
    let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    var out: [URL] = []
    for d in devices {
        let apps = base.appendingPathComponent("\(d)/data/Containers/Data/Application")
        for a in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let r = a.appendingPathComponent("Library/Caches/host-recognizer")
            if fm.fileExists(atPath: r.path) { out.append(r) }
        }
    }
    return out
}

@main
struct HostRecognizerMain {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let devices = Array(CommandLine.arguments.dropFirst())
        debugLog("watching simulators \(devices) recognizer=\(Recognition.name)")
        while true {
            for root in roots(devices) {
                let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                for d in dirs where FileManager.default.fileExists(atPath: d.appendingPathComponent("request.json").path)
                    && !FileManager.default.fileExists(atPath: d.appendingPathComponent("claimed").path) {
                    FileManager.default.createFile(atPath: d.appendingPathComponent("claimed").path, contents: nil)
                    Task { await serve(d) }
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
