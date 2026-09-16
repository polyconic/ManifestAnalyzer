import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let stops: [(Double, Double, Double, Double)] = [
    (0.00, 0, 0, 0), (0.16, 28, 12, 74), (0.32, 74, 16, 124), (0.48, 136, 26, 128),
    (0.64, 198, 44, 100), (0.76, 234, 78, 58), (0.88, 250, 134, 28),
    (0.96, 254, 209, 64), (1.00, 255, 255, 220)]

func heat(_ t: Double) -> NSColor {
    let v = min(max(t, 0), 1)
    var seg = 0
    while seg < stops.count - 2 && v > stops[seg + 1].0 { seg += 1 }
    let a = stops[seg], b = stops[seg + 1]
    let f = (v - a.0) / max(b.0 - a.0, 1e-9)
    return NSColor(srgbRed: CGFloat(a.1 + (b.1 - a.1) * f) / 255,
                   green: CGFloat(a.2 + (b.2 - a.2) * f) / 255,
                   blue: CGFloat(a.3 + (b.3 - a.3) * f) / 255, alpha: 1)
}

/// Each row is one track's spectrogram strip, with a verdict mark beside it.
func rowEnergy(_ x: Double, _ y: Double, seed: Double) -> Double {
    var e = 0.9 * exp(-y * 2.2)
    let pulse = pow(max(0, sin(x * Double.pi * (7.0 + seed * 3))), 14.0)
    e += 0.35 * pulse * exp(-y * 1.3)
    e += 0.4 * exp(-pow((y - 0.08) / 0.05, 2))
    e *= 0.8 + 0.2 * sin(x * 3.1 + seed * 2)
    return min(max(e, 0), 1)
}

let verdicts: [NSColor] = [
    NSColor(srgbRed: 0.30, green: 0.80, blue: 0.48, alpha: 1),
    NSColor(srgbRed: 0.98, green: 0.74, blue: 0.24, alpha: 1),
    NSColor(srgbRed: 0.30, green: 0.80, blue: 0.48, alpha: 1),
    NSColor(srgbRed: 0.98, green: 0.35, blue: 0.35, alpha: 1),
]

func render(_ size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = s * 0.055
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.height * 0.2237)
    ctx.saveGState()
    path.addClip()
    NSColor(srgbRed: 0.055, green: 0.05, blue: 0.075, alpha: 1).setFill()
    rect.fill()

    let pad = rect.width * 0.11
    let area = rect.insetBy(dx: pad, dy: pad)
    let rows = 4
    let gap = area.height * 0.07
    let rowH = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
    let markW = area.width * 0.14

    for r in 0..<rows {
        let y = area.maxY - CGFloat(r + 1) * rowH - CGFloat(r) * gap
        let strip = NSRect(x: area.minX, y: y, width: area.width - markW - area.width * 0.05, height: rowH)

        let cols = max(14, size / 6)
        let cells = max(6, Int(rowH / 2))
        let cw = strip.width / CGFloat(cols)
        let ch = strip.height / CGFloat(cells)
        for i in 0..<cols {
            let fx = Double(i) / Double(cols - 1)
            for j in 0..<cells {
                let fy = Double(j) / Double(cells - 1)
                heat(rowEnergy(fx, 1.0 - fy, seed: Double(r) * 0.7)).setFill()
                NSRect(x: strip.minX + CGFloat(i) * cw, y: strip.minY + CGFloat(j) * ch,
                       width: cw + 0.8, height: ch + 0.8).fill()
            }
        }

        // Verdict mark: a rounded bar in the status colour.
        let mark = NSRect(x: area.maxX - markW, y: y + rowH * 0.28,
                          width: markW, height: rowH * 0.44)
        verdicts[r].setFill()
        NSBezierPath(roundedRect: mark, xRadius: mark.height / 2, yRadius: mark.height / 2).fill()
    }

    let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.09), NSColor(white: 1, alpha: 0)])
    gloss?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    ctx.restoreGState()

    NSColor(white: 1, alpha: 0.16).setStroke()
    path.lineWidth = max(1, s * 0.006)
    path.stroke()
    image.unlockFocus()
    return image
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let img = render(size)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(size).png"))
}
print("icons written")
