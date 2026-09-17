import AppKit
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let listView = ReportListView()
    private let scrollView = NSScrollView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let batchLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    private let profilePopup = NSPopUpButton()
    private let colormapPopup = NSPopUpButton()
    private let recursiveCheck = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)

    private var reports: [TrackReport] = []
    private var batch: [Check] = []
    private var folder: URL?
    private var profile = QAProfile.club
    private var colormap = "SoX"
    private var scanToken = 0

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1480, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = AppInfo.name
        w.minSize = NSSize(width: 1100, height: 520)
        w.appearance = NSAppearance(named: .darkAqua)
        w.center()
        w.setFrameAutosaveName("ManifestMainWindow")
        self.init(window: w)
        w.delegate = self
        buildUI()
    }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        let bar = buildToolbar()
        let detail = buildDetailPanel()
        let status = buildStatusBar()

        scrollView.documentView = listView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ReportRenderer.Palette.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.onSelect = { [weak self] i in self?.showDetail(i) }
        listView.onOpenInNyquist = { [weak self] r in self?.openInNyquist(r) }
        listView.registerForDraggedTypes([.fileURL])

        content.addSubview(bar)
        content.addSubview(scrollView)
        content.addSubview(detail)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),

            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: detail.topAnchor),

            listView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.topAnchor),

            detail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: status.topAnchor),
            detail.heightAnchor.constraint(equalToConstant: 120),

            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private func group(_ caption: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: caption.uppercased())
        l.font = .systemFont(ofSize: 9, weight: .semibold)
        l.textColor = NSColor(white: 0.55, alpha: 1)
        let s = NSStackView(views: [l, control])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        return s
    }

    private func buildToolbar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        let open = NSButton(title: "Open Folder…", target: self, action: #selector(openFolder))
        open.bezelStyle = .rounded
        let rescanButton = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        rescanButton.bezelStyle = .rounded
        let export = NSButton(title: "Export Sheet…", target: self, action: #selector(exportSheet))
        export.bezelStyle = .rounded
        let csv = NSButton(title: "CSV…", target: self, action: #selector(exportCSV))
        csv.bezelStyle = .rounded

        for p in QAProfile.all { profilePopup.addItem(withTitle: p.name) }
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)

        for c in Colormap.all { colormapPopup.addItem(withTitle: c.name) }
        colormapPopup.selectItem(withTitle: colormap)
        colormapPopup.target = self
        colormapPopup.action = #selector(rescan)

        recursiveCheck.state = .on
        recursiveCheck.target = self
        recursiveCheck.action = #selector(rescan)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true

        func divider() -> NSView {
            let v = NSBox()
            v.boxType = .separator
            v.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return v
        }

        let stack = NSStackView(views: [
            open, rescanButton, progress, divider(),
            group("Profile", profilePopup),
            group("Color", colormapPopup),
            recursiveCheck, divider(),
            export, csv,
        ])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func buildDetailPanel() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.125, alpha: 1).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = NSColor(white: 0.82, alpha: 1)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = "Select a track to see its checks. Double-click to open it in Nyquist."

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = detailLabel
        scroll.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            detailLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -4),
        ])
        return box
    }

    private func buildStatusBar() -> NSView {
        let box = NSVisualEffectView()
        box.material = .titlebar
        box.blendingMode = .withinWindow
        box.state = .active
        box.translatesAutoresizingMaskIntoConstraints = false
        for l in [statusLabel, batchLabel] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = NSColor(white: 0.72, alpha: 1)
        }
        batchLabel.alignment = .right
        let s = NSStackView(views: [statusLabel, NSView(), batchLabel])
        s.orientation = .horizontal
        s.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        s.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            s.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    // MARK: - Scanning

    @objc func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder of masters to check"
        panel.begin { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.folder = url
            self?.rescan()
        }
    }

    func open(folder url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        rescan()
    }

    @objc private func profileChanged() {
        profile = QAProfile.named(profilePopup.titleOfSelectedItem ?? profile.name)
        // Re-evaluating is cheap; no need to decode anything again.
        guard !reports.isEmpty else { return }
        for i in reports.indices {
            reports[i].checks = profile.evaluate(loudness: reports[i].loudness,
                                                 stereo: reports[i].stereo,
                                                 bitDepth: reports[i].bitDepth,
                                                 sampleRate: reports[i].sampleRate)
        }
        listView.reports = reports
        updateStatus()
        showDetail(listView.selectedIndex)
    }

    @objc func rescan() {
        guard let folder else { return }
        colormap = colormapPopup.titleOfSelectedItem ?? colormap
        profile = QAProfile.named(profilePopup.titleOfSelectedItem ?? profile.name)

        scanToken += 1
        let token = scanToken
        let recursive = recursiveCheck.state == .on
        let files = AnalysisEngine.findAudioFiles(in: folder, recursive: recursive)

        window?.title = "\(AppInfo.name) — \(folder.lastPathComponent)"
        reports = []
        listView.reports = []
        guard !files.isEmpty else {
            statusLabel.stringValue = "No audio files found in \(folder.lastPathComponent)."
            batchLabel.stringValue = ""
            return
        }

        progress.startAnimation(nil)
        statusLabel.stringValue = "Analyzing 0 of \(files.count)…"
        let cmap = colormap
        let prof = profile

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var collected: [TrackReport] = []
            var failures: [String] = []
            for (n, f) in files.enumerated() {
                guard let self, token == self.scanToken else { return }
                do {
                    let r = try AnalysisEngine.analyze(url: f, root: folder, profile: prof,
                                                       colormap: cmap,
                                                       spectrogramSize: CGSize(width: 420, height: 216))
                    collected.append(r)
                } catch {
                    failures.append("\(f.lastPathComponent): \(error.localizedDescription)")
                }
                let done = collected
                let count = n + 1
                DispatchQueue.main.async {
                    guard token == self.scanToken else { return }
                    self.statusLabel.stringValue = "Analyzing \(count) of \(files.count)…"
                    self.reports = done
                    self.listView.reports = done
                }
            }
            DispatchQueue.main.async {
                guard let self, token == self.scanToken else { return }
                self.progress.stopAnimation(nil)
                self.reports = collected
                self.batch = AnalysisEngine.batchChecks(collected)
                self.listView.reports = collected
                self.updateStatus(failures: failures)
            }
        }
    }

    private func updateStatus(failures: [String] = []) {
        let counts = Dictionary(grouping: reports, by: \.verdict).mapValues(\.count)
        var parts = ["\(reports.count) tracks",
                     "\(counts[.pass] ?? 0) pass",
                     "\(counts[.warn] ?? 0) warn",
                     "\(counts[.fail] ?? 0) fail"]
        if !failures.isEmpty { parts.append("\(failures.count) unreadable") }
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
        batchLabel.stringValue = batch.isEmpty
            ? profile.note
            : batch.map(\.title).joined(separator: "   ·   ")
    }

    private func showDetail(_ index: Int?) {
        guard let index, reports.indices.contains(index) else {
            detailLabel.stringValue = "Select a track to see its checks. Double-click to open it in Nyquist."
            return
        }
        let r = reports[index]
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "\(r.relativePath)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: ReportRenderer.Palette.text]))
        for c in r.checks.sorted(by: { $0.severity > $1.severity }) {
            out.append(NSAttributedString(
                string: "\n\(c.severity.label)  ",
                attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                             .foregroundColor: ReportRenderer.Palette.color(for: c.severity)]))
            out.append(NSAttributedString(
                string: "\(c.title) — ",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: ReportRenderer.Palette.text]))
            out.append(NSAttributedString(
                string: c.detail,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor(white: 0.72, alpha: 1)]))
        }
        detailLabel.attributedStringValue = out
    }

    private func openInNyquist(_ r: TrackReport) {
        let nyquist = URL(fileURLWithPath: "/Applications/Nyquist.app")
        guard FileManager.default.fileExists(atPath: nyquist.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([r.url]); return
        }
        NSWorkspace.shared.open([r.url], withApplicationAt: nyquist,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Export

    @objc func exportSheet() {
        guard !reports.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.png] }
        panel.nameFieldStringValue = "\(folder?.lastPathComponent ?? "masters") QA.png"
        panel.message = "Export the whole batch as one contact sheet"
        panel.begin { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            do {
                try Exporter.writeContactSheet(to: url, reports: self.reports, batch: self.batch,
                                               profile: self.profile,
                                               folder: self.folder?.lastPathComponent ?? "")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.present(error) }
        }
    }

    @objc func exportCSV() {
        guard !reports.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        if #available(macOS 11.0, *) { panel.allowedContentTypes = [.commaSeparatedText] }
        panel.nameFieldStringValue = "\(folder?.lastPathComponent ?? "masters") QA.csv"
        panel.begin { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            do {
                try Exporter.writeCSV(to: url, reports: self.reports)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.present(error) }
        }
    }

    private func present(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Export failed"
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }
}
