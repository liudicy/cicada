import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia

// MARK: - Spoken language detection

/// Detects the spoken language by transcribing the same short clip with
/// every installed on-device model and comparing how confident each one is.
/// The right model is typically ≥0.85 confident; wrong ones produce little
/// text or score well below that.
enum LanguageDetector {
    struct Candidate {
        let lang: Lang
        let confidence: Double
        let chars: Int
        let text: String
        let score: Double
    }

    static func rank(_ clip: [AVAudioPCMBuffer], candidates: [Lang]) async -> [Candidate] {
        await withTaskGroup(of: Candidate?.self) { group in
            for lang in candidates {
                group.addTask { await evaluate(clip, lang: lang) }
            }
            var out: [Candidate] = []
            for await c in group { if let c { out.append(c) } }
            return out.sorted { $0.score > $1.score }
        }
    }

    private static func evaluate(_ clip: [AVAudioPCMBuffer], lang: Lang) async -> Candidate? {
        guard let heard = await Recognition.transcribe(clip, locale: lang.locale) else { return nil }
        return Candidate(lang: lang, confidence: heard.confidence, chars: heard.letters, text: heard.text,
                         score: score(conf: heard.confidence, chars: heard.letters, text: heard.text, lang: lang))
    }

    static func score(conf: Double, chars: Int, text: String, lang: Lang) -> Double {
        guard chars > 0 else { return 0 }
        // Very short output means the model mostly heard noise.
        let lengthFactor = min(1.0, Double(chars) / 6.0)
        // A CJK model that mostly writes Latin letters is transcribing a foreign language.
        var scriptFactor = 1.0
        if ["ja", "zh-CN", "ko"].contains(lang.code) {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let latin = letters.filter { $0.isASCII }.count
            if !letters.isEmpty, Double(latin) / Double(letters.count) > 0.5 { scriptFactor = 0.75 }
        }
        return conf * lengthFactor * scriptFactor
    }
}

