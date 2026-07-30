import AVFoundation
import Foundation
import Synchronization

internal enum AudioConverter16kError: Error, Equatable {
    case unsupportedInputFormat
    case cannotCreateConverter
    case cannotAllocateBuffer
    case conversionFailed(String)
    case nonFiniteOutput
}

/// Thread-safe synchronous feeder used only by AVAudioConverter's consumer-thread
/// callback. Its mutex is not on the realtime tap path.
private final class ConversionInputFeeder: Sendable {
    private struct State {
        var planes: [[Float]] = []
        var readOffset = 0
        var format: AVAudioFormat?
        var lastReturned: AVAudioPCMBuffer?
    }

    private let state = Mutex(State())

    func appendCopy(of source: AVAudioPCMBuffer) throws {
        guard let channels = source.floatChannelData else {
            throw AudioConverter16kError.unsupportedInputFormat
        }
        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)
        let planes = (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: frameCount))
        }
        state.withLock { value in
            precondition(value.planes.isEmpty, "converter feeder still contains prior input")
            value.planes = planes
            value.readOffset = 0
            value.format = source.format
            value.lastReturned = nil
        }
    }

    func nextBuffer(requestedFrames: Int) -> AVAudioPCMBuffer? {
        state.withLock { value in
            guard requestedFrames > 0,
                  !value.planes.isEmpty,
                  let format = value.format else {
                value.lastReturned = nil
                return nil
            }
            let remaining = value.planes[0].count - value.readOffset
            guard remaining > 0 else {
                value.planes.removeAll(keepingCapacity: true)
                value.lastReturned = nil
                return nil
            }

            let count = min(requestedFrames, remaining)
            guard let result = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let destination = result.floatChannelData else {
                value.lastReturned = nil
                return nil
            }
            result.frameLength = AVAudioFrameCount(count)
            for channel in value.planes.indices {
                value.planes[channel].withUnsafeBufferPointer { source in
                    destination[channel].update(from: source.baseAddress! + value.readOffset, count: count)
                }
            }
            value.readOffset += count
            if value.readOffset == value.planes[0].count {
                value.planes.removeAll(keepingCapacity: true)
                value.readOffset = 0
            }
            value.lastReturned = result
            return result
        }
    }

    var hasFrames: Bool {
        state.withLock { !$0.planes.isEmpty }
    }

    func reset() {
        state.withLock { value in
            value.planes.removeAll(keepingCapacity: true)
            value.readOffset = 0
            value.format = nil
            value.lastReturned = nil
        }
    }
}

internal struct AudioConverterSourceMetadata: Sendable, Equatable {
    let captureEpoch: UUID
    let sequence: UInt64
    let sourceFrameStart: Int64
    let firstSampleTime: ClockReading
}

/// Stateful native PCM → 16 kHz mono Float32 converter and 100 ms packager.
/// All methods are called serially by CaptureEngine's drain task.
internal final class AudioConverter16k {
    static let blockFrameCount = 1_600

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    private let conversionInputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let feeder = ConversionInputFeeder()
    private var expectedNextSourceFrame: Int64?
    private var outputCursor: Int64 = 0
    private var packageSamples: [Float] = []
    private var packageStart: Int64 = 0
    private var packageSequence: UInt64 = 0
    private var packageTime: ClockReading?

    internal init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0,
              inputFormat.sampleRate.isFinite,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved else {
            throw AudioConverter16kError.unsupportedInputFormat
        }
        guard let conversionInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(privySampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConverter16kError.cannotAllocateBuffer
        }
        guard let converter = AVAudioConverter(from: conversionInputFormat, to: outputFormat) else {
            throw AudioConverter16kError.cannotCreateConverter
        }

        self.inputFormat = inputFormat
        self.conversionInputFormat = conversionInputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        // Live input cannot provide future priming frames. `.none` avoids read-ahead
        // and lets the stateful converter carry its fixed latency continuously.
        self.converter.primeMethod = .none
        self.packageSamples.reserveCapacity(Self.blockFrameCount)
    }

    /// Converts one accepted source callback. A source-position or sequence gap first
    /// closes the old partial package, resets resampler state, and starts at the new
    /// normalized source position so no discontinuous samples are joined.
    internal func process(
        _ source: AVAudioPCMBuffer,
        metadata: AudioConverterSourceMetadata
    ) throws -> [AudioBlock16k] {
        guard source.format == inputFormat,
              source.frameLength > 0 else {
            throw AudioConverter16kError.unsupportedInputFormat
        }

        var blocks: [AudioBlock16k] = []
        let isDiscontinuous = expectedNextSourceFrame.map { $0 != metadata.sourceFrameStart } ?? false
        if isDiscontinuous {
            if let partial = takePartialPackage() { blocks.append(partial) }
            converter.reset()
            feeder.reset()
            outputCursor = normalizedSamplePosition(metadata.sourceFrameStart)
        } else if expectedNextSourceFrame == nil {
            outputCursor = normalizedSamplePosition(metadata.sourceFrameStart)
        }

        expectedNextSourceFrame = metadata.sourceFrameStart + Int64(source.frameLength)
        try feeder.appendCopy(of: try makeMonoInput(source))
        try drainAvailableOutput(metadata: metadata, into: &blocks)
        return blocks
    }

    /// Flushes a short terminal package without inventing samples, then clears all
    /// converter state. Capture restart constructs a new converter for the new format.
    internal func finish() -> [AudioBlock16k] {
        let partial = takePartialPackage()
        converter.reset()
        feeder.reset()
        expectedNextSourceFrame = nil
        outputCursor = 0
        return partial.map { [$0] } ?? []
    }

    private func makeMonoInput(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if source.format.channelCount == 1 { return source }
        guard let sourceChannels = source.floatChannelData,
              let mono = AVAudioPCMBuffer(
                pcmFormat: conversionInputFormat,
                frameCapacity: source.frameLength
              ), let destination = mono.floatChannelData?[0] else {
            throw AudioConverter16kError.cannotAllocateBuffer
        }
        mono.frameLength = source.frameLength
        let channels = Int(source.format.channelCount)
        let scale = 1 / Float(channels)
        for frame in 0..<Int(source.frameLength) {
            var mixed: Float = 0
            for channel in 0..<channels { mixed += sourceChannels[channel][frame] }
            destination[frame] = mixed * scale
        }
        return mono
    }

    private func drainAvailableOutput(
        metadata: AudioConverterSourceMetadata,
        into blocks: inout [AudioBlock16k]
    ) throws {
        let inputBlock = Self.makeInputBlock(feeder: feeder)
        var keepConverting = true
        while keepConverting {
            let needed = Self.blockFrameCount - packageSamples.count
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(needed)
            ) else {
                throw AudioConverter16kError.cannotAllocateBuffer
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError,
                withInputFrom: inputBlock
            )
            if let conversionError {
                throw AudioConverter16kError.conversionFailed(conversionError.localizedDescription)
            }

            let produced = Int(output.frameLength)
            if produced > 0 {
                guard let sourceSamples = output.floatChannelData?[0] else {
                    throw AudioConverter16kError.cannotAllocateBuffer
                }
                if packageSamples.isEmpty {
                    packageStart = outputCursor
                    packageSequence = metadata.sequence
                    storedPackageCaptureEpoch = metadata.captureEpoch
                    packageTime = shifted(
                        metadata.firstSampleTime,
                        by: Double(outputCursor - normalizedSamplePosition(metadata.sourceFrameStart))
                            / Double(privySampleRate)
                    )
                }
                let incoming = UnsafeBufferPointer(start: sourceSamples, count: produced)
                guard incoming.allSatisfy(\.isFinite) else {
                    throw AudioConverter16kError.nonFiniteOutput
                }
                packageSamples.append(contentsOf: incoming)
                outputCursor += Int64(produced)

                if packageSamples.count == Self.blockFrameCount {
                    blocks.append(makeCurrentPackage())
                    packageSamples.removeAll(keepingCapacity: true)
                    packageTime = nil
                }
            }

            switch status {
            case .haveData:
                if produced == 0 {
                    throw AudioConverter16kError.conversionFailed("converter returned haveData without output")
                }
            case .inputRanDry:
                keepConverting = false
            case .endOfStream:
                keepConverting = false
            case .error:
                throw AudioConverter16kError.conversionFailed(
                    conversionError?.localizedDescription ?? "AVAudioConverter returned error"
                )
            @unknown default:
                throw AudioConverter16kError.conversionFailed("unknown AVAudioConverter status")
            }
        }

        // The input block must consume every source frame. Otherwise a later callback
        // could be joined to an untracked tail.
        guard !feeder.hasFrames else {
            throw AudioConverter16kError.conversionFailed("converter left source frames unconsumed")
        }
    }

    private nonisolated static func makeInputBlock(
        feeder: ConversionInputFeeder
    ) -> AVAudioConverterInputBlock {
        { @Sendable requestedPackets, status in
            let requested = min(Int(requestedPackets), Int(UInt32.max))
            if let buffer = feeder.nextBuffer(requestedFrames: requested) {
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .noDataNow
            return nil
        }
    }

    private func normalizedSamplePosition(_ sourceFrame: Int64) -> Int64 {
        Int64(floor(Double(sourceFrame) * Double(privySampleRate) / inputFormat.sampleRate))
    }

    private func makeCurrentPackage() -> AudioBlock16k {
        precondition(!packageSamples.isEmpty && packageTime != nil)
        return AudioBlock16k(
            captureEpoch: storedPackageCaptureEpoch!,
            sequence: packageSequence,
            streamSampleStart: packageStart,
            firstSampleTime: packageTime!,
            samples: packageSamples
        )
    }

    private var storedPackageCaptureEpoch: UUID?

    private func takePartialPackage() -> AudioBlock16k? {
        guard !packageSamples.isEmpty else { return nil }
        let result = makeCurrentPackage()
        packageSamples.removeAll(keepingCapacity: true)
        packageTime = nil
        storedPackageCaptureEpoch = nil
        return result
    }

    private func shifted(_ reading: ClockReading, by seconds: Double) -> ClockReading {
        ClockReading(
            wallUTC: reading.wallUTC.addingTimeInterval(seconds),
            monotonicSeconds: reading.monotonicSeconds + seconds,
            clockEpoch: reading.clockEpoch
        )
    }
}
