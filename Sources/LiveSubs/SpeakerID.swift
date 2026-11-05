import Accelerate
import AVFoundation
import CoreML
import Combine
import Foundation

// 说话人识别: telling the other side's voices apart (设置 › 通用). Each heard line's
// audio becomes a voiceprint (WeSpeaker ResNet34-LM, VoxCeleb, CC BY 4.0, bundled as Core ML),
// voiceprints are grouped as they arrive, and a voice is only named once it has a few lines. The
// thresholds were tuned on AMI meetings; the model comes from `scripts/convert-voiceprint.py`.

/// Kaldi log-mel filterbank, as `torchaudio.compliance.kaldi.fbank` computes it with the defaults the
/// model was trained on: 16 kHz, 25 ms Povey windows every 10 ms, DC removed, pre-emphasis 0.97,
/// 512-point power spectrum, 80 mel bins from 20 Hz to 8 kHz, natural log.
enum Fbank {
    static let bins = 80
    static let frameLength = 400
    static let shift = 160
    private static let fftSize = 512

    private static let window: [Float] = (0..<frameLength).map {
        pow(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frameLength - 1)), 0.85)
    }

    /// `bins` rows of `fftSize / 2 + 1` weights (the Nyquist column is always zero, as in Kaldi).
    private static let melBanks: [Float] = {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let cols = fftSize / 2 + 1
        let lo = mel(20), hi = mel(8000), delta = (hi - lo) / Double(bins + 1)
        var w = [Float](repeating: 0, count: bins * cols)
        for m in 0..<bins {
            let left = lo + Double(m) * delta, center = left + delta, right = center + delta
            for k in 0..<(fftSize / 2) {
                let x = mel(Double(k) * 16000 / Double(fftSize))
                let v = min((x - left) / (center - left), (right - x) / (right - center))
                if v > 0 { w[m * cols + k] = Float(v) }
            }
        }
        return w
    }()

    private static let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!

    /// Frames × `bins`, row-major. `samples` are 16 kHz mono in -1...1.
    static func compute(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        let frames = 1 + (samples.count - frameLength) / shift
        let cols = fftSize / 2 + 1
        var out = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: fftSize / 2), im = re
        var power = [Float](repeating: 0, count: cols)
        var mels = [Float](repeating: 0, count: bins)
        for f in 0..<frames {
            let start = f * shift
            for i in 0..<frameLength { frame[i] = samples[start + i] * 32768 }
            for i in frameLength..<fftSize { frame[i] = 0 }
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            for i in 0..<frameLength { frame[i] -= mean }
            for i in stride(from: frameLength - 1, to: 0, by: -1) { frame[i] -= 0.97 * frame[i - 1] }
            frame[0] -= 0.97 * frame[0]
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameLength))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            // vDSP's real FFT returns twice the true values, Nyquist packed into im[0].
            power[0] = re[0] * re[0] / 4
            power[cols - 1] = im[0] * im[0] / 4
            for k in 1..<(fftSize / 2) { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
            vDSP_mmul(melBanks, 1, power, 1, &mels, 1, vDSP_Length(bins), 1, vDSP_Length(cols))
            for b in 0..<bins { out[f * bins + b] = log(max(mels[b], .ulpOfOne)) }
        }
        return out
    }
}

/// The bundled voiceprint model. Command Line Tools can't compile Core ML models, so the
/// `.mlpackage` is compiled on first use and the result kept in Application Support.
final class Voiceprints: @unchecked Sendable {
    static let minSeconds = 0.5
    /// Longer lines are cut: 20 s is plenty to know a voice and bounds the work.
    static let maxSeconds = 20.0

    private let model: MLModel

    private init(model: MLModel) { self.model = model }

    static func load() throws -> Voiceprints {
        guard let pkg = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlpackage") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: pkg.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin").path)[.size] as? Int) ?? 0
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder).appendingPathComponent("SpeakerEmbedding-\(size).mlmodelc")
        if !FileManager.default.fileExists(atPath: cache.path) {
            let compiled = try MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: cache)
            try FileManager.default.moveItem(at: compiled, to: cache)
        }
        let config = MLModelConfiguration()
        // Variable-length input doesn't compile for the Neural Engine; the GPU path is quick enough.
        config.computeUnits = .cpuAndGPU
        return Voiceprints(model: try MLModel(contentsOf: cache, configuration: config))
    }

    /// A whole audio file as 16 kHz mono floats (debug and tests).
    static func samples(of url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let out = PCMConverter().convert(input, to: format), let d = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
    }

    /// A unit-length 256-d voiceprint for 16 kHz mono samples, or nil when too short.
    func embed(_ samples: [Float]) -> [Float]? {
        guard Double(samples.count) >= Self.minSeconds * 16000 else { return nil }
        let clip = samples.count > Int(Self.maxSeconds * 16000) ? Array(samples.prefix(Int(Self.maxSeconds * 16000))) : samples
        var feats = Fbank.compute(clip)
        let frames = feats.count / Fbank.bins
        guard frames >= 50 else { return nil }
        // Mean normalisation per bin over the clip, as in training.
        for b in 0..<Fbank.bins {
            var sum: Float = 0
            for f in 0..<frames { sum += feats[f * Fbank.bins + b] }
            let mean = sum / Float(frames)
            for f in 0..<frames { feats[f * Fbank.bins + b] -= mean }
        }
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: Fbank.bins)], dataType: .float32) else { return nil }
        feats.withUnsafeBufferPointer { src in
            input.withUnsafeMutableBytes { dst, _ in
                dst.copyMemory(from: UnsafeRawBufferPointer(src))
            }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": input])),
              let embs = out.featureValue(for: "embs")?.multiArrayValue else { return nil }
        var v = (0..<embs.count).map { Float(truncating: embs[$0]) }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        guard norm > 0 else { return nil }
        vDSP_vsdiv(v, 1, [norm.squareRoot()], &v, 1, vDSP_Length(v.count))
        return v
    }
}

/// Groups voiceprints as lines arrive, never revising a line already labelled. A line joins the
/// closest voice when similar enough; a long line unlike every voice starts a new one; anything
/// else stays unlabelled ("对方"). Tuned on AMI dev meetings.
struct VoiceClusterer {
    static let newSeconds = 2.0
    static let join: Float = 0.5
    static let startNew: Float = 0.5

    private(set) var sums: [[Float]] = []

    /// The user said two voices are one: later lines like either go to `into`.
    mutating func merge(_ from: Int, into: Int) {
        guard sums.indices.contains(from), sums.indices.contains(into), from != into else { return }
        vDSP_vadd(sums[into], 1, sums[from], 1, &sums[into], 1, vDSP_Length(sums[into].count))
        sums[from] = [Float](repeating: 0, count: sums[from].count)   // never the closest again
    }

    mutating func label(_ v: [Float], seconds: Double) -> Int? {
        var best = -1, bestSim: Float = -1
        for (i, s) in sums.enumerated() {
            var dot: Float = 0, sq: Float = 0
            vDSP_dotpr(v, 1, s, 1, &dot, vDSP_Length(v.count))
            vDSP_svesq(s, 1, &sq, vDSP_Length(s.count))
            let sim = dot / max(sq.squareRoot(), .ulpOfOne)
            if sim > bestSim { bestSim = sim; best = i }
        }
        if best >= 0, bestSim >= Self.join {
            vDSP_vadd(sums[best], 1, v, 1, &sums[best], 1, vDSP_Length(v.count))
            return best
        }
        if seconds >= Self.newSeconds, sums.isEmpty || bestSim < Self.startNew {
            sums.append(v)
            return sums.count - 1
        }
        return nil
    }
}

/// What the transcript shows for the other side's lines. A voice gets a number only once it has
/// `shownAfter` lines, and only when at least two voices have, so a one-to-one call stays "对方".
/// Numbers follow the order voices reached `shownAfter` lines, so a number never moves once shown.
enum SpeakerLabels {
    static let shownAfter = 5

    /// A line long enough to say whose voice it is: three words, or four characters of Chinese or
    /// Japanese. "Yeah." or a stray "." can make a group of their own; they don't count towards a name.
    static func substantive(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }
        if words.count >= 3 { return true }
        return text.unicodeScalars.filter { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }.count >= 4
    }

    /// Voice id → 1-based speaker number, for the voices on show.
    static func voiceNumbers(_ lines: [TranscriptLine]) -> [Int: Int] {
        var count: [Int: Int] = [:], reached: [Int: Int] = [:]
        for (i, l) in lines.enumerated() where l.speaker == "them" {
            guard let v = l.voice, substantive(l.src) else { continue }
            count[v, default: 0] += 1
            if count[v] == shownAfter { reached[v] = i }
        }
        let shown = reached.keys.sorted { reached[$0]! < reached[$1]! }
        guard shown.count >= 2 else { return [:] }
        return Dictionary(uniqueKeysWithValues: shown.enumerated().map { ($1, $0 + 1) })
    }

    /// Line id → 1-based speaker number; lines without one show as 对方.
    static func numbers(_ lines: [TranscriptLine]) -> [String: Int] {
        let number = voiceNumbers(lines)
        var out: [String: Int] = [:]
        for l in lines where l.speaker == "them" {
            if let v = l.voice, let n = number[v] { out[l.id] = n }
        }
        return out
    }

    /// Speaker number → name: the user's, else Ling's guess (unless the user turned it down).
    static func names(_ s: Session) -> [Int: String] {
        guard s.voiceNames != nil || s.voiceGuesses != nil else { return [:] }
        var out: [Int: String] = [:]
        for (v, n) in voiceNumbers(s.lines) {
            if let mine = s.voiceNames?[String(v)] {
                if !mine.isEmpty { out[n] = mine }
            } else if let g = s.voiceGuesses?[String(v)] {
                out[n] = g.name
            }
        }
        return out
    }

    /// Speaker number → Ling's guess, for the voices whose shown name is that guess.
    static func guessed(_ s: Session) -> [Int: VoiceGuess] {
        var out: [Int: VoiceGuess] = [:]
        for (v, n) in voiceNumbers(s.lines) where s.voiceNames?[String(v)] == nil {
            if let g = s.voiceGuesses?[String(v)] { out[n] = g }
        }
        return out
    }

    /// Lines where the speaker changes: the transcript shows the name there only, as chat apps do.
    /// Keys: 你, a speaker number, or 未识别 (a voice not on show).
    static func runStarts(_ lines: [TranscriptLine], _ numbers: [String: Int]) -> Set<String> {
        var out: Set<String> = [], last: String?
        for l in lines {
            let key = l.speaker == "me" ? "me" : numbers[l.id].map { "n\($0)" } ?? "?"
            if key != last { out.insert(l.id) }
            last = key
        }
        return out
    }

    /// "George", else "说话人 2".
    static func label(_ number: Int, _ names: [Int: String]) -> String { names[number] ?? L("说话人 \(number)") }

    /// The notes as shown: Ling wrote "说话人 6" before anyone named them; show the name since given.
    static func named(_ notes: MeetingNotes, _ names: [Int: String]) -> MeetingNotes {
        guard !names.isEmpty else { return notes }
        func swap(_ text: String) -> String {
            guard text.contains("说话人") || text.contains("Speaker") else { return text }
            var out = text
            for (n, name) in names.sorted(by: { $0.key > $1.key }) {   // 说话人 12 before 说话人 1
                for form in ["说话人 \(n)", "说话人\(n)", "Speaker \(n)"] { out = out.replacingOccurrences(of: form, with: name) }
            }
            return out
        }
        var n = notes
        n.summary = swap(n.summary)
        n.topics = n.topics.map { t in var t = t; t.title = swap(t.title); t.summary = swap(t.summary); t.points = t.points.map(swap); return t }
        n.conclusions = n.conclusions.map { var i = $0; i.text = swap(i.text); i.owner = i.owner.map(swap); return i }
        n.todos = n.todos.map { var i = $0; i.text = swap(i.text); i.owner = i.owner.map(swap); return i }
        return n
    }

    /// Distinct voices on show, for the people row.
    static func shownCount(_ lines: [TranscriptLine]) -> Int { Set(numbers(lines).values).count }
}

/// Runs voiceprints off the main thread and hands back a voice per line, in arrival order.
@MainActor
final class SpeakerTagger {
    private let queue = DispatchQueue(label: "com.wquguru.cicada.voiceprint", qos: .utility)
    private nonisolated(unsafe) var model: Voiceprints?
    private nonisolated(unsafe) var loadFailed = false
    private nonisolated(unsafe) var clusterer = VoiceClusterer()
    var onVoice: ((_ lineID: String, _ voice: Int) -> Void)?

    /// A new meeting: forget the voices of the last one.
    func reset() { queue.async { [self] in clusterer = VoiceClusterer() } }

    func merge(_ from: Int, into: Int) { queue.async { [self] in clusterer.merge(from, into: into) } }

    func tag(lineID: String, samples: [Float]) {
        voice(of: samples) { [weak self] voice in
            if let voice { self?.onVoice?(lineID, voice) }
        }
    }

    /// The voice of a line not recorded yet; nil when unsure. Like `tag`, it counts towards that voice.
    func voice(of samples: [Float], _ done: @escaping @MainActor (Int?) -> Void) {
        let seconds = Double(samples.count) / 16000
        queue.async { [self] in
            if model == nil, !loadFailed {
                do { model = try Voiceprints.load() } catch {
                    loadFailed = true
                    debugLog("voiceprint model failed to load: \(error)")
                }
            }
            let voice = model.flatMap { $0.embed(samples) }.flatMap { clusterer.label($0, seconds: seconds) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(voice) } }
        }
    }
}

// MARK: - Names from the conversation

/// Asks Ling who 说话人 1, 2… are, from how people address each other. Only text is sent; a guess is
/// a suggestion the user takes or ignores, never applied by itself.
enum SpeakerNameGuess {
    /// The transcript as Ling sees it, newest 400 lines, with speaker labels; nil when no voices are shown.
    static func content(_ s: Session) -> String? {
        let numbers = SpeakerLabels.numbers(s.lines)
        guard !numbers.isEmpty else { return nil }
        let lines = s.lines.suffix(400)
        var out = "Meeting transcript. Speakers: 你 = the user; 说话人N = one person on the other side, told apart by voice; 对方 = someone on the other side, not identified.\n"
        for (i, l) in lines.enumerated() {
            let who = l.speaker == "me" ? "你" : numbers[l.id].map { "说话人\($0)" } ?? "对方"
            out += "[L\(i + 1) \(TranscriptExport.clock(l.t)) \(who)] \(l.src)\n"
        }
        return out
    }

    static let instruction = """
    Who are the people labelled 说话人N? Name one only when the transcript makes it clear: they \
    introduce themselves on a line labelled with their own 说话人N; someone addresses them by name just \
    before or after they speak ("Thanks, George" right after 说话人1's answer: 说话人1 is George); \
    or others name them as they speak. A name on a 对方 line, or far from any line of 说话人N (an advert, \
    a clip, people introducing themselves on another show), is not theirs. Speech recognition writes \
    names by ear and often misspells them: for a public figure (an official, an executive, a presenter) \
    recognisable from the name and what is said, write the name as the news spells it ("Jensen Hwang" \
    → "Jensen Huang"); otherwise as written. Leave out anyone \
    you are unsure of. Reply as JSON: {"speakers": [{"speaker": 2, "name": "George", "evidence": "L12"}]}, \
    the evidence being the line with the name; an empty list if none. Check each name's spelling before replying.
    """

    /// Voice id → guess, with the evidence line quoted ("03:21 “Thanks, George”"). A name Ling gives
    /// two voices goes to the one with more lines: two people rarely share a name in one meeting.
    static func parse(_ reply: String, _ s: Session) -> [Int: VoiceGuess] { read(reply, s).found }

    /// How far from the evidence line the named voice may speak: "Okay, Amos, thank you" comes
    /// right after Amos's last words.
    static let evidenceReach = 2

    /// `refuted`: voices Ling named on a line they neither said nor spoke next to ("I'm Christina"
    /// in an advert, given to the anchor); such a name is dropped, and an earlier copy of it too.
    static func read(_ reply: String, _ s: Session) -> (found: [Int: VoiceGuess], refuted: [Int: String]) {
        guard let data = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["speakers"] as? [[String: Any]] else { return ([:], [:]) }
        let voiceOf = Dictionary(uniqueKeysWithValues: SpeakerLabels.voiceNumbers(s.lines).map { ($1, $0) })
        let lines = Array(s.lines.suffix(400))
        func count(_ v: Int) -> Int { s.lines.filter { $0.voice == v }.count }
        var out: [Int: VoiceGuess] = [:], refuted: [Int: String] = [:]
        for item in list {
            guard let n = (item["speaker"] as? Int) ?? Int("\(item["speaker"] ?? "")"), let v = voiceOf[n],
                  let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 40 else { continue }
            // "L52" or "L52, L53": the first line named.
            let e = (item["evidence"] as? String) ?? "\(item["evidence"] ?? "")"
            guard let i = Int(String(e.drop(while: { !$0.isNumber }).prefix(while: \.isNumber))).map({ $0 - 1 }),
                  lines.indices.contains(i),
                  lines[max(0, i - evidenceReach)...min(lines.count - 1, i + evidenceReach)]
                      .contains(where: { $0.speaker == "them" && $0.voice == v }) else {
                refuted[v] = name
                continue
            }
            if let other = out.first(where: { $0.value.name == name })?.key {
                if count(other) >= count(v) { continue }
                out[other] = nil
            }
            let l = lines[i]
            let evidence = "\(TranscriptExport.clock(l.t)) “\(l.src.count > 60 ? String(l.src.prefix(60)) + "…" : l.src)”"
            out[v] = VoiceGuess(name: name, evidence: evidence)
        }
        return (out, refuted)
    }

    /// Whether a stored guess still stands by the same rule (guesses from before it was checked): its
    /// evidence ("04:41 “I'm Christina…”") is found again and the voice speaks there. Kept when not found.
    static func holds(_ g: VoiceGuess, voice v: Int, in s: Session) -> Bool {
        guard let open = g.evidence.firstIndex(of: "“") else { return true }
        let clock = g.evidence[..<open].trimmingCharacters(in: .whitespaces)
        let quote = String(g.evidence[g.evidence.index(after: open)...].dropLast().prefix(while: { $0 != "…" }))
        guard let i = s.lines.firstIndex(where: { TranscriptExport.clock($0.t) == clock && $0.src.hasPrefix(quote) }) else { return true }
        return s.lines[max(0, i - evidenceReach)...min(s.lines.count - 1, i + evidenceReach)]
            .contains { $0.speaker == "them" && $0.voice == v }
    }
}

/// A speaker edit that can still be taken back.
struct SpeakerUndo: Identifiable {
    let id = UUID()
    let session: String
    let snapshot: SessionStore.VoiceSnapshot
    var text: String
}

/// Asks Ling for names on its own: once two voices are on show, again every 20 lines, and once more
/// when the meeting ends. Guesses go straight into the meeting (`Session.voiceGuesses`); the user corrects.
@MainActor
final class SpeakerNamer: ObservableObject {
    @Published private(set) var busy: Set<String> = []
    private var askedAt: [String: Int] = [:]
    private let ling: LingClient
    private let store: SessionStore

    init(ling: LingClient, store: SessionStore) {
        self.ling = ling
        self.store = store
    }

    var available: Bool { ling.hasKey }

    /// `force`: the meeting just ended, so read it all once more.
    func guess(_ id: String, force: Bool = false) {
        guard ling.hasKey, !busy.contains(id), let s = store.session(id) else { return }
        guard force || s.lines.count >= (askedAt[id] ?? -1000) + 20, let content = SpeakerNameGuess.content(s) else { return }
        // Everyone already has a name the user gave: nothing to ask.
        let numbers = SpeakerLabels.voiceNumbers(s.lines)
        if numbers.keys.allSatisfy({ s.voiceNames?[String($0)] != nil }) { return }
        busy.insert(id)
        askedAt[id] = s.lines.count
        Task {
            defer { busy.remove(id) }
            do {
                let reply = try await ling.chat(content: content, instruction: SpeakerNameGuess.instruction,
                                                priority: .notes, json: true, maxTokens: 300, role: "speakers")
                let (found, read) = SpeakerNameGuess.read(reply, s)
                var refuted = read
                for (key, g) in s.voiceGuesses ?? [:] {
                    if let v = Int(key), found[v] == nil, !SpeakerNameGuess.holds(g, voice: v, in: s) { refuted[v] = g.name }
                }
                store.setVoiceGuesses(id, found, refuted: refuted)
                debugLog("speaker names: \(found.count) found, \(refuted.count) without evidence for \(id)")
                contentLog("speaker names reply: \(reply)")
            } catch {
                debugLog("speaker names: ling failed \(error)")
            }
        }
    }
}
