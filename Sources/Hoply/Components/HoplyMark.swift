import AppKit
import SwiftUI

// Same geometry as Hoply.icon (icon units, origin at the hub), with heavier strokes so it holds up at 14 pt.
nonisolated struct HoplyMark: Shape {
    var hollowHub = false

    private static let reach = 222.0
    private static let nodeRadius = 64.0
    private static let hubRadius = 104.0
    private static let hubHole = 62.0
    private static let spokeWidth = 52.0
    private static let width = 2 * (reach * cos(Double.pi / 6) + nodeRadius)
    private static let height = 2 * (reach + nodeRadius)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.width, rect.height / Self.height)
        let hub = CGPoint(x: rect.midX, y: rect.midY)
        let nodes = (0..<6).map { index in
            let angle = (Double(index) * 60 - 90) * .pi / 180
            return CGPoint(x: hub.x + cos(angle) * Self.reach * scale, y: hub.y + sin(angle) * Self.reach * scale)
        }
        var spokes = Path()
        for node in nodes {
            spokes.move(to: hub)
            spokes.addLine(to: node)
        }
        var mark = spokes.strokedPath(StrokeStyle(lineWidth: Self.spokeWidth * scale, lineCap: .round))
            .union(Self.circle(hub, Self.hubRadius * scale))
        for node in nodes {
            mark = mark.union(Self.circle(node, Self.nodeRadius * scale))
        }
        return hollowHub ? mark.subtracting(Self.circle(hub, Self.hubHole * scale)) : mark
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // Stand-in for the Dock under `swift run`, which has no bundle and so no Hoply.icon; same colours as the .icon.
    static func appIconImage() -> NSImage {
        let side = 512
        let size = CGSize(width: side, height: side)
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        let tile = CGRect(x: 50, y: 50, width: 412, height: 412)
        let shape = NSBezierPath(cgPath: RoundedRectangle(cornerRadius: 92, style: .continuous).path(in: tile).cgPath)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowOffset = CGSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 14
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(displayP3Red: 0.40, green: 0.46, blue: 1.0, alpha: 1),
                   ending: NSColor(displayP3Red: 0.27, green: 0.22, blue: 0.82, alpha: 1))?.draw(in: shape, angle: -90)
        NSColor.white.setFill()
        NSBezierPath(cgPath: HoplyMark().path(in: tile.insetBy(dx: 95, dy: 95)).cgPath).fill()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    static func statusBarSize(badged: Bool) -> CGSize {
        CGSize(width: badged ? 20 : 16, height: 16)
    }

    static func statusBarPath(hollowHub: Bool, badged: Bool) -> Path {
        let mark = HoplyMark(hollowHub: hollowHub).path(in: CGRect(x: 0, y: 0, width: 16, height: 16).insetBy(dx: 1, dy: 1))
        guard badged else { return mark }
        let dot = CGPoint(x: 17.5, y: 3)
        return mark.union(circle(dot, 2.5))
    }

    static func statusBarImage(hollowHub: Bool, badged: Bool = false) -> NSImage {
        let size = statusBarSize(badged: badged)
        // The path is y-down like SwiftUI; a bitmap context is y-up, and the dot belongs at the top.
        let path = NSBezierPath(cgPath: statusBarPath(hollowHub: hollowHub, badged: badged)
            .applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)).cgPath)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                             pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = badged ? "Hoply, update available" : "Hoply"
        return image
    }
}

nonisolated struct StatusBarMark: Shape {
    var hollowHub = false
    var badged = false

    func path(in rect: CGRect) -> Path {
        let size = HoplyMark.statusBarSize(badged: badged)
        let scale = min(rect.width / size.width, rect.height / size.height)
        return HoplyMark.statusBarPath(hollowHub: hollowHub, badged: badged)
            .applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: rect.minX / scale, y: rect.minY / scale))
    }
}
