// Core Audio from the shell, for room tests (macOS has no command for these):
//   audio list                 devices, the default input and output, each input's level
//   audio out <name part>      make it the default output (and the system output)
//   audio level <name part> <0-1>   an input's level (the MacBook mic's)
// Build: swiftc -O audio.swift -o audio (round.sh does it once into the work folder).
import CoreAudio
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
}

func name(_ d: AudioObjectID) -> String {
    var a = address(kAudioObjectPropertyName)
    var s: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &size, &s)
    return s as String
}

func devices() -> [AudioObjectID] {
    var a = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)
    return ids
}

func current(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var a = address(selector)
    var d = AudioObjectID(0)
    var size = UInt32(4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &d)
    return d
}

func inputLevel(_ d: AudioObjectID) -> Float32? {
    var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
    var v: Float32 = 0
    var size = UInt32(4)
    return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func find(_ part: String) -> AudioObjectID? { devices().first { name($0).contains(part) } }

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "out":
    guard let part = args.dropFirst().first, var d = find(part) else { print("no such device"); exit(1) }
    for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
        var a = address(sel)
        AudioObjectSetPropertyData(system, &a, 0, nil, 4, &d)
    }
    print("output: \(name(current(kAudioHardwarePropertyDefaultOutputDevice)))")
case "level":
    let rest = Array(args.dropFirst())
    guard rest.count == 2, let d = find(rest[0]), var v = Float32(rest[1]) else { print("audio level <name part> <0-1>"); exit(1) }
    var a = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
    AudioObjectSetPropertyData(d, &a, 0, nil, 4, &v)
    print("\(name(d)) input level \(inputLevel(d) ?? -1)")
default:
    print("output: \(name(current(kAudioHardwarePropertyDefaultOutputDevice)))")
    print("input:  \(name(current(kAudioHardwarePropertyDefaultInputDevice)))")
    for d in devices() {
        if let v = inputLevel(d) { print("  \(name(d)): input level \(v)") }
    }
}
