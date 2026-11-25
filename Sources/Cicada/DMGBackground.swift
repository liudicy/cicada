import AppKit

/// `Cicada --render-dmg-background out.png <scale>` draws the installer window's background.
/// Finder places the icons on top of it at `appIcon` and `applicationsIcon`, so the art leaves
/// those spots empty. Keep in step with `scripts/dmg-template.sh`.
enum DMGBackground {
    static let size = CGSize(width: 640, height: 520)
    static let appIcon = CGPoint(x: 170, y: 175)
    static let applicationsIcon = CGPoint(x: 470, y: 175)

    private static let ink = NSColor(srgbRed: 0.082, green: 0.09, blue: 0.11, alpha: 1)       // #15171C
    private static let secondary = NSColor(srgbRed: 0.353, green: 0.373, blue: 0.42, alpha: 1) // #5A5F6B
    private static let orange = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1)      // #E8552B
    private static let grey = NSColor(srgbRed: 0.42, green: 0.44, blue: 0.5, alpha: 1)          // #6B7080

    static func render(to url: URL, scale: Int) throws {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        guard let cg = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { throw CocoaError(.fileWriteUnknown) }
        // Flip to a y-down point space so coordinates match Finder's icon positions.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(cg)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    private static func draw(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1)) // #F6F7F9
        ctx.fill(CGRect(origin: .zero, size: size))

        text("把知了拖进应用程序", size: 22, weight: .semibold, color: ink, centerX: size.width / 2, top: 28)
        text("然后在应用程序或启动台里打开它", size: 13, weight: .regular, color: secondary, centerX: size.width / 2, top: 62)

        // Dotted arrow from the app to Applications.
        ctx.setStrokeColor(orange.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [0.1, 9])
        let y = appIcon.y
        ctx.move(to: CGPoint(x: appIcon.x + 84, y: y))
        ctx.addLine(to: CGPoint(x: applicationsIcon.x - 92, y: y))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineJoin(.round)
        let tip = CGPoint(x: applicationsIcon.x - 80, y: y)
        ctx.move(to: CGPoint(x: tip.x - 11, y: y - 9))
        ctx.addLine(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x - 11, y: y + 9))
        ctx.strokePath()

        openSteps(ctx)
    }

    /// The app is signed and notarized, so it opens without a Gatekeeper prompt: the lower half
    /// says what comes after opening instead, the onboarding's first three steps.
    private static func openSteps(_ ctx: CGContext) {
        text("打开后，跟着引导走三步", size: 15, weight: .semibold, color: ink, centerX: size.width / 2, top: 300)
        text("已通过 Apple 公证，双击就能打开", size: 12, weight: .regular,
             color: secondary, centerX: size.width / 2, top: 324)

        let steps: [(title: String, hint: String)] = [
            ("允许听系统声音", "只听电脑在放的声音"),
            ("试听示例会议", "看字幕和纪要怎么出来"),
            ("接上 AI", "可以先跳过，以后再接"),
        ]
        let w: CGFloat = 188, gap: CGFloat = 14
        var x = (size.width - w * 3 - gap * 2) / 2
        for (i, step) in steps.enumerated() {
            let card = CGRect(x: x, y: 364, width: w, height: 84)
            fill(ctx, card, radius: 12, color: .white, shadow: true)

            // "① 允许听系统声音" centred, the hint below it.
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            let tw = (step.title as NSString).size(withAttributes: titleAttrs).width
            let left = card.midX - (tw + 24) / 2
            let badge = CGRect(x: left, y: card.minY + 22, width: 18, height: 18)
            ctx.setFillColor(orange.cgColor)
            ctx.fillEllipse(in: badge)
            text("\(i + 1)", size: 11, weight: .bold, color: .white, centerX: badge.midX, top: badge.minY + 2)
            text(step.title, size: 13, weight: .semibold, color: ink, x: badge.maxX + 6, top: badge.minY)
            text(step.hint, size: 11, weight: .regular, color: grey, centerX: card.midX, top: card.minY + 50)
            x += w + gap
        }
    }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor, shadow: Bool = false) {
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: CGColor(gray: 0, alpha: 0.08)) }
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, x: CGFloat, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        (s as NSString).draw(at: CGPoint(x: x, y: top), withAttributes: attrs)
    }

    private static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let w = (s as NSString).size(withAttributes: attrs).width
        (s as NSString).draw(at: CGPoint(x: centerX - w / 2, y: top), withAttributes: attrs)
    }
}
