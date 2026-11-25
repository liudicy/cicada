import AVFoundation

// The host recognizer only uses the speech models; Recognition.swift also names the AI service's
// stream (CloudHearing.swift), which would pull in the whole AI client. These stand in for it here.

struct CloudHeard: Equatable, Sendable {}

final class CloudStream: RecognitionStream, @unchecked Sendable {
    typealias Hear = @MainActor @Sendable (_ wav: Data, _ seconds: Double) async -> CloudHeard?
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    let results = AsyncThrowingStream<Recognition.Piece, Error> { $0.finish() }
    init(format: AVAudioFormat? = nil, hear: @escaping Hear) {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finalize(through seconds: Double) async throws {}
    func finish() async {}
    func cancel() async {}
}
