import AppKit
import CryptoKit

/// Installs an update in place: downloads the release zip, checks it against checksums.txt,
/// unpacks it, then hands off to a small shell script that swaps the app bundle once the app
/// has quit and relaunches it. URLSession downloads carry no quarantine, so the new (ad-hoc
/// signed) app opens without a Gatekeeper prompt; its designated requirement is the bundle id,
/// so the system-audio and microphone permissions carry over.
@MainActor
enum Updater {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Reports download progress (0...1) on the way; returns only if installing failed.
    /// The caller has already ended the meeting: quitting must not stop to ask.
    static func install(_ update: UpdateChecker.Update, progress: @escaping (Double) -> Void) async throws {
        guard let zipURL = update.zip, let checksumsURL = update.checksums else {
            throw Failure(L("这个版本没有可安装的文件"))
        }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure(L("请先把应用拖进“应用程序”文件夹"))
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("CicadaUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let zip = work.appendingPathComponent(zipURL.lastPathComponent)
            try await download(zipURL, to: zip, progress: progress)
            let (checksums, _) = try await URLSession.shared.data(from: checksumsURL)
            guard let expected = expectedHash(of: zip.lastPathComponent, in: checksums),
                  try await sha256(of: zip) == expected else {
                throw Failure(L("下载的文件校验不通过"))
            }

            let unpacked = work.appendingPathComponent("unpacked")
            try await run("/usr/bin/ditto", "-x", "-k", zip.path, unpacked.path)
            // The zip root is "Cicada.app" upstream but "Cicada MOD.app" on the fork's packages;
            // a missing app falls through to the version check below, which reports the failure.
            let newApp = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) ?? unpacked.appendingPathComponent("Cicada.app")
            let info = Bundle(url: newApp)?.infoDictionary
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  info?["CFBundleShortVersionString"] as? String == update.version else {
                throw Failure(L("下载的不是预期的版本"))
            }
            // A later version may need a newer macOS than this Mac has: swapped in, it wouldn't open.
            if let minimum = info?["LSMinimumSystemVersion"] as? String, !Self.runs(minimum) {
                throw Failure(L("新版本需要 macOS \(minimum) 或更新版本"))
            }
            try await run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)

            let script = work.appendingPathComponent("swap.sh")
            try swapScript.write(to: script, atomically: true, encoding: .utf8)
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = [script.path, String(getpid()), app.path, newApp.path, work.path]
            try swap.run()
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        NSApp.terminate(nil)
    }

    /// Waits for the app to quit, moves the old bundle aside (restoring it if the new one can't be
    /// moved in), relaunches, and cleans up. Arguments: pid, app path, new app path, work folder.
    private static let swapScript = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$4/old.app"; then
          if mv "$3" "$2"; then rm -rf "$4/old.app"; else mv "$4/old.app" "$2"; fi
        fi
        open "$2"
        rm -rf "$4"
        """

    /// Whether this Mac's macOS is at least `minimum` ("14.4").
    nonisolated static func runs(_ minimum: String,
                                 on os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        let p = minimum.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return (os.majorVersion, os.minorVersion, os.patchVersion) >= (p[0], p[1], p[2])
    }

    /// The hash listed for `name` in a `shasum -a 256` file.
    nonisolated static func expectedHash(of name: String, in checksums: Data) -> String? {
        String(decoding: checksums, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .first { $0.count == 2 && $0[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name }
            .map { $0[0].lowercased() }
    }

    private static func download(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    return done.resume(throwing: Failure(L("下载失败（HTTP \(status)）")))
                }
                guard let file else { return done.resume(throwing: error ?? Failure(L("下载失败"))) }
                // The temporary file is deleted when this handler returns, so move it now.
                do { try FileManager.default.moveItem(at: file, to: destination); done.resume() }
                catch { done.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let fraction = p.fractionCompleted
                Task { @MainActor in progress(fraction) }
            }
            task.resume()
        }
    }

    private static func sha256(of file: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private static func run(_ tool: String, _ arguments: String...) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                p.terminationStatus == 0 ? done.resume() : done.resume(throwing: Failure(L("更新包无效")))
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }
}
