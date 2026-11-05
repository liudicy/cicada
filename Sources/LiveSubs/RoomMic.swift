import AVFoundation
import CoreAudio

// 会议室: listening to the people in the room through a real microphone instead of what the Mac
// plays. Same shape as `SystemAudioTap` (mono buffers out), so the rest of listening is unchanged.

protocol AudioSource: AnyObject {
    var onAudio: ((AVAudioPCMBuffer) -> Void)? { get set }
    func start() throws
    func stop()
}

extension SystemAudioTap: AudioSource {}

/// Which microphone hears the room.
enum RoomMicPlan {
    struct Input: Equatable {
        let uid: String
        var builtIn = false
        var bluetooth = false
        var virtual = false
    }

    /// The system default, unless it is the virtual mic (同声传译 makes it the default) or a
    /// Bluetooth headset's (AirPods hear the wearer, not the table, and drop to call quality while
    /// their mic is open); then the Mac's own microphone.
    static func pick(defaultUID: String?, inputs: [Input]) -> String? {
        if let d = inputs.first(where: { $0.uid == defaultUID }), !d.virtual, !d.bluetooth { return d.uid }
        return inputs.first(where: \.builtIn)?.uid
            ?? inputs.first(where: { !$0.virtual && !$0.bluetooth })?.uid
            ?? inputs.first(where: { !$0.virtual })?.uid
    }
}

/// When a block of audio counts as speech. The Mac's own audio is digital silence between words, so
/// a fixed -40 dBFS works there. A room mic always hears the room (a fan, the street), and a voice
/// across the table can be quieter than -40 dBFS: there the line sits at twice the room's own noise.
/// The noise is the quietest moment of each second (the gaps between words, even while people talk
/// on and on), taken low over the last half minute.
struct VoiceGate {
    static let fixed: Float = 0.01
    static let lowest: Float = 0.0015
    /// About a second of the mic's ~85 ms blocks.
    static let blocksPerSecond = 12
    var adaptive = false
    private var quietest: [Float] = []
    private var second: Float = .infinity
    private var blocks = 0

    init(adaptive: Bool = false) { self.adaptive = adaptive }

    var threshold: Float {
        guard adaptive else { return Self.fixed }
        guard quietest.count >= 3 else { return 0.004 }
        let floor = quietest.sorted()[quietest.count / 5]
        return min(Self.fixed, max(Self.lowest, floor * 2))
    }

    mutating func voiced(_ rms: Float) -> Bool {
        let on = rms >= threshold
        guard adaptive else { return on }
        second = min(second, rms)
        blocks += 1
        if blocks >= Self.blocksPerSecond {
            quietest.append(second)
            if quietest.count > 30 { quietest.removeFirst() }
            second = .infinity
            blocks = 0
        }
        return on
    }
}

/// 在会议室里开会？: asked when listening to the Mac and it has played nothing for a minute. It
/// only reads the system audio already being listened to, so the microphone stays closed.
enum RoomPrompt {
    static let after = 60.0

    static func asks(room: Bool, listened: Double, voiced: Double) -> Bool {
        !room && listened >= after && voiced < 1
    }

    /// Shown in the panel: asked, not answered this meeting, and no meeting app in a call (early
    /// in a call nobody may have spoken yet; that silence is not a meeting in the room).
    static func shows(silent: Bool, answered: Bool, inCall: Bool) -> Bool {
        silent && !answered && !inCall
    }
}

extension AudioDevices {
    static func transport(_ device: AudioObjectID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value
    }

    /// The microphone `RoomMicPlan` picks among the Mac's inputs right now.
    static var roomMic: OutputDevice? {
        let all = inputs()
        let plan = all.map { d -> RoomMicPlan.Input in
            let t = transport(d.id)
            return .init(uid: d.uid, builtIn: t == kAudioDeviceTransportTypeBuiltIn,
                         bluetooth: t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE,
                         virtual: d.isVirtualMic)
        }
        let uid = RoomMicPlan.pick(defaultUID: defaultInput?.uid, inputs: plan)
        return all.first { $0.uid == uid }
    }
}

/// A microphone as an audio source. While `muted`, silence goes on in its place: the Mac reading a
/// translation aloud, or you holding the talk key, would otherwise come back as someone in the room.
/// Silence rather than nothing keeps the recognizer's clock and the recording in step.
final class RoomMic: AudioSource {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    private var engine = AVAudioEngine()
    private let device: OutputDevice?
    private let lock = NSLock()
    private var _muted = false
    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    private var configObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(device: OutputDevice?) { self.device = device }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, defaultInputListener)
        }
    }

    /// Pinning the device on a fresh engine itself reports a configuration change: not a reason to go again.
    private var startedAt = Date.distantPast

    private func restart(_ why: String) {
        guard !stopped, Date().timeIntervalSince(startedAt) > 1 else { return }
        debugLog("room mic: \(why), restarting")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A fresh engine: the old one still names the pinned device after moving off it, so
        // pinning it again would be skipped.
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = AVAudioEngine()
        do { try start() } catch { debugLog("room mic restart failed: \(error)") }
    }

    var deviceName: String { device?.name ?? AudioDevices.inputDevice(of: engine) }

    func start() throws {
        startedAt = Date()
        AudioDevices.pinInput(engine, to: device)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "RoomMic", code: -1, userInfo: [NSLocalizedDescriptionKey: L("没有可用的麦克风")])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buf, _ in
            guard let self, buf.frameLength > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
                  let dst = out.floatChannelData?[0] else { return }
            out.frameLength = buf.frameLength
            let n = Int(buf.frameLength)
            let channels = Int(buf.format.channelCount)
            if self.muted || channels == 0 || buf.floatChannelData == nil {
                dst.update(repeating: 0, count: n)
            } else if let src = buf.floatChannelData {
                dst.update(from: src[0], count: n)
                if channels > 1 {
                    for c in 1..<channels { for i in 0..<n { dst[i] += src[c][i] } }
                    let scale = 1 / Float(channels)
                    for i in 0..<n { dst[i] *= scale }
                }
            }
            self.onAudio?(out)
        }
        engine.prepare()
        try engine.start()
        // A device coming or going, or another app switching the system mic, stops the engine
        // without a word: start it again, or the room would go quiet for the rest of the meeting.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.restart("audio configuration changed")
            }
        }
        // A new system default (AirPods connecting, another app switching to a virtual mic) stops
        // the audio with no notification, though the engine still names the pinned device: start over.
        if defaultInputListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.restart("system input changed")
            }
            defaultInputListener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInputAddress, .main, listener)
        }
    }

    private var stopped = false

    func stop() {
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
