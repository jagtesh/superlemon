// PowerlineShapeView — the classic Powerline glyphs (U+E0A0–A2, U+E0B0–B3)
// drawn as vector shapes in the native status bar. Harvested airline
// statuslines carry these as transition segments (fg = one section's color,
// bg = the next's); most fonts lack the glyphs, so the bar synthesizes them
// exactly like the grid renderer does (SurfaceKit TextRasterizer).

import AppKit

enum PowerlineGlyph {
    static let scalars: Set<Unicode.Scalar> = [
        "\u{E0A0}", "\u{E0A1}", "\u{E0A2}", "\u{E0B0}", "\u{E0B1}", "\u{E0B2}", "\u{E0B3}",
    ]

    static func isGlyph(_ scalar: Unicode.Scalar) -> Bool { scalars.contains(scalar) }

    /// Split text into runs of plain text and single powerline scalars.
    static func tokenize(_ text: String) -> [(text: String, isGlyph: Bool)] {
        var tokens: [(String, Bool)] = []
        var pending = ""
        for scalar in text.unicodeScalars {
            if isGlyph(scalar) {
                if !pending.isEmpty { tokens.append((pending, false)) }
                pending = ""
                tokens.append((String(scalar), true))
            } else {
                pending.unicodeScalars.append(scalar)
            }
        }
        if !pending.isEmpty { tokens.append((pending, false)) }
        return tokens
    }
}

@MainActor
final class PowerlineShapeView: NSView {
    let scalar: Unicode.Scalar
    let color: NSColor

    init(scalar: Unicode.Scalar, color: NSColor, height: CGFloat) {
        self.scalar = scalar
        self.color = color
        let width: CGFloat
        switch scalar {
        case "\u{E0B0}", "\u{E0B2}": width = height * 0.5  // solid triangles
        case "\u{E0B1}", "\u{E0B3}": width = height * 0.45  // chevrons
        default: width = height * 0.62  // branch / LN / padlock
        }
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        setAccessibilityIdentifier("status.powerlineGlyph")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let path = NSBezierPath()
        let thickness = max(1.2, r.height * 0.06)
        path.lineWidth = thickness
        color.set()

        switch scalar {
        case "\u{E0B0}":
            path.move(to: NSPoint(x: r.minX, y: r.minY))
            path.line(to: NSPoint(x: r.minX, y: r.maxY))
            path.line(to: NSPoint(x: r.maxX, y: r.midY))
            path.close()
            path.fill()
        case "\u{E0B2}":
            path.move(to: NSPoint(x: r.maxX, y: r.minY))
            path.line(to: NSPoint(x: r.maxX, y: r.maxY))
            path.line(to: NSPoint(x: r.minX, y: r.midY))
            path.close()
            path.fill()
        case "\u{E0B1}", "\u{E0B3}":
            let pointLeft = scalar == "\u{E0B3}"
            let tipX = pointLeft ? r.minX + 1 : r.maxX - 1
            let backX = pointLeft ? r.maxX - 1 : r.minX + 1
            path.move(to: NSPoint(x: backX, y: r.maxY - 2))
            path.line(to: NSPoint(x: tipX, y: r.midY))
            path.line(to: NSPoint(x: backX, y: r.minY + 2))
            path.stroke()
        case "\u{E0A0}":  // branch
            let x1 = r.minX + r.width * 0.32
            let x2 = r.minX + r.width * 0.72
            path.move(to: NSPoint(x: x1, y: r.minY + r.height * 0.15))
            path.line(to: NSPoint(x: x1, y: r.maxY - r.height * 0.15))
            path.move(to: NSPoint(x: x2, y: r.minY + r.height * 0.15))
            path.line(to: NSPoint(x: x2, y: r.midY))
            path.line(to: NSPoint(x: x1, y: r.midY + r.height * 0.18))
            path.stroke()
        case "\u{E0A1}":  // line-number
            let inset = r.width * 0.15
            for frac: CGFloat in [0.32, 0.5, 0.68] {
                let y = r.minY + r.height * frac
                let short: CGFloat = frac == 0.5 ? r.width * 0.16 : 0
                path.move(to: NSPoint(x: r.minX + inset, y: y))
                path.line(to: NSPoint(x: r.maxX - inset - short, y: y))
            }
            path.stroke()
        case "\u{E0A2}":  // padlock
            let bodyW = r.width * 0.6
            let bodyH = r.height * 0.32
            let body = NSRect(
                x: r.midX - bodyW / 2, y: r.minY + r.height * 0.2,
                width: bodyW, height: bodyH)
            path.appendRect(body)
            path.appendArc(
                withCenter: NSPoint(x: r.midX, y: body.maxY),
                radius: bodyW * 0.32, startAngle: 0, endAngle: 180)
            path.stroke()
        default:
            break
        }
    }
}
