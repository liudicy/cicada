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
    private static let well = CGColor(srgbRed: 0.945, green: 0.949, blue: 0.961, alpha: 1)      // #F1F2F5
    private static let bar = CGColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1)
    private static let macBlue = CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

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

        firstOpenSteps(ctx)
    }

    /// The app is ad-hoc signed, so the first open shows Gatekeeper's "Apple 无法验证…恶意软件" sheet.
    /// Say up front that this is expected, then show the three screens people will meet in miniature,
    /// with the thing to click ringed, so nobody stops at the scary sheet or picks 移到废纸篓.
    /// Button names match macOS's own Chinese strings (CoreServicesUIAgent, Privacy & Security).
    private static func firstOpenSteps(_ ctx: CGContext) {
        text("第一次打开会被拦一下，别担心", size: 15, weight: .semibold, color: ink, centerX: size.width / 2, top: 274)
        text("开发者证书还在申请中，照下面放行一次，以后就能直接打开", size: 12, weight: .regular,
             color: secondary, centerX: size.width / 2, top: 298)

        let steps: [(title: String, hint: String, art: (CGContext, CGRect) -> Void)] = [
            // macOS 14's sheet has only 好 (OK); 15 and later have 完成 and 移到废纸篓.
            ("点完成或好", "别点移到废纸篓", drawAlert),
            ("打开系统设置", "左边选隐私与安全性", drawSettings),
            // 14 asks once more after the password: 打开.
            ("点仍要打开", "在安全性一栏，按提示输密码确认", drawOpenAnyway),
        ]
        let w: CGFloat = 188, gap: CGFloat = 14
        var x = (size.width - w * 3 - gap * 2) / 2
        for (i, step) in steps.enumerated() {
            let card = CGRect(x: x, y: 330, width: w, height: 168)
            fill(ctx, card, radius: 12, color: .white, shadow: true)
            let art = card.insetBy(dx: 8, dy: 8).divided(atDistance: 100, from: .minYEdge).slice
            fill(ctx, art, radius: 8, color: well)
            ctx.saveGState()
            ctx.clip(to: art)
            step.art(ctx, art)
            ctx.restoreGState()

            // "① 点完成" centred under the picture, the hint below it.
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            let tw = (step.title as NSString).size(withAttributes: titleAttrs).width
            let left = card.midX - (tw + 24) / 2
            let badge = CGRect(x: left, y: card.minY + 120, width: 18, height: 18)
            ctx.setFillColor(orange.cgColor)
            ctx.fillEllipse(in: badge)
            text("\(i + 1)", size: 11, weight: .bold, color: .white, centerX: badge.midX, top: badge.minY + 2)
            text(step.title, size: 13, weight: .semibold, color: ink, x: badge.maxX + 6, top: badge.minY)
            text(step.hint, size: 11, weight: .regular, color: grey, centerX: card.midX, top: card.minY + 143)
            x += w + gap
        }
    }

    /// The "未打开 Cicada" sheet: 移到废纸篓 greyed, 完成 ringed.
    private static func drawAlert(_ ctx: CGContext, in r: CGRect) {
        let sheet = CGRect(x: r.midX - 66, y: r.minY + 8, width: 132, height: 86)
        fill(ctx, sheet, radius: 10, color: .white, shadow: true)
        if let icon = appIconImage {
            icon.draw(in: CGRect(x: sheet.midX - 10, y: sheet.minY + 7, width: 18, height: 18))
        }
        text("未打开 Cicada", size: 9, weight: .semibold, color: ink, centerX: sheet.midX, top: sheet.minY + 27)
        fill(ctx, CGRect(x: sheet.minX + 18, y: sheet.minY + 42, width: 96, height: 4), radius: 2, color: bar)
        fill(ctx, CGRect(x: sheet.minX + 30, y: sheet.minY + 50, width: 72, height: 4), radius: 2, color: bar)
        let trash = CGRect(x: sheet.minX + 10, y: sheet.minY + 60, width: 54, height: 16)
        let done = CGRect(x: sheet.maxX - 64, y: sheet.minY + 60, width: 54, height: 16)
        fill(ctx, trash, radius: 8, color: well)
        text("移到废纸篓", size: 7.5, weight: .regular, color: grey, centerX: trash.midX, top: trash.minY + 3)
        fill(ctx, done, radius: 8, color: macBlue)
        text("完成", size: 8, weight: .semibold, color: .white, centerX: done.midX, top: done.minY + 2.5)
        ring(ctx, done)
    }

    /// System Settings with 隐私与安全性 ringed in the sidebar.
    private static func drawSettings(_ ctx: CGContext, in r: CGRect) {
        let win = CGRect(x: r.minX + 14, y: r.minY + 12, width: r.width - 28, height: 100)
        fill(ctx, win, radius: 10, color: .white, shadow: true)
        let side = CGRect(x: win.minX, y: win.minY, width: 78, height: win.height)
        fill(ctx, side, radius: 10, color: CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        for (i, w) in [CGFloat(40), 30, 46].enumerated() {
            let rowY = win.minY + 12 + CGFloat(i) * 13
            ctx.setFillColor(bar); ctx.fillEllipse(in: CGRect(x: side.minX + 9, y: rowY, width: 7, height: 7))
            fill(ctx, CGRect(x: side.minX + 20, y: rowY + 1.5, width: w, height: 4), radius: 2, color: bar)
        }
        let row = CGRect(x: side.minX + 4, y: win.minY + 52, width: side.width + 8, height: 17)
        fill(ctx, row, radius: 5, color: macBlue)
        text("隐私与安全性", size: 8, weight: .semibold, color: .white, x: row.minX + 7, top: row.minY + 3)
        ring(ctx, row)
        for (i, w) in [CGFloat(52), 36, 44, 30].enumerated() {
            fill(ctx, CGRect(x: side.maxX + 16, y: win.minY + 14 + CGFloat(i) * 12, width: w, height: 4), radius: 2, color: bar)
        }
    }

    /// The 安全性 section: "已阻止 Cicada 以保护 Mac" with 仍要打开 ringed.
    private static func drawOpenAnyway(_ ctx: CGContext, in r: CGRect) {
        let pane = CGRect(x: r.minX + 14, y: r.minY + 12, width: r.width - 28, height: 100)
        fill(ctx, pane, radius: 10, color: .white, shadow: true)
        text("安全性", size: 9, weight: .semibold, color: ink, x: pane.minX + 12, top: pane.minY + 9)
        fill(ctx, CGRect(x: pane.minX + 12, y: pane.minY + 27, width: pane.width - 24, height: 0.8), radius: 0, color: bar)
        text("已阻止 Cicada 以保护 Mac", size: 8, weight: .regular, color: secondary, x: pane.minX + 12, top: pane.minY + 36)
        let button = CGRect(x: pane.minX + 12, y: pane.minY + 55, width: 58, height: 17)
        fill(ctx, button, radius: 8.5, color: well)
        text("仍要打开", size: 8, weight: .semibold, color: ink, centerX: button.midX, top: button.minY + 3)
        ring(ctx, button)
    }

    /// The app's own icon, read from the running bundle.
    private static var appIconImage: NSImage? { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor, shadow: Bool = false) {
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: CGColor(gray: 0, alpha: 0.08)) }
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The orange "click here" ring around a control.
    private static func ring(_ ctx: CGContext, _ rect: CGRect) {
        let r = rect.insetBy(dx: -3.5, dy: -3.5)
        ctx.setStrokeColor(orange.cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.strokePath()
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
