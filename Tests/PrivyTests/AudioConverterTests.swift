import AVFoundation
import Foundation
import Testing
@testable import PrivyCore

private let converterClockEpoch = UUID()
private let converterCaptureEpoch = UUID()

private func converterFormat(rate: Double, channels: Int) -> AVAudioFormat {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: rate,
        channels: AVAudioChannelCount(channels),
        interleaved: false
    )!
}

private func converterBuffer(
    format: AVAudioFormat,
    frames: Int,
    fill: (_ channel: Int, _ frame: Int) -> Float
) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frames)
    )!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(format.channelCount) {
        for frame in 0..<frames {
            buffer.floatChannelData![channel][frame] = fill(channel, frame)
        }
    }
    return buffer
}

private actor CaptureEventCollector {
    private var events: [CaptureEvent] = []

    func append(_ event: CaptureEvent) { events.append(event) }
    func snapshot() -> [CaptureEvent] { events }
}

private func converterMetadata(
    sequence: UInt64,
    sourceStart: Int64,
    captureEpoch: UUID = converterCaptureEpoch,
    rate: Double
) -> AudioConverterSourceMetadata {
    let seconds = Double(sourceStart) / rate
    return AudioConverterSourceMetadata(
        captureEpoch: captureEpoch,
        sequence: sequence,
        sourceFrameStart: sourceStart,
        firstSampleTime: ClockReading(
            wallUTC: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            monotonicSeconds: 100 + seconds,
            clockEpoch: converterClockEpoch
        )
    )
}

@Suite struct AudioConverterTests {
    @Test func converts48kStereoThroughRealAVAudioConverterAndMixesChannels() throws {
        let format = converterFormat(rate: 48_000, channels: 2)
        let converter = try AudioConverter16k(inputFormat: format)
        let input = converterBuffer(format: format, frames: 4_800) { channel, frame in
            let signal = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000))
            return channel == 0 ? signal : 0
        }

        let blocks = try converter.process(
            input,
            metadata: converterMetadata(sequence: 0, sourceStart: 0, rate: 48_000)
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].samples.count == 1_600)
        #expect(blocks[0].captureEpoch == converterCaptureEpoch)
        #expect(blocks[0].sequence == 0)
        #expect(blocks[0].streamSampleStart == 0)
        #expect(blocks[0].samples.allSatisfy { $0.isFinite })

        let peak = blocks[0].samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.2)
        #expect(peak < 0.8) // mono mix contains both the signal and silent channel
    }

    @Test func converts44100MonoContinuouslyAcrossNonIntegerBoundaries() throws {
        let rate = 44_100.0
        let format = converterFormat(rate: rate, channels: 1)
        let converter = try AudioConverter16k(inputFormat: format)
        let callbackSizes = [1_000, 1_000, 1_000, 1_410, 4_410]
        var sourceStart: Int64 = 0
        var sequence: UInt64 = 0
        var blocks: [AudioBlock16k] = []

        for count in callbackSizes {
            let callbackStart = sourceStart
            let input = converterBuffer(format: format, frames: count) { _, frame in
                let sourceIndex = Double(callbackStart + Int64(frame))
                return Float(sin(2 * Double.pi * 330 * sourceIndex / rate))
            }
            blocks += try converter.process(
                input,
                metadata: converterMetadata(
                    sequence: sequence,
                    sourceStart: sourceStart,
                    rate: rate
                )
            )
            sourceStart += Int64(count)
            sequence += 1
        }
        blocks += converter.finish()

        // A one-callback conversion of the identical signal is the reference. Matching
        // it proves callback partitioning neither duplicates nor skips resampler input.
        let referenceConverter = try AudioConverter16k(inputFormat: format)
        let referenceInput = converterBuffer(format: format, frames: Int(sourceStart)) { _, frame in
            Float(sin(2 * Double.pi * 330 * Double(frame) / rate))
        }
        var referenceBlocks = try referenceConverter.process(
            referenceInput,
            metadata: converterMetadata(sequence: 0, sourceStart: 0, rate: rate)
        )
        referenceBlocks += referenceConverter.finish()
        let partitionedSamples = blocks.flatMap(\.samples)
        let referenceSamples = referenceBlocks.flatMap(\.samples)

        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.samples.count == 1_600 })
        #expect(blocks.map(\.streamSampleStart) == [0, 1_600])
        #expect(partitionedSamples.count == 3_200)
        #expect(referenceSamples.count == partitionedSamples.count)
        #expect(partitionedSamples.allSatisfy { $0.isFinite })
        let largestPartitionDelta = zip(partitionedSamples, referenceSamples)
            .map { abs($0 - $1) }
            .max() ?? 0
        #expect(largestPartitionDelta < 0.000_1)
    }

    @Test func sourceGapFlushesPartialAndResetsTimeline() throws {
        let format = converterFormat(rate: 48_000, channels: 1)
        let converter = try AudioConverter16k(inputFormat: format)
        let first = converterBuffer(format: format, frames: 2_400) { _, _ in 0.25 }
        let afterGap = converterBuffer(format: format, frames: 2_400) { _, _ in -0.25 }

        let initial = try converter.process(
            first,
            metadata: converterMetadata(sequence: 0, sourceStart: 0, rate: 48_000)
        )
        #expect(initial.isEmpty)

        let resetOutput = try converter.process(
            afterGap,
            metadata: converterMetadata(sequence: 2, sourceStart: 4_800, rate: 48_000)
        )
        #expect(resetOutput.count == 1)
        #expect(resetOutput[0].samples.count == 800)
        #expect(resetOutput[0].sequence == 0)
        #expect(resetOutput[0].streamSampleStart == 0)

        let tail = converter.finish()
        #expect(tail.count == 1)
        #expect(tail[0].samples.count == 800)
        #expect(tail[0].sequence == 2)
        #expect(tail[0].streamSampleStart == 1_600)
        let tailMean = tail[0].samples.reduce(0, +) / Float(tail[0].samples.count)
        #expect(tailMean < -0.2)
    }

    @Test func formatChangeUsesFreshConverterAndCaptureEpoch() throws {
        let epochA = UUID()
        let epochB = UUID()
        let format48 = converterFormat(rate: 48_000, channels: 2)
        let format441 = converterFormat(rate: 44_100, channels: 1)
        let converter48 = try AudioConverter16k(inputFormat: format48)
        let converter441 = try AudioConverter16k(inputFormat: format441)

        let blocks48 = try converter48.process(
            converterBuffer(format: format48, frames: 4_800) { _, _ in 0.1 },
            metadata: converterMetadata(sequence: 0, sourceStart: 0, captureEpoch: epochA, rate: 48_000)
        )
        let blocks441 = try converter441.process(
            converterBuffer(format: format441, frames: 4_410) { _, _ in 0.2 },
            metadata: converterMetadata(sequence: 0, sourceStart: 0, captureEpoch: epochB, rate: 44_100)
        )

        #expect(blocks48.count == 1)
        #expect(blocks441.count == 1)
        #expect(blocks48[0].captureEpoch == epochA)
        #expect(blocks441[0].captureEpoch == epochB)
        #expect(blocks441[0].streamSampleStart == 0)
    }

    @Test func boundedConvertedStreamReportsExactCoalescedOverrun() async {
        let output = CaptureOutput()
        let reading = ClockReading(
            wallUTC: Date(timeIntervalSince1970: 1_700_000_000),
            monotonicSeconds: 10,
            clockEpoch: converterClockEpoch
        )
        var blocks: [AudioBlock16k] = []
        for index in 0..<82 {
            let offset = Double(index) / 10
            let blockTime = ClockReading(
                wallUTC: reading.wallUTC.addingTimeInterval(offset),
                monotonicSeconds: reading.monotonicSeconds + offset,
                clockEpoch: reading.clockEpoch
            )
            blocks.append(AudioBlock16k(
                captureEpoch: converterCaptureEpoch,
                sequence: UInt64(index),
                streamSampleStart: Int64(index * 1_600),
                firstSampleTime: blockTime,
                samples: Array(repeating: Float(index), count: 1_600)
            ))
        }
        #expect(output.yield(blocks))

        var eventIterator = output.streams.events.makeAsyncIterator()
        guard let event = await eventIterator.next() else {
            Issue.record("converted queue overflow must emit telemetry")
            return
        }
        guard case .queueOverrun(let at, let droppedFrames, let duration) = event else {
            Issue.record("expected queueOverrun, got \(event)")
            return
        }
        #expect(at == blocks[80].firstSampleTime)
        #expect(droppedFrames == 3_200)
        #expect(duration == 0.2)

        var audioIterator = output.streams.audio.makeAsyncIterator()
        for expectedSequence in 0..<80 {
            let retained = await audioIterator.next()
            #expect(retained?.sequence == UInt64(expectedSequence))
        }
    }

    @Test func captureStartWithoutInputReportsUnavailableAndNeverStarted() async {
        let engine = CaptureEngine(clock: SystemClock(), forceInputUnavailable: true)
        var events = engine.streams.events.makeAsyncIterator()
        do {
            try await engine.start()
            Issue.record("start should fail without an input device")
        } catch let error as CaptureEngineError {
            guard case .inputUnavailable = error else {
                Issue.record("unexpected capture error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected capture error: \(error)")
        }

        guard let event = await events.next() else {
            Issue.record("missing inputUnavailable event")
            return
        }
        guard case .inputUnavailable(_, let detail) = event else {
            Issue.record("engine claimed a different lifecycle event: \(event)")
            return
        }
        #expect(!detail.isEmpty)
        await engine.stop(reason: .manualPause)
        await engine.stop(reason: .manualPause) // notification bursts are idempotent
    }

    @Test func concurrentRestartBurstCoalescesToOneAttempt() async {
        let engine = CaptureEngine(clock: SystemClock(), forceInputUnavailable: true)
        let collector = CaptureEventCollector()
        let collectionTask = Task {
            for await event in engine.streams.events {
                await collector.append(event)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    try? await engine.restart(reason: .deviceChange)
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        collectionTask.cancel()
        await collectionTask.value

        let events = await collector.snapshot()
        let unavailableCount = events.filter {
            if case .inputUnavailable = $0 { return true }
            return false
        }.count
        let startedCount = events.filter {
            if case .engineStarted = $0 { return true }
            return false
        }.count
        #expect(unavailableCount == 1)
        #expect(startedCount == 0)
    }
}
