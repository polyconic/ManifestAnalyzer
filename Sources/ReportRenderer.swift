import AppKit
import CoreGraphics

/// Draws one track as a horizontal strip, and a whole batch as a contact sheet.
enum ReportRenderer {

    static let rowHeight: CGFloat = 132
    static let headerHeight: CGFloat = 64
    static let footerHeight: CGFloat = 30

    struct Palette {
        static let background = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.07, alpha: 1)
        static let row = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        static let rowAlt = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.095, alpha: 1)
        static let text = NSColor(white: 0.94, alpha: 1)
        static let dim = NSColor(white: 0.58, alpha: 1)
        static let pass = NSColor(srgbRed: 0.30, green: 0.80, blue: 0.48, alpha: 1)
        static let warn = NSColor(srgbRed: 0.98, green: 0.74, blue: 0.24, alpha: 1)
        static let fail = NSColor(srgbRed: 0.98, green: 0.35, blue: 0.35, alpha: 1)

        static func color(for s: Severity) -> NSColor {
            switch s { case .pass: return pass; case .warn: return warn; case .fail: return fail }
        }
    }

    static func drawRow(_ r: TrackReport, in rect: CGRect, ctx: CGContext,
                        index: Int, scale: CGFloat = 1, selected: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setFillColor((selected ? NSColor(srgbRed: 0.14, green: 0.15, blue: 0.19, alpha: 1)
                                   : (index % 2 == 0 ? Palette.row : Palette.rowAlt)).cgColor)
        ctx.fill(rect)

        let pad: CGFloat = 12 * scale
        var x = rect.minX + pad
        let top = rect.maxY - pad
        let inner = rect.height - pad * 2

        // Verdict stripe down the left edge.
        ctx.setFillColor(Palette.color(for: r.verdict).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 3 * scale, height: rect.height))

        // Spectrogram.
        let sgWidth = 210 * scale
        if let img = r.spectrogram {
            let box = CGRect(x: x, y: rect.minY + pad, width: sgWidth, height: inner)
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: box)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box)
        }
        x += sgWidth + pad

        // Vectorscope, square.
        if let img = r.vectorscope {
            let box = CGRect(x: x, y: rect.minY + pad, width: inner, height: inner)
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: box)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box)
            // A vertical guide: mono content collapses onto this line.
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
            ctx.move(to: CGPoint(x: box.midX, y: box.minY))
            ctx.addLine(to: CGPoint(x: box.midX, y: box.maxY))
            ctx.strokePath()
            x += inner + pad
        }

        // Title block. Long names wrap within the column instead of running into
        // the numbers; everything below moves down by however much they took.
        let titleWidth = 250 * scale
        var cursorY = top
        cursorY -= drawWrapped(r.displayName, x: x, top: cursorY, width: titleWidth,
                               font: .systemFont(ofSize: 13 * scale, weight: .semibold),
                               color: Palette.text, maxLines: 2, ctx: ctx)
        cursorY -= 3 * scale
        cursorY -= drawWrapped("\(r.relativePath)  ·  \(r.formatSummary)", x: x, top: cursorY,
                               width: titleWidth, font: .systemFont(ofSize: 10 * scale),
                               color: Palette.dim, maxLines: 2, ctx: ctx)
        cursorY -= 3 * scale
        _ = drawWrapped("\(r.formattedDuration)  ·  \(r.channelCount == 1 ? "mono" : "stereo")",
                        x: x, top: cursorY, width: titleWidth, font: .systemFont(ofSize: 10 * scale),
                        color: Palette.dim, maxLines: 1, ctx: ctx)

        // Verdict chip.
        let chip = CGRect(x: x, y: rect.minY + pad, width: 54 * scale, height: 18 * scale)
        let chipPath = CGPath(roundedRect: chip, cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
        ctx.addPath(chipPath)
        ctx.setFillColor(Palette.color(for: r.verdict).withAlphaComponent(0.18).cgColor)
        ctx.fillPath()
        ctx.addPath(chipPath)
        ctx.setStrokeColor(Palette.color(for: r.verdict).withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        drawCentered(r.verdict.label, in: chip, font: .systemFont(ofSize: 9 * scale, weight: .bold),
                     color: Palette.color(for: r.verdict), ctx: ctx)
        x += titleWidth + pad

        // Numbers.
        let metrics: [(String, String, Severity)] = [
            ("LUFS", r.loudness.integratedLUFS.isFinite
                ? String(format: "%.1f", r.loudness.integratedLUFS) : "—", .pass),
            ("TRUE PEAK", String(format: "%+.2f", r.loudness.truePeakDBTP),
             r.loudness.truePeakDBTP > 0 ? .fail : (r.loudness.truePeakDBTP > -1 ? .warn : .pass)),
            ("LRA", String(format: "%.1f", r.loudness.loudnessRangeLU), .pass),
            ("CORR", String(format: "%+.2f", r.stereo.overall), .pass),
            ("BASS CORR", String(format: "%+.2f", r.stereo.lowOverall),
             r.stereo.lowFractionNegative > 0.05 ? .fail
                 : (r.stereo.lowFractionNegative > 0.01 ? .warn : .pass)),
            // Below -60 dB of side the channels are identical for any practical purpose.
            ("WIDTH", r.stereo.sideToMidDB > -60
                ? String(format: "%.0f dB", r.stereo.sideToMidDB) : "mono", .pass),
        ]
        let colWidth = 70 * scale
        for (label, value, sev) in metrics {
            draw(label, at: CGPoint(x: x, y: top - 14 * scale),
                 font: .systemFont(ofSize: 8.5 * scale, weight: .semibold), color: Palette.dim, ctx: ctx)
            draw(value, at: CGPoint(x: x, y: top - 34 * scale),
                 font: .monospacedDigitSystemFont(ofSize: 15 * scale, weight: .medium),
                 color: sev == .pass ? Palette.text : Palette.color(for: sev), ctx: ctx)
            x += colWidth
        }

        // Loudness envelope and correlation strips.
        let stripX = x + pad
        let stripWidth = max(60 * scale, rect.maxX - stripX - pad)
        if stripWidth > 40 * scale {
            drawEnvelope(r, in: CGRect(x: stripX, y: rect.midY + 2 * scale,
                                       width: stripWidth, height: inner / 2 - 2 * scale),
                         ctx: ctx, scale: scale)
            drawCorrelation(r, in: CGRect(x: stripX, y: rect.minY + pad,
                                          width: stripWidth, height: inner / 2 - 4 * scale),
                            ctx: ctx, scale: scale)
        }
    }

    /// Short-term loudness over time, on a fixed −40…0 LUFS scale so rows compare.
    private static func drawEnvelope(_ r: TrackReport, in box: CGRect, ctx: CGContext, scale: CGFloat) {
        let values = r.loudness.shortTerm
        guard values.count > 1 else { return }
        let lo = -40.0, hi = 0.0

        ctx.setFillColor(NSColor(white: 1, alpha: 0.04).cgColor)
        ctx.fill(box)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: box.minX, y: box.minY))
        for i in 0..<values.count {
            let v = Double(values[i])
            let norm = v.isFinite ? min(max((v - lo) / (hi - lo), 0), 1) : 0
            let px = box.minX + box.width * CGFloat(i) / CGFloat(values.count - 1)
            path.addLine(to: CGPoint(x: px, y: box.minY + box.height * CGFloat(norm)))
        }
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.55, blue: 0.25, alpha: 0.55).cgColor)
        ctx.fillPath()

        draw("LOUDNESS", at: CGPoint(x: box.minX + 4 * scale, y: box.maxY - 12 * scale),
             font: .systemFont(ofSize: 8 * scale, weight: .semibold),
             color: NSColor(white: 1, alpha: 0.45), ctx: ctx)
    }

    /// Correlation over time, centered on zero. Below the line is the problem.
    private static func drawCorrelation(_ r: TrackReport, in box: CGRect, ctx: CGContext, scale: CGFloat) {
        let values = r.stereo.overTime
        guard values.count > 1 else { return }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.04).cgColor)
        ctx.fill(box)

        let zeroY = box.minY + box.height * 0.5
        for i in 0..<values.count {
            let v = CGFloat(min(max(values[i], -1), 1))
            let px = box.minX + box.width * CGFloat(i) / CGFloat(values.count)
            let h = box.height * 0.5 * v
            ctx.setFillColor((v < 0 ? Palette.fail : NSColor(srgbRed: 0.35, green: 0.72, blue: 0.95, alpha: 1))
                                .withAlphaComponent(0.75).cgColor)
            ctx.fill(CGRect(x: px, y: min(zeroY, zeroY + h),
                            width: max(1, box.width / CGFloat(values.count) + 0.5), height: abs(h)))
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: box.minX, y: zeroY))
        ctx.addLine(to: CGPoint(x: box.maxX, y: zeroY))
        ctx.strokePath()

        draw("CORRELATION", at: CGPoint(x: box.minX + 4 * scale, y: box.maxY - 11 * scale),
             font: .systemFont(ofSize: 8 * scale, weight: .semibold),
             color: NSColor(white: 1, alpha: 0.45), ctx: ctx)
    }

    // MARK: - Contact sheet

    static func contactSheetSize(rows: Int, width: CGFloat, batchNotes: Int) -> CGSize {
        CGSize(width: width,
               height: headerHeight + CGFloat(rows) * rowHeight
                     + CGFloat(batchNotes) * 22 + footerHeight)
    }

    static func drawContactSheet(_ reports: [TrackReport], batch: [Check], profile: QAProfile,
                                 folder: String, in ctx: CGContext, size: CGSize, scale: CGFloat) {
        ctx.setFillColor(Palette.background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        let pad: CGFloat = 16 * scale
        var y = size.height - pad

        draw(folder, at: CGPoint(x: pad, y: y - 19 * scale),
             font: .systemFont(ofSize: 15 * scale, weight: .bold), color: Palette.text, ctx: ctx)
        let counts = Dictionary(grouping: reports, by: \.verdict).mapValues(\.count)
        let summary = "\(reports.count) tracks   ·   "
            + "\(counts[.pass] ?? 0) pass, \(counts[.warn] ?? 0) warn, \(counts[.fail] ?? 0) fail"
            + "   ·   \(profile.name)"
        draw(summary, at: CGPoint(x: pad, y: y - 37 * scale),
             font: .systemFont(ofSize: 11 * scale), color: Palette.dim, ctx: ctx)

        let brand = "\(AppInfo.name) \(AppInfo.version)"
        let bw = (brand as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11 * scale)]).width
        draw(brand, at: CGPoint(x: size.width - pad - bw, y: y - 19 * scale),
             font: .systemFont(ofSize: 11 * scale), color: Palette.dim, ctx: ctx)

        y -= headerHeight * scale

        for (i, r) in reports.enumerated() {
            let rect = CGRect(x: 0, y: y - rowHeight * scale, width: size.width, height: rowHeight * scale)
            drawRow(r, in: rect, ctx: ctx, index: i, scale: scale)
            y -= rowHeight * scale
        }

        if !batch.isEmpty {
            y -= 8 * scale
            for c in batch {
                ctx.setFillColor(Palette.color(for: c.severity).cgColor)
                ctx.fillEllipse(in: CGRect(x: pad, y: y - 11 * scale, width: 6 * scale, height: 6 * scale))
                draw("\(c.title) — \(c.detail)", at: CGPoint(x: pad + 14 * scale, y: y - 14 * scale),
                     font: .systemFont(ofSize: 10 * scale), color: Palette.dim, ctx: ctx,
                     maxWidth: size.width - pad * 2 - 14 * scale)
                y -= 22 * scale
            }
        }
    }

    // MARK: - Text

    static func draw(_ text: String, at p: CGPoint, font: NSFont, color: NSColor,
                     ctx: CGContext, maxWidth: CGFloat? = nil) {
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var s = text
        if let maxWidth {
            while (s as NSString).size(withAttributes: attrs).width > maxWidth && s.count > 4 {
                s = String(s.dropLast(2))
            }
            if s != text { s += "…" }
        }
        (s as NSString).draw(at: p, withAttributes: attrs)
        NSGraphicsContext.current = saved
    }

    /// Draws text wrapped to `width`, hanging down from `top`, and returns the height used.
    @discardableResult
    static func drawWrapped(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat,
                            font: NSFont, color: NSColor, maxLines: Int, ctx: CGContext) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
                                                    .paragraphStyle: para]
        let str = NSAttributedString(string: text, attributes: attrs)
        // Measure a line the same way the text will be laid out; defaultLineHeight
        // can come out a fraction short and silently drop the last line.
        let lineHeight = NSAttributedString(string: "Ag", attributes: attrs)
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin]).height
        let natural = str.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height
        let height = ceil(min(natural, lineHeight * CGFloat(maxLines)) + 0.5)

        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(with: CGRect(x: x, y: top - height, width: width, height: height),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.current = saved
        return height
    }

    static func drawCentered(_ text: String, in rect: CGRect, font: NSFont,
                             color: NSColor, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        draw(text, at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
             font: font, color: color, ctx: ctx)
    }
}
