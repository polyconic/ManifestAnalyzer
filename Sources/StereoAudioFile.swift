import AVFoundation
import Foundation

struct StereoAudio {
    var channels: [[Float]]      // kept separate; correlation and true peak need them
    var sampleRate: Double
    var codecDescription: String
    var bitDepth: Int
    var decodedVia: String

    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: Double { Double(frameCount) / sampleRate }
    var channelCount: Int { channels.count }

    /// Mono mixdown, for the spectrogram.
    func mixdown() -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var out = [Float](repeating: 0, count: first.count)
        let scale = 1.0 / Float(channels.count)
        for ch in channels {
            for i in 0..<min(out.count, ch.count) { out[i] += ch[i] * scale }
        }
        return out
    }
}

enum StereoLoadError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? { switch self { case .unreadable(let m): return m } }
}

enum StereoLoader {

    static func load(url: URL) throws -> StereoAudio {
        do { return try loadNative(url: url) }
        catch {
            guard let tool = ffmpegPath() else { throw error }
            return try loadViaFFmpeg(url: url, ffmpeg: tool, avMessage: error.localizedDescription)
        }
    }

    private static func loadNative(url: URL) throws -> StereoAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let total = Int(file.length)
        guard total > 0, channelCount > 0 else {
            throw StereoLoadError.unreadable("The file contains no audio frames.")
        }

        var out = [[Float]](repeating: [Float](repeating: 0, count: total), count: channelCount)
        let chunk: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw StereoLoadError.unreadable("Could not allocate a decode buffer.")
        }

        var written = 0
        while written < total {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let planes = buffer.floatChannelData else { break }
            for c in 0..<channelCount {
                let src = planes[c]
                out[c].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: written).update(from: src, count: n)
                }
            }
            written += n
        }
        if written < total { for c in 0..<channelCount { out[c].removeLast(total - written) } }

        let asbd = file.fileFormat.streamDescription.pointee
        return StereoAudio(channels: out,
                           sampleRate: file.fileFormat.sampleRate,
                           codecDescription: describe(asbd),
                           bitDepth: Int(asbd.mBitsPerChannel),
                           decodedVia: "AVFoundation")
    }

    private static func describe(_ d: AudioStreamBasicDescription) -> String {
        switch d.mFormatID {
        case kAudioFormatLinearPCM:
            let float = d.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return "\(float ? "PCM float" : "PCM") \(d.mBitsPerChannel)-bit"
        case kAudioFormatMPEGLayer3:    return "MP3"
        case kAudioFormatMPEG4AAC:      return "AAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC:          return "FLAC"
        case kAudioFormatOpus:          return "Opus"
        default:                        return "Audio"
        }
    }

    static func ffmpegPath() -> String? {
        for c in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    private static func loadViaFFmpeg(url: URL, ffmpeg: String, avMessage: String) throws -> StereoAudio {
        var rate = 48000.0
        var channelCount = 2
        let probePath = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        if FileManager.default.isExecutableFile(atPath: probePath) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: probePath)
            p.arguments = ["-v", "quiet", "-select_streams", "a:0", "-show_entries",
                           "stream=sample_rate,channels", "-of", "default=nw=1:nk=0", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                for line in String(decoding: d, as: UTF8.self).split(separator: "\n") {
                    let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    if kv[0] == "sample_rate" { rate = Double(kv[1]) ?? rate }
                    if kv[0] == "channels" { channelCount = Int(kv[1]) ?? channelCount }
                }
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-i", url.path, "-map", "0:a:0",
                       "-f", "f32le", "-acodec", "pcm_f32le", "-"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var raw = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                let d = out.fileHandleForReading.availableData
                if d.isEmpty { break }
                raw.append(d)
            }
            done.signal()
        }
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        done.wait()

        guard p.terminationStatus == 0, !raw.isEmpty else {
            let m = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw StereoLoadError.unreadable("macOS could not decode this file (\(avMessage)).\n\nffmpeg: \(m)")
        }

        let interleaved = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let frames = interleaved.count / max(channelCount, 1)
        var out2 = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channelCount)
        for i in 0..<frames {
            for c in 0..<channelCount { out2[c][i] = interleaved[i * channelCount + c] }
        }
        return StereoAudio(channels: out2, sampleRate: rate,
                           codecDescription: "Decoded by ffmpeg", bitDepth: 0, decodedVia: "ffmpeg")
    }
}
