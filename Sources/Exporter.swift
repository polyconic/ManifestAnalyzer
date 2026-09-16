import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Exporter {

    enum ExportError: LocalizedError {
        case allocationFailed, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .allocationFailed: return "Could not allocate a bitmap that size. Try fewer tracks."
            case .writeFailed(let m): return m
            }
        }
    }

    static func writeContactSheet(to url: URL, reports: [TrackReport], batch: [Check],
                                  profile: QAProfile, folder: String,
                                  width: CGFloat = 1600, scale: CGFloat = 2) throws {
        let size = ReportRenderer.contactSheetSize(rows: reports.count, width: width,
                                                   batchNotes: batch.count)
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard pw > 0, ph > 0, pw * ph <= 250_000_000 else { throw ExportError.allocationFailed }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: pw * 4, space: cs, bitmapInfo: info.rawValue) else {
            throw ExportError.allocationFailed
        }
        ReportRenderer.drawContactSheet(reports, batch: batch, profile: profile, folder: folder,
                                        in: ctx, size: CGSize(width: size.width * scale,
                                                              height: size.height * scale),
                                        scale: scale)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.writeFailed("Could not create \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed("Could not write \(url.lastPathComponent).")
        }
    }

    static func writeCSV(to url: URL, reports: [TrackReport]) throws {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"")
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : s
        }
        var lines = ["file,duration_s,sample_rate,bit_depth,channels,"
                   + "integrated_lufs,lra_lu,true_peak_dbtp,sample_peak_dbfs,"
                   + "max_short_term_lufs,correlation,min_correlation,width_db,verdict,issues"]
        for r in reports {
            let issues = r.checks.filter { $0.severity != .pass }
                .map { "\($0.severity.label): \($0.title)" }.joined(separator: "; ")
            func f(_ v: Double, _ p: Int = 2) -> String {
                v.isFinite ? String(format: "%.\(p)f", v) : ""
            }
            lines.append([
                esc(r.relativePath), f(r.duration, 1), String(Int(r.sampleRate)),
                String(r.bitDepth), String(r.channelCount),
                f(r.loudness.integratedLUFS), f(r.loudness.loudnessRangeLU),
                f(r.loudness.truePeakDBTP), f(r.loudness.samplePeakDBFS),
                f(r.loudness.maxShortTermLUFS), f(r.stereo.overall, 3),
                f(r.stereo.minimum, 3), f(r.stereo.sideToMidDB, 1),
                r.verdict.label, esc(issues),
            ].joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
