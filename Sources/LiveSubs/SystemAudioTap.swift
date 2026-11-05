import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Speech

// MARK: - System audio tap

/// Captures the audio that is currently going to the default output device.
/// This uses Core Audio process taps, so it only needs the "System Audio
/// Recording" privacy grant and never asks for Screen Recording.
/// Whether 系统音频录制 was allowed. Refused, the tap still starts and hears only silence, so
/// starting proves nothing; TCC's own preflight is the one way to tell (loaded at run time; nil
/// when it isn't there, and then starting is taken as allowed, as before).
enum SystemAudioPermission {
    enum Status { case granted, denied, unknown }

    static func status() -> Status? {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY),
              let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        switch unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }
}

final class SystemAudioTap {
    /// Called on the real-time audio thread. Must not block.
    var onAudio: ((AVAudioPCMBuffer) -> Void)?

    private var audioUnit: AudioUnit?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var clientFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        if status != noErr || device == kAudioObjectUnknown { return nil }
        return device
    }

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// How many input channels a device has: a headset, AirPods or a virtual machine's sound
    /// device has a microphone on the same device as its speakers.
    static func inputChannels(_ device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func defaultOutputUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        if status != noErr { return nil }
        return uid as String
    }

    private func fail(_ code: Int, _ message: String) -> NSError {
        stop()
        return NSError(domain: "LiveSubsAudio", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func start() throws {
        stop()

        // Exclude our own process so the app's spoken translations never
        // come back in as subtitles.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        desc.name = "Cicada"
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw fail(Int(status), L("无法创建系统音频 Tap（\(status)）")) }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else { throw fail(-1, L("找不到默认输出设备")) }

        let aggregateUID = "com.wquguru.cicada.\(UUID().uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cicada Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw fail(Int(status), L("无法创建音频聚合设备（\(status)）")) }
        self.aggregateID = aggregateID

        var component = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let found = AudioComponentFindNext(nil, &component) else { throw fail(-2, L("找不到 HAL 音频组件")) }
        var unit: AudioUnit?
        status = AudioComponentInstanceNew(found, &unit)
        guard status == noErr, let unit else { throw fail(Int(status), L("无法创建音频单元（\(status)）")) }
        audioUnit = unit

        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                             &disableOutput, UInt32(MemoryLayout<UInt32>.size))
        var enableInput: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                             &enableInput, UInt32(MemoryLayout<UInt32>.size))

        var device = aggregateID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                      &device, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else { throw fail(Int(status), L("无法连接音频聚合设备（\(status)）")) }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let clientFormat = AVAudioFormat(streamDescription: &asbd) else { throw fail(-3, L("无法创建音频格式")) }
        self.clientFormat = clientFormat
        self.monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        // Pre-allocate so the real-time callback normally doesn't allocate.
        self.renderBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: 4096)

        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                      &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw fail(Int(status), L("无法设置音频格式（\(status)）")) }

        // The aggregate's inputs are the output device's own inputs first, then the tap. When the
        // output device has a microphone (a headset, AirPods, a virtual machine's sound device),
        // the first two channels are that microphone, not what the Mac plays: skip past them.
        let mics = Self.defaultOutputDevice().map(Self.inputChannels) ?? 0
        if mics > 0 {
            var map: [Int32] = [Int32(mics), Int32(mics + 1)]
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                          &map, UInt32(MemoryLayout<Int32>.size * map.count))
            debugLog("audio tap: output device has \(mics) input channels, reading the tap from channel \(mics) (\(status))")
        }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, timestamp, bus, frames, _ in
                let tap = Unmanaged<SystemAudioTap>.fromOpaque(refCon).takeUnretainedValue()
                return tap.render(timestamp: timestamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                      &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw fail(Int(status), L("无法设置音频回调（\(status)）")) }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { throw fail(Int(status), L("无法初始化音频单元（\(status)）")) }
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw fail(Int(status), L("无法启动音频采集（\(status)）")) }
    }

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit = audioUnit, let clientFormat else { return noErr }
        var pcm = renderBuffer
        if pcm == nil || pcm!.frameCapacity < frames {
            pcm = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: frames)
            renderBuffer = pcm
        }
        guard let pcm else { return noErr }
        pcm.frameLength = frames
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, timestamp, bus, frames, pcm.mutableAudioBufferList)
        guard status == noErr else { return status }

        guard let monoFormat, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let src = pcm.floatChannelData, let dst = mono.floatChannelData else {
            return noErr
        }
        mono.frameLength = frames
        let n = Int(frames)
        if pcm.format.channelCount >= 2 {
            for i in 0..<n {
                dst[0][i] = (src[0][i] + src[1][i]) * 0.5
            }
        } else {
            memcpy(dst[0], src[0], n * MemoryLayout<Float>.size)
        }
        onAudio?(mono)
        return noErr
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = kAudioObjectUnknown
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        clientFormat = nil
        monoFormat = nil
        renderBuffer = nil
    }

    deinit { stop() }
}

