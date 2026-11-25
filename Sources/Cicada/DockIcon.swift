import AppKit

/// The Dock tile: the app icon, with an orange dot at the top right while a meeting is being
/// recorded (the same "live" the menu bar icon shows).
@MainActor
enum DockIcon {
    private(set) static var live = false

    static func show(live: Bool) {
        self.live = live
        let tile = NSApp.dockTile
        // Drawn ourselves either way: after the app turns regular again the Dock can otherwise keep
        // a blank tile until something redraws it.
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = image(live: live)
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }

    private static func image(live: Bool) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            guard live else { return true }
            // Inside the icon's own rounded square (about 80% of the canvas, centered), top right.
            let d = rect.width * 0.22
            let dot = NSRect(x: rect.maxX - rect.width * 0.1 - d * 0.8, y: rect.maxY - rect.height * 0.1 - d * 0.8,
                             width: d, height: d)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -d * 0.1, dy: -d * 0.1)).fill()
            NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }
}
