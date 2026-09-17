import Accelerate
import Foundation

/// EBU R128 / ITU-R BS.1770-4 loudness measurement.
enum Loudness {

    struct Result {
        var integratedLUFS: Double      // gated, whole programme
        var loudnessRangeLU: Double     // EBU R128 LRA
        var maxShortTermLUFS: Double
        var maxMomentaryLUFS: Double
        var truePeakDBTP: Double        // 4x oversampled
        var samplePeakDBFS: Double
        var shortTerm: [Float]          // 3 s window, 100 ms hop — the energy envelope
        var shortTermHopSeconds: Double
    }

    // MARK: - K-weighting

    /// Biquad in direct form I. Coefficients are normalized so a0 == 1.
    private struct Biquad {
        var b0, b1, b2, a1, a2: Double

        func apply(_ x: inout [Float]) {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let x0 = Double(x[i])
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x0
                y2 = y1; y1 = y0
                x[i] = Float(y0)
            }
        }
    }

    /// Stage 1: high shelf. Stage 2: high pass (RLB).
    /// Analog prototype parameters, so the filters are correct at any sample rate
    /// rather than only at the 48 kHz the spec tabulates.
    private static func kWeighting(_ fs: Double) -> [Biquad] {
        let f0s = 1681.974450955533
        let gainDB = 3.999843853973347
        let qs = 0.7071752369554196

        let ks = tan(Double.pi * f0s / fs)
        let vh = pow(10.0, gainDB / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0s = 1.0 + ks / qs + ks * ks
        let shelf = Biquad(
            b0: (vh + vb * ks / qs + ks * ks) / a0s,
            b1: 2.0 * (ks * ks - vh) / a0s,
            b2: (vh - vb * ks / qs + ks * ks) / a0s,
            a1: 2.0 * (ks * ks - 1.0) / a0s,
            a2: (1.0 - ks / qs + ks * ks) / a0s)

        let f0h = 38.13547087602444
        let qh = 0.5003270373238773
        let kh = tan(Double.pi * f0h / fs)
        let a0h = 1.0 + kh / qh + kh * kh
        let highpass = Biquad(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (kh * kh - 1.0) / a0h,
            a2: (1.0 - kh / qh + kh * kh) / a0h)

        return [shelf, highpass]
    }

    // MARK: - Measurement

    static func measure(channels: [[Float]], sampleRate: Double) -> Result {
        precondition(!channels.isEmpty)
        let n = channels[0].count

        // Sample peak and true peak come off the unweighted signal.
        var samplePeak: Float = 0
        for ch in channels {
            var p: Float = 0
            vDSP_maxmgv(ch, 1, &p, vDSP_Length(ch.count))
            samplePeak = max(samplePeak, p)
        }
        let truePeak = channels.map { truePeakLinear($0) }.max() ?? 0

        // K-weight a working copy of each channel.
        let filters = kWeighting(sampleRate)
        var weighted = channels
        for c in 0..<weighted.count {
            for f in filters { f.apply(&weighted[c]) }
        }

        // 400 ms blocks, 100 ms hop.
        let blockLen = Int(0.4 * sampleRate)
        let hop = Int(0.1 * sampleRate)
        guard n >= blockLen, blockLen > 0, hop > 0 else {
            return Result(integratedLUFS: -.infinity, loudnessRangeLU: 0,
                          maxShortTermLUFS: -.infinity, maxMomentaryLUFS: -.infinity,
                          truePeakDBTP: db(truePeak), samplePeakDBFS: db(samplePeak),
                          shortTerm: [], shortTermHopSeconds: 0.1)
        }
        let blockCount = (n - blockLen) / hop + 1

        // Per-block weighted mean square, summed across channels (G = 1.0 for L/R).
        var blockPower = [Double](repeating: 0, count: blockCount)
        for c in 0..<weighted.count {
            weighted[c].withUnsafeBufferPointer { buf in
                let p = buf.baseAddress!
                for j in 0..<blockCount {
                    var sum: Float = 0
                    vDSP_measqv(p + j * hop, 1, &sum, vDSP_Length(blockLen))
                    blockPower[j] += Double(sum)
                }
            }
        }

        let momentary = blockPower.map { loudness($0) }
        let maxMomentary = momentary.max() ?? -.infinity

        // Two-stage gate: absolute at -70 LUFS, then relative at -10 LU.
        let absKept = (0..<blockCount).filter { momentary[$0] > -70.0 }
        var integrated = -Double.infinity
        if !absKept.isEmpty {
            let meanAbs = absKept.reduce(0.0) { $0 + blockPower[$1] } / Double(absKept.count)
            let relativeGate = loudness(meanAbs) - 10.0
            let kept = absKept.filter { momentary[$0] > relativeGate }
            if !kept.isEmpty {
                let mean = kept.reduce(0.0) { $0 + blockPower[$1] } / Double(kept.count)
                integrated = loudness(mean)
            }
        }

        // Short term: 3 s window, same 100 ms hop.
        let stLen = Int(3.0 * sampleRate)
        var shortTerm: [Float] = []
        var stPower: [Double] = []
        if n >= stLen {
            let stCount = (n - stLen) / hop + 1
            stPower = [Double](repeating: 0, count: stCount)
            for c in 0..<weighted.count {
                weighted[c].withUnsafeBufferPointer { buf in
                    let p = buf.baseAddress!
                    for j in 0..<stCount {
                        var sum: Float = 0
                        vDSP_measqv(p + j * hop, 1, &sum, vDSP_Length(stLen))
                        stPower[j] += Double(sum)
                    }
                }
            }
            shortTerm = stPower.map { Float(loudness($0)) }
        }

        return Result(integratedLUFS: integrated,
                      loudnessRangeLU: loudnessRange(stPower),
                      maxShortTermLUFS: shortTerm.map { Double($0) }.max() ?? -.infinity,
                      maxMomentaryLUFS: maxMomentary,
                      truePeakDBTP: db(truePeak),
                      samplePeakDBFS: db(samplePeak),
                      shortTerm: shortTerm,
                      shortTermHopSeconds: 0.1)
    }

    private static func loudness(_ power: Double) -> Double {
        power > 0 ? -0.691 + 10.0 * log10(power) : -.infinity
    }

    private static func db(_ linear: Float) -> Double {
        linear > 0 ? 20.0 * log10(Double(linear)) : -.infinity
    }

    /// EBU R128 LRA: 10th to 95th percentile of short-term loudness, gated at
    /// -70 LUFS absolute and -20 LU relative.
    private static func loudnessRange(_ stPower: [Double]) -> Double {
        guard !stPower.isEmpty else { return 0 }
        let l = stPower.map { loudness($0) }
        let absKept = (0..<l.count).filter { l[$0] > -70.0 }
        guard !absKept.isEmpty else { return 0 }
        let mean = absKept.reduce(0.0) { $0 + stPower[$1] } / Double(absKept.count)
        let gate = loudness(mean) - 20.0
        let kept = absKept.map { l[$0] }.filter { $0 > gate }.sorted()
        guard kept.count > 1 else { return 0 }
        func percentile(_ p: Double) -> Double {
            let idx = min(max(Int((Double(kept.count - 1) * p).rounded()), 0), kept.count - 1)
            return kept[idx]
        }
        return percentile(0.95) - percentile(0.10)
    }

    // MARK: - True peak

    /// 4x oversample with a Kaiser-windowed sinc, then take the peak. This follows
    /// the BS.1770 Annex 2 method without using its exact tabulated filter, so it can read
    /// up to ~0.15 dB low on heavily clipped material.
    private static let phases: [[Float]] = makePolyphase()

    private static func makePolyphase(taps: Int = 32, factor: Int = 4) -> [[Float]] {
        let total = taps * factor
        let center = Double(total - 1) / 2.0
        let beta = 8.0
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            let half = x / 2
            for k in 1...40 {
                term *= (half / Double(k)) * (half / Double(k))
                sum += term
                if term < sum * 1e-17 { break }
            }
            return sum
        }
        let denom = besselI0(beta)
        var h = [Double](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) - center
            let sinc = t == 0 ? 1.0 : sin(Double.pi * t / Double(factor)) / (Double.pi * t / Double(factor))
            let r = 2.0 * Double(i) / Double(total - 1) - 1.0
            let w = besselI0(beta * (1.0 - r * r).squareRoot()) / denom
            h[i] = sinc * w
        }
        // Normalize so each phase has unity DC gain.
        var out = [[Float]](repeating: [], count: factor)
        for p in 0..<factor {
            var phase = [Double]()
            var i = p
            while i < total { phase.append(h[i]); i += factor }
            let s = phase.reduce(0, +)
            out[p] = phase.map { Float($0 / (s == 0 ? 1 : s)) }
        }
        return out
    }

    private static func truePeakLinear(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        let tapsPerPhase = phases[0].count
        guard x.count > tapsPerPhase else { return peak }

        // Convolve once per phase; the max across all phases is the oversampled peak.
        let outCount = x.count - tapsPerPhase + 1
        var scratch = [Float](repeating: 0, count: outCount)
        for phase in phases {
            vDSP_conv(x, 1, phase.reversed(), 1, &scratch, 1,
                      vDSP_Length(outCount), vDSP_Length(tapsPerPhase))
            var p: Float = 0
            vDSP_maxmgv(scratch, 1, &p, vDSP_Length(outCount))
            peak = max(peak, p)
        }
        return peak
    }
}
