import AVFoundation
import Foundation

/// A meeting in the room: a real microphone → the same 48 kHz mono float buffers the system-audio
/// tap produces, so everything downstream of the capture is identical for the two sources.
/// Never follows the system default onto the virtual mic (Cicada would hear its own voice):
/// `AppModel` passes `SystemMic.recordingDevice`.
final class MicCapture {
    /// Called on the engine's tap thread. Must not block.
    var onAudio: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()

    enum Failure: LocalizedError {
        case noPermission
        case start(Error)

        var errorDescription: String? {
            switch self {
            case .noPermission: L("无法读取麦克风，请在系统设置里允许“麦克风”")
            case .start(let error): error.localizedDescription
            }
        }
    }

    func start(device: OutputDevice?) throws {
        stop()
        // .notDetermined starts anyway: the request prompt is on its way, and `reconnectAudio`
        // reopens the device once it is granted. .denied / .restricted read silence forever.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized, .notDetermined: break
        default: throw Failure.noPermission
        }
        AudioDevices.pinInput(engine, to: device)
        let input = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcm, _ in
            self?.onAudio?(pcm)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.start(error)
        }
        debugLog("mic capture started, device \(AudioDevices.inputDevice(of: engine))")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { stop() }
}
