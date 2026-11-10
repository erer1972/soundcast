import AppKit
import SoundCastCore

/// What AirPlay rooms (Apple TVs) show while SoundCast plays to them:
/// "SoundCast" / this Mac's name, over a cover image drawn here, so the
/// TV shows a Now Playing screen instead of a black one.
enum NowPlayingArtwork {
    @MainActor static let info: AirPlayRealtimeSender.NowPlaying = {
        let macName = Host.current().localizedName ?? "Mac"
        return AirPlayRealtimeSender.NowPlaying(
            title: "SoundCast",
            artist: macName,
            album: "Playing from \(macName)",
            artworkPNG: renderPNG(macName: macName)
        )
    }()

    private static let side: CGFloat = 600

    private static func renderPNG(macName: String) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        // Same colours as the widget: deep blue-black with coral and teal.
        NSGradient(colors: [
            NSColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1),
            NSColor(red: 0.16, green: 0.10, blue: 0.20, alpha: 1),
        ])?.draw(in: bounds, angle: -60)

        let coral = NSColor(red: 1.0, green: 0.48, blue: 0.35, alpha: 1)
        let teal = NSColor(red: 0.43, green: 0.91, blue: 0.78, alpha: 1)

        // Sound waves: concentric arcs to the right of a dot.
        let center = NSPoint(x: side * 0.34, y: side * 0.58)
        coral.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)).fill()
        for (index, radius) in [CGFloat(80), 135, 190].enumerated() {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: -45, endAngle: 45)
            arc.lineWidth = 22
            arc.lineCapStyle = .round
            (index == 2 ? teal : coral).withAlphaComponent(1 - CGFloat(index) * 0.2).setStroke()
            arc.stroke()
        }

        func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            (text as NSString).draw(in: NSRect(x: 30, y: y, width: side - 60, height: size * 1.3), withAttributes: attributes)
        }
        draw("SoundCast", size: 64, weight: .bold, color: .white, y: 150)
        draw(macName, size: 34, weight: .medium, color: NSColor.white.withAlphaComponent(0.65), y: 92)

        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}
