import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// 手机外放's subtitles over other apps: iOS lets an app float only a picture-in-picture video, so
/// the newest line is drawn into frames and fed to a sample buffer layer as a live stream. It starts
/// by itself when the app goes to the background while listening to video played aloud.
@MainActor
final class PiPSubtitles: NSObject, ObservableObject {
    /// The layer PiP takes its frames from; it has to sit in the window (PiPHost).
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var isActive = false
    private var controller: AVPictureInPictureController?
    private var shown: Caption?
    private var pending: Caption?
    private var drawing = false

    struct Caption: Equatable {
        var src: String
        var dst: String
        var note: String
    }

    /// 32:10 at the scale the window is drawn: wide enough for two lines of Chinese.
    static let size = CGSize(width: 960, height: 300)

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        draw(Caption(src: "", dst: "", note: L("正在听外放…")))
    }

    /// On while 手机外放 is listening, so leaving the app floats the window; off otherwise.
    func setEnabled(_ on: Bool) {
        if on, controller == nil, AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            let c = AVPictureInPictureController(contentSource: source)
            c.delegate = self
            c.requiresLinearPlayback = true
            controller = c
        }
        controller?.canStartPictureInPictureAutomaticallyFromInline = on
        if !on, controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        debugLog("pip: enabled=\(on) supported=\(AVPictureInPictureController.isPictureInPictureSupported())")
    }

    /// Debug (`pip`): float it now, as leaving the app would.
    func start() {
        debugLog("pip: start possible=\(controller?.isPictureInPicturePossible ?? false)")
        controller?.startPictureInPicture()
    }

    func show(src: String, dst: String, note: String) {
        let c = Caption(src: src, dst: dst, note: note)
        guard c != shown else { return }
        pending = c
        guard !drawing else { return }
        // A few frames a second at most: a draft changes on every word.
        drawing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.drawing = false
            if let p = self.pending { self.pending = nil; self.draw(p) }
        }
    }

    private func draw(_ c: Caption) {
        shown = c
        guard let buffer = Self.frame(c) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(buffer)
    }

    /// The design's dark card: 知了 · 正在听 in the accent, what was said in grey, the translation in white.
    private static func frame(_ c: Caption) -> CMSampleBuffer? {
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor(red: 0x15 / 255, green: 0x17 / 255, blue: 0x1C / 255, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let pad: CGFloat = 40
            let width = size.width - pad * 2
            let accent = UIColor(red: 0xFF / 255, green: 0x8A / 255, blue: 0x63 / 255, alpha: 1)
            accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: pad, y: 42, width: 14, height: 14)).fill()
            (L("知了 · 正在听") as NSString).draw(at: CGPoint(x: pad + 26, y: 30), withAttributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: accent])
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingHead
            var y: CGFloat = 92
            if !c.src.isEmpty {
                (c.src as NSString).draw(in: CGRect(x: pad, y: y, width: width, height: 44), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor(white: 0.74, alpha: 1), .paragraphStyle: para])
                y += 52
            }
            let main = c.dst.isEmpty ? c.note : c.dst
            let wrap = NSMutableParagraphStyle()
            wrap.lineBreakMode = .byWordWrapping
            wrap.lineSpacing = 6
            // The end of a long line matters most: keep its last two lines.
            let font = UIFont.systemFont(ofSize: 46, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: wrap]
            let text = tail(main, fitting: CGSize(width: width, height: size.height - y - 24), attrs)
            (text as NSString).draw(in: CGRect(x: pad, y: y, width: width, height: size.height - y - 16), withAttributes: attrs)
        }
        guard let cg = image.cgImage else { return nil }
        var pb: CVPixelBuffer?
        let props = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, props, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// The shortest ending of `text` that fills `box`, starting at a character boundary.
    private static func tail(_ text: String, fitting box: CGSize, _ attrs: [NSAttributedString.Key: Any]) -> String {
        func fits(_ s: String) -> Bool {
            (s as NSString).boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                         options: .usesLineFragmentOrigin, attributes: attrs, context: nil).height <= box.height
        }
        if fits(text) { return text }
        var s = Substring(text)
        while !s.isEmpty, !fits("…" + s) { s = s.dropFirst(max(1, s.count / 12)) }
        return "…" + s
    }
}

extension PiPSubtitles: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = true; debugLog("pip: started") }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        MainActor.assumeIsolated { isActive = false; debugLog("pip: stopped") }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { debugLog("pip: failed \(error)") }
    }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {}

    /// A live stream: no timeline, no skipping.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion: @escaping () -> Void) { completion() }
}

/// Holds the PiP layer in the window, as PiP requires; a few points, under the page.
struct PiPHost: UIViewRepresentable {
    let pip: PiPSubtitles

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.layer.addSublayer(pip.layer)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        pip.layer.frame = v.bounds
    }
}
