import AppKit
import AVFoundation
import CoreAudio
import CryptoKit
import Foundation
import Speech

/// Sets up the BlackHole 2ch virtual microphone without the Terminal, in three steps the UI
/// shows as a checklist: install → let the system load it → sound test.
///
/// Install: download the official, Apple-notarized package, verify its SHA-256, run it through
/// the standard administrator prompt. (Downloaded, not bundled: we don't redistribute the GPL
/// driver.) The package only copies the driver and asks for a reboot; Core Audio doesn't load a
/// new HAL plug-in until `coreaudiod` restarts, so the same prompt restarts it.
///
/// Test: speak a phrase into the virtual mic and listen back from its input side, so we know the
/// whole path the meeting app will use works — not just that a device with the name exists.
@MainActor
final class VirtualMicInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading
        case installing
        case reloading
        case testing
        case failed(String)
    }

    struct TestResult: Equatable {
        var heard: Bool
        var text: String
        var levels: [Float]
        /// Why nothing was heard, shown instead of the generic line.
        var problem: String? = nil
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var test: TestResult?
    /// Bumped after Core Audio restarts so views re-read the device list.
    @Published private(set) var generation = 0

    static let packageURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
    static let packageSHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
    static let testPhrase = "Hi, can you hear me?"

    /// Plays text through a given device; provided by the speak engine.
    var speakThrough: ((_ text: String, _ language: String, _ device: OutputDevice) async -> Void)?
    /// Called once Core Audio has the device (after an install or reload).
    var onLoaded: (() -> Void)?
    /// Tests swap in a session with a stub protocol.
    var session: URLSession = .shared

    var device: OutputDevice? { AudioDevices.virtualMic }
    var isLoaded: Bool { device != nil }
    /// Installed on disk; may not be loaded until Core Audio restarts.
    var isOnDisk: Bool { FileManager.default.fileExists(atPath: Self.driverPath) }
    var busy: Bool { [.downloading, .installing, .reloading, .testing].contains(state) }
    var passed: Bool { test?.heard == true }

    // Kept for existing callers.
    var isInstalled: Bool { isLoaded }

    /// The next thing to do, whatever state the Mac is in.
    func next() {
        if !isOnDisk && !isLoaded { install() } else if !isLoaded { reload() } else { runTest() }
    }

    /// `verifyOnly` stops after the download and checksum (used by tests).
    func install(verifyOnly: Bool = false, onInstalled: (() -> Void)? = nil) {
        guard !busy else { return }
        Task {
            guard let pkg = await download() else { return }
            if verifyOnly { state = .idle; return }
            state = .installing
            try? await Task.sleep(nanoseconds: 200_000_000) // let "安装中" show before the dialog
            let cmd = "/usr/sbin/installer -pkg " + shellQuote(pkg.path) + " -target / && " + Self.restartAudio
            guard runPrivileged(cmd, prompt: L("\(appDisplayName)要安装虚拟麦克风，让会议里的人听到你的翻译。")) else { return }
            state = .reloading
            await waitForDevice(onLoaded: onInstalled)
        }
    }

    /// The driver is on disk but Core Audio hasn't loaded it: restart Core Audio only.
    func reload() {
        guard !busy else { return }
        Task {
            state = .reloading
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard runPrivileged(Self.restartAudio, prompt: L("\(appDisplayName)要让系统认出虚拟麦克风，声音会断约 1 秒。")) else { return }
            await waitForDevice(onLoaded: nil)
        }
    }

    func runTest() {
        guard !busy, let device else { return }
        Task {
            state = .testing
            // Reading the virtual mic's input side is microphone access like any other.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                test = .init(heard: false, text: "", levels: [], problem: L("试音要用麦克风权限，请在系统设置里允许\(appDisplayName)"))
                state = .idle
                return
            }
            test = await LoopbackTest.run(device: device, phrase: Self.testPhrase) { [weak self] in
                await self?.speakThrough?(Self.testPhrase, "en", device)
            }
            debugLog("virtual mic test: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) heard=\(test?.heard ?? false) text=\(test?.text ?? "")")
            state = .idle
        }
    }

    // MARK: Steps

    // `launchctl kickstart` is the supported restart; killall is the fallback (launchd relaunches it).
    private static let restartAudio =
        "/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod"

    private func download() async -> URL? {
        state = .downloading
        do {
            let (tmp, response) = try await session.download(from: Self.packageURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failed(L("下载失败，请检查网络"))
                return nil
            }
            let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
            guard digest == Self.packageSHA256 else {
                debugLog("virtual mic: checksum mismatch \(digest)")
                state = .failed(L("安装包校验未通过，已中止安装"))
                return nil
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSubsMic", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent("BlackHole2ch.pkg")
            try? FileManager.default.removeItem(at: pkg)
            try FileManager.default.moveItem(at: tmp, to: pkg)
            debugLog("virtual mic: downloaded and verified \(pkg.path)")
            return pkg
        } catch {
            debugLog("virtual mic: download error \(error)")
            state = .failed(L("下载失败，请检查网络"))
            return nil
        }
    }

    /// Runs a shell command through the standard administrator prompt. Cancel goes back to idle.
    private func runPrivileged(_ command: String, prompt: String) -> Bool {
        let script = "do shell script \(appleQuote(command)) with prompt \(appleQuote(prompt)) with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return true }
        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        debugLog("virtual mic: privileged command error \(errorInfo)")
        state = code == -128 ? .idle : .failed(L("安装未完成，请再试一次"))
        return false
    }

    private func waitForDevice(onLoaded extra: (() -> Void)?) async {
        for _ in 0..<30 where !isLoaded {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        generation += 1
        guard isLoaded else {
            state = .failed(isOnDisk ? L("系统还没认出它，点“让系统认出它”再试一次") : L("安装未完成，请再试一次"))
            return
        }
        debugLog("virtual mic: loaded")
        state = .idle
        onLoaded?()
        extra?()
        // Core Audio just restarted; give it a moment before the test.
        try? await Task.sleep(nanoseconds: 800_000_000)
        runTest()
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Loopback test

/// Records the virtual mic's input side while a phrase is played into its output side, then
/// transcribes the recording. Hearing the phrase back proves the room will hear us.
enum LoopbackTest {
    @MainActor
    static func run(device: OutputDevice, phrase: String, play: @escaping () async -> Void) async -> VirtualMicInstaller.TestResult {
        let recorder = LoopbackRecorder()
        guard recorder.start(deviceID: device.id) else {
            return .init(heard: false, text: "", levels: [], problem: L("打不开虚拟麦克风，点“让系统认出它”后再试"))
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        await play()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let buffers = recorder.stop()
        debugLog("loopback: \(buffers.first?.frameLength ?? 0) frames")
        let levels = LoopbackRecorder.levels(buffers, bars: 12)
        let loud = (levels.max() ?? 0) > 0.02
        let text = loud ? await transcribe(buffers, locale: "en-US") : ""
        // Any real signal counts; the transcript is shown so people can judge it themselves.
        return .init(heard: loud, text: text, levels: levels,
                     problem: loud ? nil : buffers.isEmpty ? L("虚拟麦克风未收到声音，请再试一次") : nil)
    }

    static func transcribe(_ buffers: [AVAudioPCMBuffer], locale: String) async -> String {
        await Recognition.transcribe(buffers, locale: locale)?.text ?? ""
    }
}

/// Records one device's input side with a plain Core Audio IO proc. (An AVAudioEngine input
/// node switched to another device keeps the default mic's format and can stop itself on the
/// format change, which made the test flaky.)
final class LoopbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var device = AudioObjectID(0)
    private var proc: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48_000
    /// When the first recorded sample was captured (the first callback, minus its own length).
    private var firstAt: Date?
    var startedAt: Date? { lock.lock(); defer { lock.unlock() }; return firstAt }
    private let queue = DispatchQueue(label: "com.wquguru.cicada.loopback")

    func start(deviceID: AudioObjectID) -> Bool {
        device = deviceID
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr, rate > 0 { sampleRate = rate }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            let p = data.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            if self.firstAt == nil { self.firstAt = Date().addingTimeInterval(-Double(frames) / self.sampleRate) }
            for i in 0..<frames { self.samples.append(p[i * channels]) } // first channel is enough
            self.lock.unlock()
        }
        guard status == noErr, let proc else {
            debugLog("loopback: io proc failed \(status)")
            return false
        }
        let started = AudioDeviceStart(deviceID, proc)
        debugLog("loopback: recording device \(deviceID) at \(sampleRate) Hz, start=\(started)")
        return started == noErr
    }

    func stop() -> [AVAudioPCMBuffer] {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        lock.lock(); let all = samples; lock.unlock()
        guard !all.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count)) else { return [] }
        buf.frameLength = AVAudioFrameCount(all.count)
        all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
        return [buf]
    }

    /// Peak level per slice of the recording, 0…1, for the little bar graph.
    static func levels(_ buffers: [AVAudioPCMBuffer], bars: Int) -> [Float] {
        var samples: [Float] = []
        for b in buffers {
            guard let ch = b.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength)))
        }
        guard !samples.isEmpty else { return [] }
        let slice = max(1, samples.count / bars)
        return stride(from: 0, to: samples.count, by: slice).prefix(bars).map { start in
            let end = min(samples.count, start + slice)
            return min(1, samples[start..<end].reduce(0) { max($0, abs($1)) })
        }
    }
}
