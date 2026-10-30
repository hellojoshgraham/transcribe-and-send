import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.34, green: 0.32, blue: 0.68, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 205, yRadius: 205).fill()
        NSColor.white.setFill()
        for (index, height) in [100.0, 230, 340, 200, 100].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 229 + Double(index) * 72, y: 590 - height / 2, width: 38, height: height), xRadius: 19, yRadius: 19).fill()
        }
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 638, y: 590)); arrow.line(to: NSPoint(x: 806, y: 590))
        arrow.move(to: NSPoint(x: 741, y: 655)); arrow.line(to: NSPoint(x: 806, y: 590)); arrow.line(to: NSPoint(x: 741, y: 525))
        arrow.lineWidth = 35; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; NSColor.white.setStroke(); arrow.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 205, weight: .semibold), .foregroundColor: NSColor.white]
        let text = "T&S" as NSString
        let width = text.size(withAttributes: attrs).width
        text.draw(at: NSPoint(x: (1024-width)/2, y: 198), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}
