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

    /// The one chosen beside 打开麦克风 while it is plugged in (a headset too: then the wearer is
    /// all the user wants). Else the system default, unless it is the virtual mic (同声传译 makes it
    /// the default) or a Bluetooth headset's (AirPods hear the wearer, not the table, and drop to call
    /// quality while their mic is open); then the Mac's own microphone.
    static func pick(defaultUID: String?, inputs: [Input], preferredUID: String? = nil) -> String? {
        if let preferred = inputs.first(where: { $0.uid == preferredUID }), !preferred.virtual {
            return preferred.uid
        }
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
    /// The mic tap's ~85 ms blocks to a second (the default length of a block). The echo-cancelling
    /// unit's are ~11 ms: the window is counted in seconds, not blocks.
    static let blocksPerSecond = 12
    var adaptive = false
    private var quietest: [Float] = []
    private var second: Float = .infinity
    private var elapsed = 0.0

    init(adaptive: Bool = false) { self.adaptive = adaptive }

    var threshold: Float {
        guard adaptive else { return Self.fixed }
        guard quietest.count >= 3 else { return 0.004 }
        let floor = quietest.sorted()[quietest.count / 5]
        return min(Self.fixed, max(Self.lowest, floor * 2))
    }

    mutating func voiced(_ rms: Float, seconds: Double = 1.0 / Double(blocksPerSecond)) -> Bool {
        let on = rms >= threshold
        guard adaptive else { return on }
        second = min(second, rms)
        elapsed += seconds
        if elapsed >= 1 - 1e-9 {
            quietest.append(second)
            if quietest.count > 30 { quietest.removeFirst() }
            second = .infinity
            elapsed = 0
        }
        return on
    }
}

/// 外接麦克风断开了: the microphone hearing the room went away mid-meeting. Another takes over
/// (`RoomMicPlan` among what's left); with none left, 电脑和会议室 goes on with the Mac alone and
/// 会议室 pauses.
enum RoomMicLoss {
    static func detail(next: String?, builtIn: Bool, both: Bool) -> String {
        guard let next else { return both ? L("只听电脑了") : L("没有别的麦克风，已暂停") }
        return builtIn ? L("已改用 Mac 自带的麦克风") : L("已改用 \(next)")
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
    static var roomMic: OutputDevice? { roomMic() }

    /// `excluding`: inputs to treat as gone (the debug command's pretend unplug). `preferredUID`: the
    /// one chosen beside 打开麦克风 (`AppSettings.roomMicUID`).
    static func roomMic(excluding: Set<String> = [], preferredUID: String? = nil) -> OutputDevice? {
        let all = roomMicInputs(excluding: excluding)
        let uid = RoomMicPlan.pick(defaultUID: defaultInput?.uid, inputs: all.map(\.plan), preferredUID: preferredUID)
        return all.first { $0.device.uid == uid }?.device
    }

    /// The menu beside 打开麦克风: the inputs that can hear the room, the virtual ones left out.
    static func roomMicChoices(excluding: Set<String> = []) -> [(device: OutputDevice, bluetooth: Bool)] {
        roomMicInputs(excluding: excluding).filter { !$0.plan.virtual }.map { ($0.device, $0.plan.bluetooth) }
    }

    private static func roomMicInputs(excluding: Set<String>) -> [(device: OutputDevice, plan: RoomMicPlan.Input)] {
        inputs().filter { !excluding.contains($0.uid) }.map { d in
            let t = transport(d.id)
            return (d, .init(uid: d.uid, builtIn: t == kAudioDeviceTransportTypeBuiltIn,
                             bluetooth: t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE,
                             // The aggregate macOS makes for echo cancellation is no microphone of its own.
                             virtual: d.isVirtualMic || d.uid.hasPrefix("CADefaultDeviceAggregate")))
        }
    }
}

/// 打开麦克风 while the Mac plays a meeting: the room mic hears the remote voices again from the
/// speakers. The room mic hears silence while the Mac plays speech, until `hang` after it (the
/// speakers' tail and the room's echo), but only when that is needed and only for speech:
///
/// - Echo is measured, not assumed away: the room mic's level while the Mac is loud against its own
///   floor while the Mac is quiet. Headphones, a meeting mic or a quiet speaker leave the mic where
///   it was, and then nothing is silenced, so people at the table are heard over a remote speaker
///   too. Until there is enough to tell (and whenever it is unclear) the speakers are taken to echo.
/// - Music isn't speech: a loud stretch the Mac's recognizer has found no words in for `music`
///   seconds stops closing the gate, so people at the table are heard over hold music or a video.
///   Words heard again close it again (a voice over music echoes too).
///
/// Measured with the MacBook's speakers and a speaker at the table (ESP32, 10 cm from the mic):
/// echo cancellation (`VoiceMic`) let 0 echoes through but lost most table lines even with nobody
/// online speaking, so this gate, with `EchoMatch` behind it, is the default.
final class EchoGate: @unchecked Sendable {
    static let hang = 0.4
    /// Seconds of loud Mac audio without a word before it counts as music.
    static let music = 4.0
    /// A pause this long ends a loud stretch.
    static let stretchGap = 1.5
    /// Mac audio this recent makes a room block "during the Mac"; this long ago, "the Mac is quiet".
    static let during = 0.15
    static let quietAfter = 1.0
    /// Room level during the Mac over the room's floor: at or over `echoRatio` there is echo, under
    /// `clearRatio` there is none (the gap between them keeps it from flapping).
    static let echoRatio: Float = 3
    static let clearRatio: Float = 2
    /// Seconds of each that a decision needs, and how much is kept.
    static let enough = 3.0
    static let window = 20.0

    private let lock = NSLock()
    private var until: Double = 0
    private var lastLoud: Double = -.infinity
    private var stretchStart: Double = -.infinity
    private var lastWords: Double = -.infinity
    /// Room mic blocks (time, rms, seconds) while the Mac is loud, and while it is quiet.
    private var during: [(t: Double, rms: Float, s: Double)] = []
    private var quiet: [(t: Double, rms: Float, s: Double)] = []
    private var _echo = true
    /// When the Mac's loud blocks came, for `playedShare`.
    private var loud: [Double] = []
    /// Debug (`roomEchoSim:<on|off>`): pretend the measurement says this.
    var forced: Bool?

    /// Forget what was measured: the speakers are taken to echo until measured again (a new
    /// meeting, or the output moved between speakers and headphones).
    func reset() {
        lock.withLock {
            during = []
            quiet = []
            _echo = true
        }
        debugLog("room echo: measuring again")
    }

    /// A loud block of the Mac's audio, on the main engine's audio queue.
    func hold(now: Double = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            loud.append(now)
            loud.removeAll { $0 < now - Self.window * 3 }
            if now - lastLoud > Self.stretchGap { stretchStart = now }
            lastLoud = now
            guard !musicLocked(now), echoLocked else { return }
            until = max(until, now + Self.hang)
        }
    }

    /// The Mac's recognizer heard words (a draft or a line).
    func heardWords(now: Double = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            lastWords = now
            // The words were said a moment ago: close from now, so their echo is caught.
            if now - lastLoud < Self.hang, echoLocked { until = max(until, lastLoud + Self.hang) }
        }
    }

    func closed(now: Double = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.withLock { now < until }
    }

    /// The share of `from`…`to` the Mac played something loud through, when its speakers reach the
    /// mic (0 on headphones). The talk key on the plain mic hears that as much as you.
    func playedShare(from: Double, to: Double) -> Double {
        lock.withLock {
            guard echoLocked, to > from else { return 0 }
            let steps = max(1, Int((to - from) / 0.1))
            var hit = 0
            for i in 0..<steps {
                let t = from + (Double(i) + 0.5) * (to - from) / Double(steps)
                if loud.contains(where: { $0 <= t + Self.hang && $0 >= t - Self.hang }) { hit += 1 }
            }
            return Double(hit) / Double(steps)
        }
    }

    /// Whether the speakers reach the room mic, as last measured.
    var echo: Bool { lock.withLock { echoLocked } }
    /// Whether the Mac is playing something loud that has no words in it.
    func playingMusic(now: Double = CFAbsoluteTimeGetCurrent()) -> Bool { lock.withLock { musicLocked(now) } }

    private var echoLocked: Bool { forced ?? _echo }

    private func musicLocked(_ now: Double) -> Bool {
        now - lastLoud <= Self.stretchGap && now - stretchStart >= Self.music && lastWords < now - Self.music
    }

    /// A block of what the room mic heard, before any silencing.
    func roomLevel(_ rms: Float, seconds: Double, now: Double = CFAbsoluteTimeGetCurrent()) {
        lock.withLock {
            let since = now - lastLoud
            // Music echoes like speech: it counts for the measurement.
            if since <= Self.during { during.append((now, rms, seconds)) } else if since >= Self.quietAfter { quiet.append((now, rms, seconds)) } else { return }
            during.removeAll { $0.t < now - Self.window }
            quiet.removeAll { $0.t < now - Self.window * 3 }
            if let ratio = Self.ratio(during: during.map { ($0.rms, $0.s) }, quiet: quiet.map { ($0.rms, $0.s) }) {
                let was = _echo
                if ratio >= Self.echoRatio { _echo = true } else if ratio < Self.clearRatio { _echo = false }
                if was != _echo {
                    debugLog("room echo: \(_echo ? "speakers reach the mic" : "none") (×\(String(format: "%.1f", ratio)))")
                    if !_echo { until = 0 }
                }
            }
        }
    }

    /// For `hybridState`: seconds of each kind of room block kept, their levels, and the ratio.
    var summary: String {
        lock.withLock {
            let d = during.map(\.rms).sorted(), q = quiet.map(\.rms).sorted()
            let mid = d.isEmpty ? 0 : d[d.count * 4 / 5], floor = q.isEmpty ? 0 : q[q.count / 5]
            return String(format: "during=%.1fs p80=%.4f quiet=%.1fs floor=%.4f", during.reduce(0) { $0 + $1.s }, mid,
                          quiet.reduce(0) { $0 + $1.s }, floor)
        }
    }

    /// The room mic's loud end (a fifth of it louder) while the Mac is loud over its floor (the
    /// quietest fifth) while the Mac is quiet, or nil without `enough` of both. Not the middle: echo
    /// from a laptop's speakers is only a little over the room's noise between the words, and
    /// clearly over it on them. People at the table talking over the Mac raise it too: that errs on
    /// the side of echo.
    static func ratio(during: [(Float, Double)], quiet: [(Float, Double)]) -> Float? {
        guard during.reduce(0, { $0 + $1.1 }) >= enough, quiet.reduce(0, { $0 + $1.1 }) >= enough else { return nil }
        let d = during.map(\.0).sorted(), q = quiet.map(\.0).sorted()
        let floor = max(q[q.count / 5], 0.0002)
        return d[d.count * 4 / 5] / floor
    }
}

/// A microphone as an audio source. While `muted`, silence goes on in its place: the Mac reading a
/// translation aloud, or you holding the talk key, would otherwise come back as someone in the room.
/// Silence rather than nothing keeps the recognizer's clock and the recording in step.
final class RoomMic: AudioSource {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    /// 电脑和会议室 without echo cancellation: silence while the Mac plays speech.
    var echoGate: EchoGate?
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
    var deviceUID: String? { device?.uid }

    func start() throws {
        startedAt = Date()
        silence = .waiting
        AudioDevices.pinInput(engine, to: device)
        let input = engine.inputNode
        // The hardware format: after pinning, the client format can still be the system mic's,
        // and a tap in that format raises an Objective-C exception (issue #12).
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
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
            if let src = buf.floatChannelData, channels > 0 {
                if Self.simulateSilence { for c in 0..<channels { src[c].update(repeating: 0, count: n) } }
                var sum: Float = 0
                var sound = false
                for i in 0..<n { let v = src[0][i]; sum += v * v; if v != 0 { sound = true } }
                self.echoGate?.roomLevel((sum / Float(max(n, 1))).squareRoot(), seconds: Double(n) / format.sampleRate)
                self.watchSilence(sound: sound)
            }
            if self.muted || self.echoGate?.closed() == true || channels == 0 || buf.floatChannelData == nil {
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

    // MARK: A microphone that delivers nothing

    /// Seconds of nothing but digital zeros after a start that make the mic count as silent. A real
    /// mic is never exactly zero, however quiet the room; a mic starved by another audio unit is.
    static let silentAfter = 5.0
    /// Debug (`roomMicSilent:on`): every block from the mic is zeros.
    nonisolated(unsafe) static var simulateSilence = false
    /// Called on the main queue when the mic stayed silent after being opened again.
    var onSilent: (() -> Void)?
    /// Per opening of the mic, on the audio thread: whether it has been silent since it started.
    private enum SilenceWatch { case waiting, silentSince(Date), settled }
    private var silence = SilenceWatch.waiting
    /// Opened again once already for silence (main queue): the next time it is reported instead.
    private var reopenedForSilence = false

    /// On the audio thread, per block: a mic silent since it started is opened again once, and
    /// reported (`onSilent`) when it is still silent after that.
    private func watchSilence(sound: Bool) {
        let since: Date
        switch silence {
        case .settled: return
        case .waiting: since = Date()
        case .silentSince(let d): since = d
        }
        if sound { silence = .settled; return }
        silence = .silentSince(since)
        guard Date().timeIntervalSince(since) >= Self.silentAfter else { return }
        silence = .settled
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            if !self.reopenedForSilence {
                self.reopenedForSilence = true
                self.startedAt = .distantPast
                self.restart("silent since it started")
            } else {
                debugLog("room mic: still silent after opening it again")
                self.onSilent?()
            }
        }
    }

    private var stopped = false

    func stop() {
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
