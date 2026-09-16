import AppKit

/// Draws the batch with ReportRenderer, so the window and the exported sheet
/// are the same code path.
final class ReportListView: NSView {

    var reports: [TrackReport] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var onSelect: (Int?) -> Void = { _ in }
    var onOpenInNyquist: (TrackReport) -> Void = { _ in }
    var placeholder = "Choose a folder of masters"

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: max(CGFloat(reports.count) * ReportRenderer.rowHeight, 1))
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(ReportRenderer.Palette.background.cgColor)
        ctx.fill(bounds)

        guard !reports.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(white: 0.42, alpha: 1)]
            let size = (placeholder as NSString).size(withAttributes: attrs)
            (placeholder as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2 - 10),
                withAttributes: attrs)
            return
        }

        // The view is flipped for natural top-down scrolling; the renderer is not,
        // so flip back around each row before drawing it.
        for (i, r) in reports.enumerated() {
            let rowRect = NSRect(x: 0, y: CGFloat(i) * ReportRenderer.rowHeight,
                                 width: bounds.width, height: ReportRenderer.rowHeight)
            guard rowRect.intersects(dirty) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rowRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ReportRenderer.drawRow(r, in: CGRect(x: 0, y: 0, width: bounds.width,
                                                 height: ReportRenderer.rowHeight),
                                   ctx: ctx, index: i, scale: 1, selected: i == selectedIndex)
            ctx.restoreGState()
        }
    }

    private func index(at point: NSPoint) -> Int? {
        let i = Int(point.y / ReportRenderer.rowHeight)
        return reports.indices.contains(i) ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        selectedIndex = i
        onSelect(i)
        if event.clickCount == 2, let i { onOpenInNyquist(reports[i]) }
    }

    override func keyDown(with event: NSEvent) {
        guard !reports.isEmpty else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 125: // down
            selectedIndex = min((selectedIndex ?? -1) + 1, reports.count - 1)
        case 126: // up
            selectedIndex = max((selectedIndex ?? reports.count) - 1, 0)
        default:
            return super.keyDown(with: event)
        }
        onSelect(selectedIndex)
        if let i = selectedIndex {
            scrollToVisible(NSRect(x: 0, y: CGFloat(i) * ReportRenderer.rowHeight,
                                   width: 1, height: ReportRenderer.rowHeight))
        }
    }
}
