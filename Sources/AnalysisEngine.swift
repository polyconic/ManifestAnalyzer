import AppKit
import Foundation

struct TrackReport {
    var url: URL
    var displayName: String
    var relativePath: String
    var duration: Double
    var sampleRate: Double
    var bitDepth: Int
    var channelCount: Int
    var codec: String
    var loudness: Loudness.Result
    var stereo: StereoAnalysis.Result
    var spectrogram: CGImage?
    var vectorscope: CGImage?
    var checks: [Check]

    var verdict: Severity { checks.map(\.severity).max() ?? .pass }

    var formattedDuration: String {
        let m = Int(duration) / 60, s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
    var formatSummary: String {
        let khz = sampleRate >= 1000
            ? String(format: "%.1f kHz", sampleRate / 1000).replacingOccurrences(of: ".0 kHz", with: " kHz")
            : "\(Int(sampleRate)) Hz"
        return bitDepth > 0 ? "\(khz) · \(bitDepth)-bit" : khz
    }
}

enum AnalysisEngine {

    static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "aifc", "flac", "mp3", "m4a", "aac",
        "caf", "ogg", "opus", "wv", "alac", "w64",
    ]

    static func findAudioFiles(in root: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        if recursive {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            for case let u as URL in e where audioExtensions.contains(u.pathExtension.lowercased()) {
                found.append(u)
            }
        } else {
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles])) ?? []
            found = items.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func analyze(url: URL, root: URL?, profile: QAProfile,
                        colormap: String, spectrogramSize: CGSize) throws -> TrackReport {
        let audio = try StereoLoader.load(url: url)

        let loudness = Loudness.measure(channels: audio.channels, sampleRate: audio.sampleRate)
        let stereo = StereoAnalysis.analyze(channels: audio.channels, sampleRate: audio.sampleRate)

        // Spectrogram runs on the mixdown, matching what Nyquist shows.
        let sg = Spectrogram.analyze(samples: audio.mixdown(), sampleRate: audio.sampleRate,
                                     settings: AnalysisSettings(fftSize: 2048, overlap: 2, window: .hann))
        var render = RenderSettings()
        render.colormapName = colormap
        let spectrogram = SpectrogramThumb.image(sg, settings: render,
                                                 width: Int(spectrogramSize.width),
                                                 height: Int(spectrogramSize.height))

        let scope = scopeImage(stereo, colormap: Colormap.named(colormap))

        var relative = url.lastPathComponent
        if let root, url.path.hasPrefix(root.path) {
            relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return TrackReport(
            url: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            relativePath: relative,
            duration: audio.duration,
            sampleRate: audio.sampleRate,
            bitDepth: audio.bitDepth,
            channelCount: audio.channelCount,
            codec: audio.codecDescription,
            loudness: loudness,
            stereo: stereo,
            spectrogram: spectrogram,
            vectorscope: scope,
            checks: profile.evaluate(loudness: loudness, stereo: stereo,
                                     bitDepth: audio.bitDepth, sampleRate: audio.sampleRate))
    }

    private static func scopeImage(_ s: StereoAnalysis.Result, colormap: Colormap) -> CGImage? {
        let size = s.vectorscopeSize
        guard s.vectorscope.count == size * size else { return nil }
        let lut = colormap.lut()
        var pixels = [UInt32](repeating: lut[0], count: size * size)
        for i in 0..<pixels.count {
            let v = min(max(Double(s.vectorscope[i]), 0), 1)
            pixels[i] = lut[Int(v * 255)]
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: cs, bitmapInfo: info.rawValue)?.makeImage()
        }
    }

    /// Batch-level checks that only make sense across the whole folder.
    static func batchChecks(_ reports: [TrackReport]) -> [Check] {
        guard reports.count > 1 else { return [] }
        var checks: [Check] = []

        let rates = Set(reports.map(\.sampleRate))
        if rates.count > 1 {
            let list = rates.sorted().map { String(format: "%.1f kHz", $0 / 1000) }.joined(separator: ", ")
            checks.append(Check(severity: .warn, title: "Mixed sample rates",
                                detail: "This folder contains \(list). A release should normally be consistent."))
        }
        let depths = Set(reports.map(\.bitDepth)).filter { $0 > 0 }
        if depths.count > 1 {
            checks.append(Check(severity: .warn, title: "Mixed bit depths",
                                detail: "This folder contains \(depths.sorted().map { "\($0)-bit" }.joined(separator: ", "))."))
        }
        let loudnesses = reports.map(\.loudness.integratedLUFS).filter { $0.isFinite }
        if let lo = loudnesses.min(), let hi = loudnesses.max(), hi - lo > 2.0 {
            checks.append(Check(
                severity: .warn,
                title: String(format: "Loudness spread %.1f LU across the batch", hi - lo),
                detail: String(format: "Quietest %.1f LUFS, loudest %.1f LUFS. On a release played end to end that step will be audible.", lo, hi)))
        }
        return checks
    }
}
