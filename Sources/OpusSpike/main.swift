import AVFoundation
import OpusIO
import Foundation

// Day-1 spike: can CoreAudio encode Opus into CAF via AVAudioFile, streamed in
// small chunks (the shape of real capture), at ~24 kbps? Also simulates a crash
// (file never finalized) to check truncation tolerance for req 5.
//
// Verdict criteria: encode succeeds at 16 kHz, ~30 KB for 10 s (24 kbps
// honored), ffmpeg can read both the clean and the "crashed" file and can
// extract a time range (M2 path). If this fails, fall back to swift-ogg.

let outDir = URL(fileURLWithPath: "dist", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func sineChunk(format: AVAudioFormat, frames: AVAudioFrameCount, startFrame: Int) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    let ptr = buf.floatChannelData![0]
    let sr = format.sampleRate
    for i in 0..<Int(frames) {
        ptr[i] = 0.3 * Float(sin(2.0 * .pi * 440.0 * Double(startFrame + i) / sr))
    }
    return buf
}

func writeOpusCAF(name: String, sampleRate: Double, seconds: Double, finalize: Bool) {
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatOpus,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 24000,
    ]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let pcm = file.processingFormat
        let chunkFrames = AVAudioFrameCount(pcm.sampleRate / 10)  // 100 ms, mimics streaming capture
        var written = 0
        let total = Int(pcm.sampleRate * seconds)
        while written < total {
            let n = min(Int(chunkFrames), total - written)
            try file.write(from: sineChunk(format: pcm, frames: AVAudioFrameCount(n), startFrame: written))
            written += n
        }
        if finalize {
            // let `file` deinit close and finalize the header
            print("OK \(name): wrote \(written) frames @ \(Int(pcm.sampleRate))Hz, finalized")
        } else {
            // simulate a crash: leak the file handle and die without finalizing
            _ = Unmanaged.passRetained(file)
            print("OK \(name): wrote \(written) frames @ \(Int(pcm.sampleRate))Hz, NOT finalized (simulated crash)")
        }
    } catch {
        print("FAILED \(name): \(error)")
    }
}

writeOpusCAF(name: "opus-16k.caf", sampleRate: 16000, seconds: 10, finalize: true)
writeOpusCAF(name: "opus-48k.caf", sampleRate: 48000, seconds: 10, finalize: true)
writeOpusCAF(name: "opus-crash.caf", sampleRate: 16000, seconds: 10, finalize: false)

// Candidate B: streaming ogg-opus via system libopus/libogg (OpusIO).
func sineSamples(sampleRate: Int, seconds: Double, startFrame: Int = 0) -> [Float] {
    (0 ..< Int(Double(sampleRate) * seconds)).map {
        0.3 * Float(sin(2.0 * .pi * 440.0 * Double(startFrame + $0) / Double(sampleRate)))
    }
}

func writeOgg(name: String, seconds: Double, finish: Bool) {
    let url = outDir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    do {
        let writer = try OggOpusWriter(url: url, sampleRate: 16000, bitrate: 24000)
        var written = 0
        let chunk = 1600  // 100 ms, mimics streaming capture
        let total = Int(16000 * seconds)
        while written < total {
            try writer.append(sineSamples(sampleRate: 16000, seconds: Double(min(chunk, total - written)) / 16000, startFrame: written))
            written += chunk
        }
        if finish {
            try writer.finish()
            print("OK \(name): wrote \(written) samples, finished")
        } else {
            _ = Unmanaged.passRetained(writer)  // leak: no finish(), no deinit
            print("OK \(name): wrote \(written) samples, NOT finished (simulated crash)")
        }
    } catch {
        print("FAILED \(name): \(error)")
    }
}

writeOgg(name: "opus-16k.ogg", seconds: 10, finish: true)
writeOgg(name: "opus-1h.ogg", seconds: 3600, finish: true)  // disk-math check at scale
writeOgg(name: "opus-crash.ogg", seconds: 10, finish: false)
exit(0)  // hard exit so the crash files are never finalized
