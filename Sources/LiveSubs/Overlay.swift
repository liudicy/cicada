import AppKit

/// The floating subtitle bar.
/// - Auto mode: appears when someone speaks; after a few quiet seconds it
///   tucks away into a small dot (hover the dot to peek at the last line).
/// - Always click-through. When the pointer passes over it, it fades to 15%
///   so whatever is underneath stays visible and clickable.
/// - Rest the pointer on it for 0.6 s to edit: outline + corner grip.
/// - Drag anywhere to move (snaps to the screen's centre line).
/// - Drag the bottom-right grip to scale; the font scales with the width.
/// - Double-click to return to the default spot.
/// - Position, width and size are remembered per display.
@MainActor
final class OverlayController {
    struct Speaking {
        var phase: SpeakEngine.Phase
        var source: String
        var translation: String
    }

    private let panel: OverlayPanel
    private let view: OverlayView
    private var hoverTimer: Timer?
    private var speakClearWork: DispatchWorkItem?

    /// "auto" or "always", and seconds of quiet before tucking away.
    var mode: () -> (auto: Bool, hideAfter: Double) = { (true, 4) }
    /// Called when the bar tucks away after a quiet spell.
    var onCollapsed: (() -> Void)?
    private(set) var expanded = true
    private(set) var manualHidden = false
    private(set) var dimmed = false
    private var peeking = false
    private var lastContentAt = Date()
    private var lastMouse = NSPoint.zero
    private var stillFor = 0.0
    private static let pollInterval = 0.05

    private(set) var isShown = false
    private var width: CGFloat = 900
    private var fontSize: CGFloat = 28
    private var origin = NSPoint.zero
    private var screenKey = ""

    static let margin: CGFloat = 10

    init() {
        view = OverlayView(frame: NSRect(x: 0, y: 0, width: 900, height: 160))
        panel = OverlayPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = view
        view.controller = self
    }

    // MARK: Content

    func setSubtitle(source: String, translation: String) {
        let changed = source != view.source || translation != view.translation
        view.source = source
        view.translation = translation
        let lines = view.neededLines(barWidth: width)
        if lines != view.transLines, view.dragMode == nil {
            view.transLines = lines
            layout()
        }
        view.needsDisplay = true
        if changed && !(source.isEmpty && translation.isEmpty) {
            lastContentAt = Date()
            expand()
        }
    }

    func setStatus(_ text: String) {
        guard view.source.isEmpty && view.translation.isEmpty || view.isStatus else { return }
        view.source = ""
        view.translation = text
        view.isStatus = true
        view.needsDisplay = true
    }

    func clearStatus() {
        if view.isStatus {
            view.translation = ""
            view.isStatus = false
            view.needsDisplay = true
        }
    }

    /// A status that has to be seen (the meeting is about to end): brings a tucked-away bar back
    /// and keeps it up while it is repeated.
    func notice(_ text: String) {
        setStatus(text)
        guard view.isStatus else { return }
        lastContentAt = Date()
        expand()
    }

    func setSpeaking(_ s: Speaking?) {
        speakClearWork?.cancel()
        if s != nil {
            lastContentAt = Date()
            expand()
        }
        if let s, s.phase == .idle {
            // Leave the last thing you said up for a few seconds.
            view.speaking = s
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.view.speaking = nil
                    self?.layout()
                }
            }
            speakClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        } else {
            view.speaking = s
        }
        layout()
    }

    // MARK: Show / hide

    func show() {
        restore()
        isShown = true
        manualHidden = false
        // Auto mode starts tucked away until someone speaks.
        setExpanded(!mode().auto, animated: false)
        layout()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHover() }
        }
        hoverTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func hide() {
        isShown = false
        hoverTimer?.invalidate()
        hoverTimer = nil
        setHover(false)
        panel.orderOut(nil)
    }

    // MARK: Expand / collapse

    private func expand() {
        guard isShown, !manualHidden, !expanded else { return }
        setExpanded(true, animated: true)
    }

    private func setExpanded(_ on: Bool, animated: Bool) {
        expanded = on
        if !on {
            onCollapsed?()
            dimmed = false
            stillFor = 0
            setHover(false)
        }
        guard animated else {
            view.collapsed = !on
            view.needsDisplay = true
            panel.alphaValue = manualHidden ? 0 : 1
            return
        }
        if on {
            view.collapsed = false
            view.needsDisplay = true
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.expanded else { return }
                    self.view.collapsed = true
                    self.view.needsDisplay = true
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        self.panel.animator().alphaValue = 1
                    }
                }
            })
        }
    }

    /// The toggle shortcut (⌃⌥S by default): hide everything now, or bring the bar back.
    func toggleManual() {
        guard isShown else { return }
        if manualHidden || !expanded {
            manualHidden = false
            lastContentAt = Date()
            setExpanded(true, animated: true)
        } else {
            manualHidden = true
            setHover(false)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }
        }
    }

    /// The listening pill: back on screen however it went away (⌃⌥S, or tucked after a quiet spell).
    func reveal() {
        guard isShown else { show(); return }
        if manualHidden || !expanded { toggleManual() }
    }

    func modeChanged() {
        if !mode().auto { lastContentAt = Date(); expand() }
    }

    var stateDescription: String {
        "shown=\(isShown) expanded=\(expanded) manualHidden=\(manualHidden) dimmed=\(dimmed) editing=\(view.hover) " +
        "peek=\(peeking) alpha=\(String(format: "%.2f", panel.alphaValue)) clickThrough=\(panel.ignoresMouseEvents) " +
        "mouse=\(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y)) bar=\(barFrame.integral)"
    }

    // MARK: Geometry

    private var barHeight: CGFloat { view.barHeight(fontSize: fontSize) }

    private func layout() {
        view.fontSize = fontSize
        let m = Self.margin
        let frame = NSRect(x: origin.x - m, y: origin.y - m, width: width + 2 * m, height: barHeight + 2 * m)
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
    }

    private func currentScreen() -> NSScreen {
        let mid = NSPoint(x: origin.x + width / 2, y: origin.y + 10)
        return NSScreen.screens.first(where: { $0.frame.contains(mid) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func key(for screen: NSScreen) -> String {
        let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return "overlay.\(n)"
    }

    private func defaults(on screen: NSScreen) {
        let v = screen.visibleFrame
        width = min(1000, v.width - 160)
        fontSize = 28
        origin = NSPoint(x: v.midX - width / 2, y: v.minY + 56)
    }

    private func restore() {
        let d = UserDefaults.standard
        let last = d.string(forKey: "overlay.lastScreen")
        let screen = NSScreen.screens.first(where: { Self.key(for: $0) == last })
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        screenKey = Self.key(for: screen)
        if let a = d.array(forKey: screenKey) as? [Double], a.count == 4 {
            let rect = NSRect(x: a[0], y: a[1], width: a[2], height: 40)
            if screen.frame.intersects(rect) {
                origin = NSPoint(x: a[0], y: a[1])
                width = a[2]
                fontSize = a[3]
                return
            }
        }
        defaults(on: screen)
    }

    private func save() {
        let screen = currentScreen()
        screenKey = Self.key(for: screen)
        UserDefaults.standard.set([Double(origin.x), Double(origin.y), Double(width), Double(fontSize)], forKey: screenKey)
        UserDefaults.standard.set(screenKey, forKey: "overlay.lastScreen")
    }

    func resetPosition() {
        defaults(on: currentScreen())
        layout()
        save()
    }

    /// Debug / tests: place the bar exactly.
    func place(x: CGFloat, y: CGFloat, width w: CGFloat, fontSize fs: CGFloat) {
        origin = NSPoint(x: x, y: y)
        width = w
        fontSize = fs
        layout()
        save()
    }

    var barFrame: NSRect { NSRect(x: origin.x, y: origin.y, width: width, height: barHeight) }
    var currentFontSize: CGFloat { fontSize }

    // MARK: Hover

    private var pillFrame: NSRect {
        NSRect(x: origin.x + width / 2 - 34, y: origin.y - 4, width: 68, height: 30)
    }

    private func setDimmed(_ on: Bool) {
        guard dimmed != on else { return }
        dimmed = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.12 : 0.25
            panel.animator().alphaValue = on ? 0.15 : 1
        }
    }

    private func pollHover() {
        guard isShown, !manualHidden else { return }
        if view.dragMode != nil { return }
        let mouse = NSEvent.mouseLocation
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2
        lastMouse = mouse
        let dt = Self.pollInterval

        // Tucked away: hovering the dot peeks at the last line.
        if !expanded {
            if pillFrame.contains(mouse) {
                peeking = true
                setExpanded(true, animated: true)
            }
            return
        }

        let overBar = barFrame.insetBy(dx: -4, dy: -4).contains(mouse)
        if view.hover {
            // Editing: stay until the pointer leaves.
            if !overBar { setHover(false); stillFor = 0 }
        } else if overBar && !peeking {
            // Passing over: fade so the app underneath stays usable.
            setDimmed(true)
            stillFor = moved ? 0 : stillFor + dt
            if stillFor >= 0.6 {
                setDimmed(false)
                setHover(true)
            }
        } else {
            stillFor = 0
            setDimmed(false)
        }

        if peeking {
            if !overBar && !pillFrame.contains(mouse) {
                peeking = false
                if mode().auto { setExpanded(false, animated: true) }
            }
            return
        }

        // Quiet long enough: tuck away.
        let m = mode()
        if m.auto, !view.hover, !dimmed, view.speaking == nil,
           Date().timeIntervalSince(lastContentAt) > m.hideAfter {
            setExpanded(false, animated: true)
        }
    }

    private func setHover(_ on: Bool) {
        view.hover = on
        panel.ignoresMouseEvents = !on
        view.needsDisplay = true
    }

    // MARK: Dragging (called by the view)

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragStartWidth: CGFloat = 0
    private var dragStartFont: CGFloat = 0
    private var snapped = false

    func beginDrag() {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = origin
        dragStartWidth = width
        dragStartFont = fontSize
        snapped = false
    }

    func drag(scale: Bool) {
        let p = NSEvent.mouseLocation
        let dx = p.x - dragStartMouse.x
        let dy = p.y - dragStartMouse.y
        let screen = currentScreen()
        let sf = screen.frame
        if scale {
            let maxW = min(1800, sf.width - 16)
            width = max(420, min(maxW, dragStartWidth + dx))
            fontSize = max(18, min(48, (dragStartFont * width / dragStartWidth).rounded()))
            // Grow downwards from the top edge, like a window corner.
            let top = dragStartOrigin.y + view.barHeight(fontSize: dragStartFont)
            origin = NSPoint(x: dragStartOrigin.x, y: top - view.barHeight(fontSize: fontSize))
        } else {
            var x = dragStartOrigin.x + dx
            let y = dragStartOrigin.y + dy
            let centre = screen.visibleFrame.midX
            if abs(x + width / 2 - centre) < 18 {
                x = centre - width / 2
                if !snapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                snapped = true
            } else {
                snapped = false
            }
            origin = NSPoint(x: x, y: y)
        }
        // Keep the bar on screen.
        let all = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        origin.x = max(all.minX + 4 - width + 120, min(all.maxX - 120, origin.x))
        origin.y = max(all.minY + 4, min(all.maxY - barHeight - 4, origin.y))
        view.snapped = snapped && !scale
        layout()
    }

    func endDrag() {
        view.snapped = false
        save()
        view.needsDisplay = true
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    weak var controller: OverlayController?
    var source = ""
    var translation = ""
    var isStatus = false
    var speaking: OverlayController.Speaking?
    var fontSize: CGFloat = 28
    var hover = false
    var snapped = false
    var collapsed = false
    /// Translation lines the bar is sized for (1 or 2), so a short line leaves no gap.
    var transLines = 1
    var dragMode: Bool?

    private let orange = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.62, alpha: 1)
    private let accent = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1)

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Metrics

    private func k(_ fs: CGFloat) -> CGFloat { fs / 28 }
    private func srcFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: max(12, fs * 0.58), weight: .medium) }
    private func transFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs, weight: .semibold) }
    private func speakFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: max(14, fs * 0.78), weight: .semibold) }
    private func line(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) * 1.18 }

    func barHeight(fontSize fs: CGFloat) -> CGFloat {
        let pad = 14 * k(fs)
        var h = pad * 2 + line(srcFont(fs)) + 6 * k(fs) + line(transFont(fs)) * CGFloat(transLines)
        if speaking != nil {
            h += 12 * k(fs) + line(srcFont(fs)) + line(speakFont(fs)) * 2
        }
        return ceil(h)
    }

    private var barRect: NSRect { bounds.insetBy(dx: OverlayController.margin, dy: OverlayController.margin) }
    private var gripRect: NSRect {
        let s: CGFloat = 26
        return NSRect(x: barRect.maxX - s + 6, y: barRect.minY - 6, width: s, height: s)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if collapsed {
            // Tucked away: a small pill at the bottom centre — still listening.
            let pill = NSRect(x: barRect.midX - 23, y: barRect.minY, width: 46, height: 18)
            NSColor(calibratedWhite: 0.05, alpha: 0.75).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 12, y: pill.midY - 2.5, width: 5, height: 5)).fill()
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 21, y: pill.midY - 1.5, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 28, y: pill.midY - 1.5, width: 3, height: 3)).fill()
            return
        }
        let bar = barRect
        let radius = 16 * k(fontSize)
        NSColor(calibratedWhite: 0.05, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        if hover {
            let outline = NSBezierPath(roundedRect: bar.insetBy(dx: -3, dy: -3), xRadius: radius + 3, yRadius: radius + 3)
            outline.lineWidth = 1.5
            (snapped ? accent : NSColor.white.withAlphaComponent(0.5)).setStroke()
            outline.stroke()
        }

        let fs = fontSize
        let pad = 14 * k(fs)
        let inner = bar.insetBy(dx: 26 * k(fs), dy: pad)
        var y = inner.maxY

        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineBreakMode = .byWordWrapping

        func draw(_ text: String, font: NSFont, color: NSColor, maxLines: Int) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center]
            let maxH = line(font) * CGFloat(maxLines)
            let fitted = fitTail(text, attrs: attrs, width: inner.width, maxHeight: maxH + 1)
            let h = min(maxH, height(of: fitted, attrs: attrs, width: inner.width))
            // Bottom-align within the slot so the newest line sits lowest.
            let rect = NSRect(x: inner.minX, y: y - maxH, width: inner.width, height: h)
            (fitted as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            y -= maxH
        }

        let srcText = isStatus ? "" : source
        draw(srcText, font: srcFont(fs), color: NSColor.white.withAlphaComponent(0.62), maxLines: 1)
        y -= 6 * k(fs)
        draw(translation, font: transFont(fs),
             color: isStatus ? NSColor.white.withAlphaComponent(0.7) : .white, maxLines: transLines)

        if let s = speaking {
            y -= 12 * k(fs)
            let label: String
            switch s.phase {
            case .listening: label = L("你在说…  ") + s.source
            case .translating: label = L("翻译中…  ") + s.source
            case .speaking, .idle: label = L("你：") + s.source
            }
            draw(label, font: srcFont(fs), color: orange.withAlphaComponent(0.8), maxLines: 1)
            draw(s.translation, font: speakFont(fs), color: orange, maxLines: 2)
        }

        if hover {
            let g = gripRect
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: g, xRadius: 8, yRadius: 8).fill()
            let p = NSBezierPath()
            p.lineWidth = 2
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: g.minX + 8, y: g.minY + 7)); p.line(to: NSPoint(x: g.maxX - 7, y: g.maxY - 8))
            p.move(to: NSPoint(x: g.midX + 1, y: g.minY + 7)); p.line(to: NSPoint(x: g.maxX - 7, y: g.midY - 1))
            NSColor(calibratedWhite: 0.08, alpha: 1).setStroke()
            p.stroke()
        }
    }

    /// How many lines the translation needs at the current width (1 or 2).
    func neededLines(barWidth: CGFloat) -> Int {
        let fs = fontSize
        let attrs: [NSAttributedString.Key: Any] = [.font: transFont(fs)]
        let w = barWidth - 2 * 26 * k(fs)
        return height(of: translation, attrs: attrs, width: w) > line(transFont(fs)) * 1.3 ? 2 : 1
    }

    private func height(of s: String, attrs: [NSAttributedString.Key: Any], width: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs).height)
    }

    /// Keeps the end of the text (newest words) and drops the beginning until it fits.
    private func fitTail(_ text: String, attrs: [NSAttributedString.Key: Any], width: CGFloat, maxHeight: CGFloat) -> String {
        if text.isEmpty || height(of: text, attrs: attrs, width: width) <= maxHeight { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if height(of: "…" + String(chars[mid...]), attrs: attrs, width: width) <= maxHeight { hi = mid } else { lo = mid + 1 }
        }
        return "…" + String(chars[min(lo, chars.count)...])
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.resetPosition()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        dragMode = gripRect.insetBy(dx: -6, dy: -6).contains(p)
        controller?.beginDrag()
        (dragMode == true ? NSCursor.crosshair : NSCursor.closedHand).push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode else { return }
        controller?.drag(scale: mode)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragMode != nil else { return }
        dragMode = nil
        NSCursor.pop()
        controller?.endDrag()
    }

    override func resetCursorRects() {
        if hover {
            addCursorRect(barRect, cursor: .openHand)
            addCursorRect(gripRect, cursor: .crosshair)
        }
    }
}
