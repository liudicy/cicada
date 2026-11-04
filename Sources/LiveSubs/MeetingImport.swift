import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Turns a recording file (m4a, wav, mp3…) into a meeting. Language detection and transcription
/// run on-device as fast as the file reads; translations follow sentence by sentence. The audio
/// becomes the meeting's system.m4a, so a later cloud proofread works on it like on a live one.
enum MeetingImport {
    enum Failure: Error, Equatable {
        case unreadable
        /// No speech heard in the file.
        case silent
        case model(String)
    }

    /// Reads, transcribes and translates `url`, returning the meeting's lines and language.
    /// `progress` is called on the main actor with 0…1 as results land.
    static func run(url: URL, sourceMode: SourceMode, candidates: [Lang], target: String,
                    translate: @escaping (String, String, String) async -> String?,
                    progress: @escaping @MainActor (Double) -> Void) async throws -> (lines: [TranscriptLine], lang: Lang, seconds: Double) {
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        guard seconds >= 1 else { throw Failure.unreadable }

        let lang = try await language(of: file, sourceMode: sourceMode, candidates: candidates)
        debugLog("import: language \(lang.locale)")
        let transcriber = SpeechTranscriber(locale: Locale(identifier: lang.locale),
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.transcriptionConfidence])
        try await ensureModel(for: transcriber, lang: lang)

        // File input, finishAfterFile: the analyzer reads the file itself and closes the results
        // stream at its end — a hand-fed stream never does, and collecting would hang.
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () throws -> [TranscriptLine] in
            var lines: [TranscriptLine] = []
            var n = 0
            for try await result in transcriber.results where result.isFinal {
                let text = HeardText.clean(String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
                guard text.contains(where: \.isLetter) else { continue }
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(result.range.end)
                n += 1
                let dst = await translate(text, lang.code, target)
                lines.append(TranscriptLine(id: "h\(n)", t: max(0, start), speaker: "them", src: text, dst: dst,
                                            srcLang: lang.code, dstLang: target,
                                            audioStart: max(0, start), audioEnd: max(start, end)))
                await progress(min(0.99, end / seconds))
            }
            return lines
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let heard = try await collector.value
        guard !heard.isEmpty else { throw Failure.silent }
        return (heard, lang, seconds)
    }

    /// The file's spoken language: the fixed one when the settings pin it, else the detector's
    /// ranking of its first seconds.
    private static func language(of file: AVAudioFile, sourceMode: SourceMode, candidates: [Lang]) async throws -> Lang {
        if case .fixed(let lang) = sourceMode { return lang }
        var clip: [AVAudioPCMBuffer] = []
        let position = file.framePosition
        let chunk = AVAudioFrameCount(file.fileFormat.sampleRate)
        for _ in 0..<12 where file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
            clip.append(buf)
        }
        file.framePosition = position
        let ranked = await LanguageDetector.rank(clip, candidates: candidates)
        guard let best = ranked.first, best.chars >= 4 else {
            throw Failure.model(ranked.first?.lang.name ?? "?")
        }
        return best.lang
    }

    /// Like ListenEngine.ensureModel: installed, or downloaded now (a fixed language choice means
    /// the user already asked for it).
    private static func ensureModel(for transcriber: SpeechTranscriber, lang: Lang) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return }
        guard status != .unsupported else { throw Failure.model(lang.name) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// The audio as the meeting's system.m4a: rewrapped when it already is one, re-encoded to AAC
    /// otherwise, so proofread slices and the records page's playback read it like any recording.
    static func copyAudio(from url: URL, to dest: URL) async throws {
        let srcExt = url.pathExtension.lowercased()
        try? FileManager.default.removeItem(at: dest)
        if ["m4a", "aac", "mp4"].contains(srcExt), (try? AVAudioFile(forReading: url)) != nil {
            try FileManager.default.copyItem(at: url, to: dest)
            return
        }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.unreadable
        }
        do {
            try await export.export(to: dest, as: .m4a)
        } catch {
            debugLog("import audio convert failed: \(error)")
            throw Failure.unreadable
        }
    }
}
