import AppKit

enum ModeStatusImage {
    static func make(transmitting: Bool, delivered: Bool = false, failed: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 65, height: 18), flipped: false) { _ in
            let track = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 53, height: 17), xRadius: 5, yRadius: 5)
            NSColor.black.withAlphaComponent(0.5).setStroke(); track.lineWidth = 1; track.stroke()
            let thumb = NSBezierPath(roundedRect: NSRect(x: transmitting ? 2 : 28, y: 2, width: 24, height: 14), xRadius: 3, yRadius: 3)
            NSColor.black.setFill(); thumb.fill()
            for (label, x, selected) in [("TX", 6.0, transmitting), ("RX", 32.0, !transmitting)] {
                // Clear the selected letters from the template's alpha channel,
                // so the system menu-bar tint works in light and dark appearance.
                NSGraphicsContext.saveGraphicsState()
                if selected { NSGraphicsContext.current?.compositingOperation = .destinationOut }
                (label as NSString).draw(at: NSPoint(x: x, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.black])
                NSGraphicsContext.restoreGraphicsState()
            }
            let badge = failed ? "!" : delivered ? "✓" : ""
            (badge as NSString).draw(at: NSPoint(x: 56, y: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.black])
            return true
        }
        image.isTemplate = true
        return image
    }
}
