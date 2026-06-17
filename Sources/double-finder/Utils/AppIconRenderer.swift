import AppKit

/// Draws the Double Finder app icon entirely in code (Core Graphics / AppKit),
/// so the dock icon needs no bundled asset. The same drawing exports to PNG/icns.
///
/// Concept: a blue "squircle" with two side-by-side file panels (the app's
/// signature dual-pane layout); the left panel has one highlighted row, and a
/// pair of ⇄ arrows sits in the center channel to suggest transferring files
/// between panels.
enum AppIconRenderer {

    static func image(pixels: Int = 512) -> NSImage {
        let img = NSImage(size: NSSize(width: pixels, height: pixels))
        img.addRepresentation(bitmap(pixels: pixels))
        return img
    }

    static func writePNG(to path: String, pixels: Int = 1024) {
        guard let data = bitmap(pixels: pixels).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func bitmap(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Drawing (designed on a 1024×1024 grid, scaled by `size`)

    static func draw(size S: CGFloat) {
        let k = S / 1024.0
        func s(_ v: CGFloat) -> CGFloat { v * k }

        // Rounded-square (squircle-ish) background with a vertical blue gradient.
        let sq = NSRect(x: s(96), y: s(96), width: s(832), height: s(832))
        let sqPath = NSBezierPath(roundedRect: sq, xRadius: s(186), yRadius: s(186))
        let topBlue = NSColor(srgbRed: 0.36, green: 0.62, blue: 1.00, alpha: 1)
        let bottomBlue = NSColor(srgbRed: 0.13, green: 0.31, blue: 0.86, alpha: 1)
        NSGradient(starting: bottomBlue, ending: topBlue)!.draw(in: sqPath, angle: 90)

        // Subtle top sheen for depth.
        NSGraphicsContext.saveGraphicsState()
        sqPath.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.16),
                            NSColor.white.withAlphaComponent(0.0)])!
            .draw(in: sq, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Two panels with a center channel.
        let gap = s(96)
        let region = NSRect(x: s(228), y: s(300), width: s(568), height: s(430))
        let pw = (region.width - gap) / 2
        let leftRect = NSRect(x: region.minX, y: region.minY, width: pw, height: region.height)
        let rightRect = NSRect(x: region.minX + pw + gap, y: region.minY, width: pw, height: region.height)

        // Panel bases with a soft drop shadow.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: s(-8))
        shadow.shadowBlurRadius = s(22)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.set()
        drawPanelBase(leftRect, k: k)
        drawPanelBase(rightRect, k: k)
        NSGraphicsContext.restoreGraphicsState()

        // Panel contents (header + file rows; left panel has a selected row).
        drawPanelContent(leftRect, k: k, highlight: 1)
        drawPanelContent(rightRect, k: k, highlight: nil)

        // Transfer arrows in the center channel.
        drawArrows(centerX: region.minX + pw + gap / 2, centerY: region.midY, k: k)
    }

    private static func drawPanelBase(_ r: NSRect, k: CGFloat) {
        let radius = 26 * k
        NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    private static func drawPanelContent(_ r: NSRect, k: CGFloat, highlight: Int?) {
        func s(_ v: CGFloat) -> CGFloat { v * k }
        let inset = s(26)
        let x = r.minX + inset
        let innerW = r.width - inset * 2

        // Header bar.
        let headerH = s(46)
        let headerY = r.maxY - inset - headerH
        NSColor(srgbRed: 0.80, green: 0.87, blue: 1.0, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: headerY, width: innerW, height: headerH),
                     xRadius: s(10), yRadius: s(10)).fill()

        // File rows.
        let rowH = s(30)
        let rowGap = s(26)
        var rowY = headerY - rowGap - rowH
        for i in 0..<4 {
            let row = NSRect(x: x, y: rowY, width: innerW, height: rowH)
            if highlight == i {
                NSColor(srgbRed: 0.24, green: 0.50, blue: 1.0, alpha: 1).setFill()
                NSBezierPath(roundedRect: row, xRadius: s(8), yRadius: s(8)).fill()
                NSColor.white.setFill()
                let line = NSRect(x: x + s(14), y: row.midY - s(6), width: innerW * 0.55, height: s(12))
                NSBezierPath(roundedRect: line, xRadius: s(6), yRadius: s(6)).fill()
            } else {
                NSColor(srgbRed: 0.78, green: 0.81, blue: 0.86, alpha: 1).setFill()
                let w = innerW * (i % 2 == 0 ? 0.85 : 0.62)
                let line = NSRect(x: x, y: row.midY - s(6), width: w, height: s(12))
                NSBezierPath(roundedRect: line, xRadius: s(6), yRadius: s(6)).fill()
            }
            rowY -= rowGap + rowH
        }
    }

    private static func drawArrows(centerX cx: CGFloat, centerY cy: CGFloat, k: CGFloat) {
        func s(_ v: CGFloat) -> CGFloat { v * k }
        NSColor.white.setStroke()
        let len = s(58), head = s(22), dy = s(42)

        func arrow(y: CGFloat, pointingRight: Bool) {
            let p = NSBezierPath()
            p.lineWidth = s(20)
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            let tail = pointingRight ? cx - len / 2 : cx + len / 2
            let tip = pointingRight ? cx + len / 2 : cx - len / 2
            p.move(to: NSPoint(x: tail, y: y))
            p.line(to: NSPoint(x: tip, y: y))
            let back = pointingRight ? tip - head : tip + head
            p.move(to: NSPoint(x: back, y: y + head))
            p.line(to: NSPoint(x: tip, y: y))
            p.line(to: NSPoint(x: back, y: y - head))
            p.stroke()
        }

        arrow(y: cy + dy, pointingRight: true)
        arrow(y: cy - dy, pointingRight: false)
    }
}
