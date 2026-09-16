import AppKit
import CoreGraphics

struct RenderSettings {
    var colormapName: String = "Spek Classic"
    var dbFloor: Double = -110
    var gain: Double = 0
    var colormap: Colormap { Colormap.named(colormapName) }
}

/// Fixed-size spectrogram thumbnail. No axes, no zoom — Nyquist is the tool for
/// inspecting one file; this is the glance across a folder.
enum SpectrogramThumb {

    static func image(_ sg: Spectrogram, settings: RenderSettings,
                      width: Int, height: Int, logFrequency: Bool = false) -> CGImage? {
        let w = max(1, width), h = max(1, height)
        let lut = settings.colormap.lut()
        let floor = settings.dbFloor
        let span = max(1.0, -floor)
        let gain = settings.gain
        let bins = sg.binCount

        var colStart = [Int](repeating: 0, count: w)
        var colEnd = [Int](repeating: 0, count: w)
        for x in 0..<w {
            let a = sg.frameCount * x / w
            let b = max(a + 1, sg.frameCount * (x + 1) / w)
            colStart[x] = min(a, sg.frameCount - 1)
            colEnd[x] = min(b, sg.frameCount)
        }
        var rowStart = [Int](repeating: 0, count: h)
        var rowEnd = [Int](repeating: 0, count: h)
        for y in 0..<h {
            // Row 0 is the top of the image, so the highest frequency.
            let fracLow = 1.0 - Double(y + 1) / Double(h)
            let fracHigh = 1.0 - Double(y) / Double(h)
            let a: Int, b: Int
            if logFrequency {
                let lo = log10(10.0), hi = log10(sg.nyquist)
                a = sg.bin(atFrequency: pow(10, lo + (hi - lo) * fracLow))
                b = sg.bin(atFrequency: pow(10, lo + (hi - lo) * fracHigh))
            } else {
                a = Int(Double(bins) * fracLow)
                b = Int(Double(bins) * fracHigh)
            }
            rowStart[y] = min(max(a, 0), bins - 1)
            rowEnd[y] = min(max(b, a + 1), bins)
        }

        var pixels = [UInt32](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { out in
            let o = out.baseAddress!
            sg.db.withUnsafeBufferPointer { dbBuf in
                let db = dbBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: w) { x in
                    let f0 = colStart[x], f1 = colEnd[x]
                    for y in 0..<h {
                        let b0 = rowStart[y], b1 = rowEnd[y]
                        // Mean power, so the noise floor is not inflated by pooling.
                        var sum: Float = 0
                        var n = 0
                        for f in f0..<f1 {
                            let row = db + f * bins
                            for b in b0..<b1 { sum += exp2f(row[b] * 0.332192809); n += 1 }
                        }
                        var value: Float = -200
                        if n > 0 && sum > 0 { value = log2f(sum / Float(n)) * 3.01029996 }
                        let norm = (Double(value) + gain - floor) / span
                        let idx = norm <= 0 ? 0 : (norm >= 1 ? 255 : Int(norm * 255))
                        o[y * w + x] = lut[idx]
                    }
                }
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs, bitmapInfo: info.rawValue)?.makeImage()
        }
    }
}
