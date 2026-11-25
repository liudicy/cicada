import AVFoundation
import CoreAudio
import Foundation

/// Input side of `AudioDevices`: the devices that can record, and the system default input.
extension AudioDevices {
    /// The microphones, without what macOS adds while an echo-cancelling unit runs here.
    static func inputs() -> [OutputDevice] {
        devices(scope: kAudioObjectPropertyScopeInput).filter {
            !$0.uid.hasPrefix("VPAUAggregateAudioDevice") && !isEchoReference($0.id)
        }
    }

    /// While this process holds an echo-cancelling unit (同声传译, 记录我的发言), macOS gives the speakers
    /// an input of their own (what they play, for the canceller to subtract) and lists a private
    /// aggregate: neither hears the room, and the speakers would sit in the menu as a microphone.
    /// That input is on the output the canceller plays to and has no terminal type; a real
    /// microphone's says it is one.
    static func isEchoReference(_ device: AudioObjectID) -> Bool {
        // A headset is one device for its mic and its earpiece: its mic stays, whatever it reports.
        let t = transport(device)
        guard device == SystemAudioTap.defaultOutputDevice(),
              t != kAudioDeviceTransportTypeBluetooth, t != kAudioDeviceTransportTypeBluetoothLE else { return false }
        func streams(_ scope: AudioObjectPropertyScope) -> [AudioStreamID] {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr else { return [] }
            return ids
        }
        let inputs = streams(kAudioObjectPropertyScopeInput)
        guard !inputs.isEmpty, !streams(kAudioObjectPropertyScopeOutput).isEmpty else { return false }
        return inputs.allSatisfy { id in
            var type: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyTerminalType,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type)
            return type == kAudioStreamTerminalTypeUnknown
        }
    }

    static var defaultInput: OutputDevice? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return inputs().first { $0.id == id }
    }

    /// Points an engine's input at a device. Call while the engine is stopped and before reading the
    /// input format, which then follows the device. nil leaves it where it is.
    static func pinInput(_ engine: AVAudioEngine, to device: OutputDevice?) {
        guard let device, let unit = engine.inputNode.audioUnit else { return }
        var cur = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &size)
        guard cur != device.id else { return }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioObjectID>.size))
        debugLog("mic: recording from \(device.name) status=\(status)")
    }

    /// The device an engine's input is reading now (for the debug log).
    static func inputDevice(of engine: AVAudioEngine) -> String {
        guard let unit = engine.inputNode.audioUnit else { return "-" }
        var cur = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &size)
        return name(cur) ?? "\(cur)"
    }

    @discardableResult
    static func setDefaultInput(_ device: OutputDevice) -> Bool {
        var id = device.id
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &id)
        if status != noErr { debugLog("system mic: set default input \(device.name) failed \(status)") }
        return status == noErr
    }
}

/// Which real microphone to come back to and which one Cicada records from. Pure, so it's tested.
/// Devices are compared by UID: IDs change when Core Audio restarts (the BlackHole install does).
enum SystemMicPlan {
    struct Device: Equatable {
        var uid: String
        var isVirtual: Bool
    }

    /// The microphone to put back when we let go of the system default. The one saved when we
    /// switched, while it's still plugged in; else the current default if it's real (the user
    /// already chose it); else the first real one. Never a virtual mic: putting BlackHole "back"
    /// would leave every other app deaf.
    static func original(saved: String, current: String?, inputs: [Device]) -> String? {
        let real = inputs.filter { !$0.isVirtual }
        if real.contains(where: { $0.uid == saved }) { return saved }
        if let current, real.contains(where: { $0.uid == current }) { return current }
        return real.first?.uid
    }

    /// What Cicada itself records from: the one picked in settings, else the original. Cicada must
    /// never follow the system default onto the virtual mic, or it would hear its own voice.
    static func recording(chosen: String, saved: String, current: String?, inputs: [Device]) -> String? {
        if inputs.contains(where: { $0.uid == chosen && !$0.isVirtual }) { return chosen }
        return original(saved: saved, current: current, inputs: inputs)
    }
}

/// Points the system default input at the virtual mic while 同声传译 is on, so a meeting page in
/// Chrome (and any app left on "default") hears the translation without being set up, and puts it
/// back when speaking stops or Cicada quits. The device we switched from is saved in settings so
/// a crash can be undone on the next launch.
@MainActor
final class SystemMic {
    enum State: Equatable {
        /// Not switched, nothing to undo.
        case off
        /// The system mic is the virtual mic; `original` comes back when speaking stops.
        case switched(original: String)
        /// Speaking is off but the system mic is still the virtual mic (Cicada quit uncleanly).
        case notRestored(original: String)
        /// Speaking is on but something else (AirPods, the user) moved the system mic away.
        case moved(to: String)
    }

    let settings: AppSettings
    private(set) var state: State = .off

    init(settings: AppSettings) { self.settings = settings }

    private var plan: [SystemMicPlan.Device] {
        AudioDevices.inputs().map { .init(uid: $0.uid, isVirtual: $0.isVirtualMic) }
    }

    private func device(_ uid: String?) -> OutputDevice? {
        guard let uid else { return nil }
        return AudioDevices.inputs().first { $0.uid == uid }
    }

    /// The device Cicada records my voice from; nil leaves the engine on the system default.
    var recordingDevice: OutputDevice? {
        device(SystemMicPlan.recording(chosen: settings.speakMic, saved: settings.savedSystemInput,
                                       current: AudioDevices.defaultInput?.uid, inputs: plan))
    }

    /// Real microphones for the settings menu.
    var realInputs: [OutputDevice] { AudioDevices.inputs().filter { !$0.isVirtualMic } }

    /// Makes the virtual mic the system default, remembering the real one it replaces.
    /// `wanted` is false when switching makes no sense (feature off, voice sent elsewhere).
    func engage(wanted: Bool) {
        guard wanted else { release(); return }
        guard let virtual = AudioDevices.inputs().first(where: \.isVirtualMic) else { refresh(wanted: wanted); return }
        let current = AudioDevices.defaultInput
        // Keep a save left over from a crash: by now the default is the virtual mic.
        if settings.savedSystemInput.isEmpty || device(settings.savedSystemInput) == nil,
           let original = SystemMicPlan.original(saved: settings.savedSystemInput, current: current?.uid, inputs: plan) {
            settings.savedSystemInput = original
        }
        if current?.uid != virtual.uid {
            AudioDevices.setDefaultInput(virtual)
            debugLog("system mic: \(current?.name ?? "-") → \(virtual.name), will restore \(device(settings.savedSystemInput)?.name ?? "-")")
        }
        refresh(wanted: wanted)
    }

    /// Puts the saved real microphone back, if the system default is still the virtual mic.
    func release() {
        let current = AudioDevices.defaultInput
        if current?.isVirtualMic ?? false,
           let back = device(SystemMicPlan.original(saved: settings.savedSystemInput, current: nil, inputs: plan)) {
            AudioDevices.setDefaultInput(back)
            debugLog("system mic: restored \(back.name)")
        }
        if !settings.savedSystemInput.isEmpty { settings.savedSystemInput = "" }
        state = .off
    }

    /// Re-reads the system default (polled): spots a crash left over or a device that took over.
    @discardableResult
    func refresh(wanted: Bool) -> State {
        let saved = settings.savedSystemInput
        let current = AudioDevices.defaultInput
        let originalName = device(SystemMicPlan.original(saved: saved, current: nil, inputs: plan))?.name ?? ""
        let next: State
        if saved.isEmpty {
            next = .off
        } else if current?.isVirtualMic ?? false {
            next = wanted ? .switched(original: originalName) : .notRestored(original: originalName)
        } else if wanted {
            next = .moved(to: current?.name ?? "")
        } else {
            // Someone already put a real mic back: nothing left to undo.
            settings.savedSystemInput = ""
            next = .off
        }
        state = next
        return next
    }
}
