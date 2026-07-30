import COgg
import COpus
import Foundation
import OpusShim

/// Streaming Ogg Opus file writer.
///
/// Designed for Privy's capture path (PLAN.md req 5): audio is encoded and
/// flushed to disk in ~1 s ogg pages as it arrives, so a crash or `kill -9`
/// loses at most the last unflushed second — every page already on disk stays
/// decodable because ogg needs no finalization step.
public final class OggOpusWriter {
    public enum WriterError: Error {
        case opus(String, Int32)
        case io(String)
    }

    public let sampleRate: Int32
    public let bitrate: Int32

    private var encoder: OpaquePointer
    private var stream = ogg_stream_state()
    private let handle: FileHandle
    private let frameSamples: Int  // 20 ms per opus packet
    private var pending: [Float] = []
    private var granulePos: Int64 = 0  // 48 kHz units, per opus spec
    private var packetNo: Int64 = 0
    private var samplesSinceFlush = 0
    private var finished = false

    public private(set) var totalSamples = 0

    public init(url: URL, sampleRate: Int32 = 16000, bitrate: Int32 = 24000) throws {
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.frameSamples = Int(sampleRate) / 50  // 20 ms

        var err: Int32 = 0
        guard let enc = opus_encoder_create(sampleRate, 1, OPUS_APPLICATION_VOIP, &err), err == OPUS_OK else {
            throw WriterError.opus("opus_encoder_create", err)
        }
        encoder = enc
        _ = opus_shim_set_bitrate(enc, bitrate)
        _ = opus_shim_set_signal_voice(enc)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            opus_encoder_destroy(enc)
            throw WriterError.io("cannot open \(url.path)")
        }
        handle = h

        ogg_stream_init(&stream, Int32.random(in: 0 ..< .max))
        try writeHeaders()
    }

    deinit {
        if !finished {
            // Crash-tolerant by design, but normal teardown should call finish().
            try? finish()
        }
        opus_encoder_destroy(encoder)
        ogg_stream_clear(&stream)
    }

    /// Append mono float32 samples at `sampleRate`. Thread-unsafe by design —
    /// call from a single consumer (never the realtime audio callback, req 4).
    public func append(_ samples: [Float]) throws {
        precondition(!finished, "append after finish")
        pending.append(contentsOf: samples)
        totalSamples += samples.count
        while pending.count >= frameSamples {
            try encodeFrame(Array(pending[0 ..< frameSamples]), endOfStream: false)
            pending.removeFirst(frameSamples)
        }
        // Bound crash loss to ~1 s: force pages out even mid-stream.
        samplesSinceFlush += samples.count
        if samplesSinceFlush >= Int(sampleRate) {
            try flushPages(force: true)
            samplesSinceFlush = 0
        }
    }

    /// Pad the tail to a whole frame, mark end-of-stream, flush everything.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        if !pending.isEmpty {
            pending.append(contentsOf: [Float](repeating: 0, count: frameSamples - pending.count))
        } else {
            pending = [Float](repeating: 0, count: frameSamples)
        }
        try encodeFrame(pending, endOfStream: true)
        pending.removeAll()
        try flushPages(force: true)
        try handle.close()
    }

    // MARK: - Internals

    private func writeHeaders() throws {
        var lookahead: opus_int32 = 0
        _ = opus_shim_get_lookahead(encoder, &lookahead)
        let preSkip48k = UInt16(clamping: Int(lookahead) * 48000 / Int(sampleRate))

        var head: [UInt8] = Array("OpusHead".utf8)
        head.append(1)  // version
        head.append(1)  // channel count
        head.append(le16: preSkip48k)
        head.append(le32: UInt32(sampleRate))  // original input rate, informational
        head.append(le16: 0)  // output gain
        head.append(0)  // mapping family
        try submitPacket(head, granulePos: 0, beginOfStream: true, endOfStream: false)
        try flushPages(force: true)

        let vendor = Array("privy".utf8)
        var tags: [UInt8] = Array("OpusTags".utf8)
        tags.append(le32: UInt32(vendor.count))
        tags.append(contentsOf: vendor)
        tags.append(le32: 0)  // no comments
        try submitPacket(tags, granulePos: 0, beginOfStream: false, endOfStream: false)
        try flushPages(force: true)
    }

    private func encodeFrame(_ frame: [Float], endOfStream: Bool) throws {
        var out = [UInt8](repeating: 0, count: 4000)  // opus recommended max packet
        let n = frame.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBufferPointer { buf in
                opus_encode_float(encoder, pcm.baseAddress!, Int32(frameSamples), buf.baseAddress!, Int32(buf.count))
            }
        }
        guard n > 0 else { throw WriterError.opus("opus_encode_float", n) }
        granulePos += Int64(48000 / 50)  // 20 ms in 48 kHz units
        try submitPacket(Array(out[0 ..< Int(n)]), granulePos: granulePos, beginOfStream: false, endOfStream: endOfStream)
        try flushPages(force: false)
    }

    private func submitPacket(_ bytes: [UInt8], granulePos: Int64, beginOfStream: Bool, endOfStream: Bool) throws {
        var data = bytes
        try data.withUnsafeMutableBufferPointer { buf in
            var packet = ogg_packet(
                packet: buf.baseAddress,
                bytes: buf.count,
                b_o_s: beginOfStream ? 1 : 0,
                e_o_s: endOfStream ? 1 : 0,
                granulepos: granulePos,
                packetno: packetNo
            )
            guard ogg_stream_packetin(&stream, &packet) == 0 else {
                throw WriterError.io("ogg_stream_packetin failed")
            }
        }
        packetNo += 1
    }

    private func flushPages(force: Bool) throws {
        var page = ogg_page()
        while (force ? ogg_stream_flush(&stream, &page) : ogg_stream_pageout(&stream, &page)) != 0 {
            try handle.write(contentsOf: Data(bytes: page.header, count: page.header_len))
            try handle.write(contentsOf: Data(bytes: page.body, count: page.body_len))
        }
    }
}

private extension [UInt8] {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
