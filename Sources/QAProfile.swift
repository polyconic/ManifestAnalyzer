import Foundation

enum Severity: Int, Comparable {
    case pass = 0, warn = 1, fail = 2
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var label: String { self == .pass ? "PASS" : (self == .warn ? "WARN" : "FAIL") }
}

struct Check {
    var severity: Severity
    var title: String
    var detail: String
}

struct QAProfile {
    var name: String
    /// nil means the profile does not care how loud the track is.
    var targetLUFS: Double?
    var lufsTolerance: Double
    var truePeakCeiling: Double
    var minCorrelation: Double
    var note: String

    static let all: [QAProfile] = [club, streaming, appleMusic, broadcast]
    static func named(_ n: String) -> QAProfile { all.first { $0.name == n } ?? club }

    static let club = QAProfile(
        name: "Club / DJ", targetLUFS: nil, lufsTolerance: 0,
        truePeakCeiling: -0.3, minCorrelation: 0.0,
        note: "Loudness unconstrained. Checks headroom and mono compatibility only.")

    static let streaming = QAProfile(
        name: "Streaming (−14 LUFS)", targetLUFS: -14, lufsTolerance: 1.0,
        truePeakCeiling: -1.0, minCorrelation: 0.0,
        note: "Spotify, YouTube and Amazon normalise to about −14 LUFS.")

    static let appleMusic = QAProfile(
        name: "Apple Music (−16 LUFS)", targetLUFS: -16, lufsTolerance: 1.0,
        truePeakCeiling: -1.0, minCorrelation: 0.0,
        note: "Apple's Sound Check target.")

    static let broadcast = QAProfile(
        name: "Broadcast (−23 LUFS)", targetLUFS: -23, lufsTolerance: 0.5,
        truePeakCeiling: -1.0, minCorrelation: 0.0,
        note: "EBU R128 broadcast delivery.")

    func evaluate(loudness: Loudness.Result, stereo: StereoAnalysis.Result,
                  bitDepth: Int, sampleRate: Double) -> [Check] {
        var checks: [Check] = []

        // True peak.
        let tp = loudness.truePeakDBTP
        if tp > truePeakCeiling {
            let over = tp - truePeakCeiling
            checks.append(Check(
                severity: tp > 0 ? .fail : .warn,
                title: String(format: "True peak %+.2f dBTP", tp),
                detail: tp > 0
                    ? String(format: "Over full scale by %.2f dB. Inter-sample peaks will clip on conversion to MP3/AAC and on many DACs.", tp)
                    : String(format: "%.2f dB above the %.1f dBTP ceiling for this profile.", over, truePeakCeiling)))
        } else {
            checks.append(Check(severity: .pass,
                                title: String(format: "True peak %+.2f dBTP", tp),
                                detail: String(format: "Within the %.1f dBTP ceiling.", truePeakCeiling)))
        }

        // Sample peak at or above full scale suggests the render already clipped.
        if loudness.samplePeakDBFS >= -0.01 {
            checks.append(Check(severity: .warn, title: "Sample peak at full scale",
                                detail: "Samples are hitting 0 dBFS, so the file may already be clipped rather than merely loud."))
        }

        // Integrated loudness.
        if let target = targetLUFS {
            let delta = loudness.integratedLUFS - target
            if abs(delta) <= lufsTolerance {
                checks.append(Check(severity: .pass,
                                    title: String(format: "%.1f LUFS integrated", loudness.integratedLUFS),
                                    detail: String(format: "Within %.1f LU of the %.0f LUFS target.", lufsTolerance, target)))
            } else {
                checks.append(Check(
                    severity: .warn,
                    title: String(format: "%.1f LUFS integrated", loudness.integratedLUFS),
                    detail: delta > 0
                        ? String(format: "%.1f LU louder than target. The platform will turn it down by that much, so the extra limiting buys nothing.", delta)
                        : String(format: "%.1f LU quieter than target.", -delta)))
            }
        } else {
            checks.append(Check(severity: .pass,
                                title: String(format: "%.1f LUFS integrated", loudness.integratedLUFS),
                                detail: "No loudness target in this profile."))
        }

        // Mono compatibility. Judged on how much low-band ENERGY is out of phase,
        // not on the worst block: a dip during a breakdown costs nothing.
        let lostBassPercent = stereo.lowFractionNegative * 100
        if lostBassPercent > 1.0 {
            checks.append(Check(
                severity: lostBassPercent > 5 ? .fail : .warn,
                title: String(format: "%.1f%% of bass energy out of phase", lostBassPercent),
                detail: String(format: "Below %.0f Hz the energy-weighted correlation is %+.2f, worst block %+.2f. Summed to mono on a club system that bass will lose level.",
                               StereoAnalysis.lowBandHz, stereo.lowOverall, stereo.lowMinimum)))
        } else if stereo.minimum < 0 || stereo.lowMinimum < 0 {
            checks.append(Check(
                severity: .pass,
                title: String(format: "Mono-safe — bass correlation %+.3f", stereo.lowOverall),
                detail: String(format: "Correlation dips below zero at moments, but only %.3f%% of low-band energy is involved, so mono summing costs effectively nothing. The dips are stereo width in the mids and highs.",
                               lostBassPercent)))
        } else {
            checks.append(Check(severity: .pass,
                                title: String(format: "Correlation %+.2f", stereo.overall),
                                detail: String(format: "Bass correlation %+.3f. Mono-safe.", stereo.lowOverall)))
        }

        return checks
    }
}
