import AVFoundation

// Audio formats and files shared by the Mac and iOS apps (ios/shared-sources.txt).

/// Stateful sample-rate / sample-format converter.
final class PCMConverter {
    private var converter: AVAudioConverter?

    func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter == nil || converter!.inputFormat != input.format || converter!.outputFormat != format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }
}

enum AudioFileWriter {
    /// AAC .m4a, mono, at the buffer's sample rate. The processing format must
    /// match the buffers written to it exactly.
    static func open(_ url: URL, format: AVAudioFormat) -> AVAudioFile? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 32_000,
        ]
        return try? AVAudioFile(forWriting: url, settings: settings,
                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Meetings are recorded as ADTS (`system.aac`), which stays readable up to the last packet
    /// if the app is killed; an .m4a is unreadable until it is closed. `finish` turns it into
    /// the .m4a afterwards (and at launch, for a meeting the app didn't get to close).
    static func partial(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("aac") }

    /// Rewraps `partial(url)` into `url` without re-encoding, then removes the partial file.
    /// A partial file next to an .m4a means the last rewrap was cut short: it is done again.
    /// `until`: seconds to keep from the start (the silent tail of a meeting that ended by itself).
    nonisolated static func finish(_ url: URL, until: Double? = nil) async {
        let src = partial(url)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.removeItem(at: url)
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        if let until { export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: until, preferredTimescale: 600)) }
        do {
            try await export.export(to: url, as: .m4a)
            try? FileManager.default.removeItem(at: src)
        } catch {
            debugLog("audio rewrap failed \(url.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
