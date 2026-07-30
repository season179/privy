import AVFoundation
import Darwin
import Foundation
import Testing
@testable import PrivyCore

private func makePCMBuffer(
    sampleRate: Double = 48_000,
    channels: Int = 1,
    frames: Int,
    base: Float = 0
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(frames)
    )!
    buffer.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<channels {
        for frame in 0..<frames {
            buffer.floatChannelData![channel][frame] = base + Float(channel * 1_000 + frame)
        }
    }
    return buffer
}

private func makeTime(sampleTime: AVAudioFramePosition = 0) -> AVAudioTime {
    AVAudioTime(sampleTime: sampleTime, atRate: 48_000)
}

private func makeDestination(
    sampleRate: Double = 48_000,
    channels: Int = 1,
    capacity: Int
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: false
    )!
    return AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(capacity)
    )!
}

// AVAudioPCMBuffer's allocator is process-global; serialize fixture creation so TSan
// observes only the deliberate producer/consumer concurrency inside the stress test.
@Suite(.serialized) struct RealtimeAudioRingTests {
    @Test func emptyFullAndWraparoundUseTheRealPushPopPath() {
        let ring = RealtimeAudioRing(
            sampleRate: 48_000,
            channelCount: 2,
            minimumDurationSeconds: 0.001,
            maximumCallbackFrames: 4,
            slotCount: 3
        )
        let destination = makeDestination(channels: 2, capacity: 4)
        #expect(ring.pop(into: destination) == nil)

        for callback in 0..<3 {
            let source = makePCMBuffer(channels: 2, frames: 4, base: Float(callback * 10))
            let result = ring.push(buffer: source, time: makeTime(sampleTime: Int64(callback * 4)))
            guard case .accepted(let metadata) = result else {
                Issue.record("callback should fit")
                return
            }
            #expect(metadata.sequence == UInt64(callback))
            #expect(metadata.sourceFrameStart == Int64(callback * 4))
        }

        let rejected = ring.push(
            buffer: makePCMBuffer(channels: 2, frames: 4, base: 99),
            time: makeTime(sampleTime: 12)
        )
        guard case .dropped(let dropped) = rejected else {
            Issue.record("full ring must reject newest callback")
            return
        }
        #expect(dropped.sequence == 3)
        #expect(dropped.sourceFrameStart == 12)
        #expect(ring.count == 3)
        #expect(ring.takeDroppedSourceFrames() == 4)

        let first = ring.pop(into: destination)
        #expect(first?.sequence == 0)
        #expect(Array(UnsafeBufferPointer(start: destination.floatChannelData![1], count: 4)) == [1000, 1001, 1002, 1003])

        let wrapped = ring.push(
            buffer: makePCMBuffer(channels: 2, frames: 4, base: 40),
            time: makeTime(sampleTime: 16)
        )
        guard case .accepted(let wrappedMetadata) = wrapped else {
            Issue.record("freed slot should be reused")
            return
        }
        #expect(wrappedMetadata.sequence == 4)
        #expect(wrappedMetadata.sourceFrameStart == 16)

        var sequences: [UInt64] = []
        while let item = ring.pop(into: destination) { sequences.append(item.sequence) }
        #expect(sequences == [1, 2, 4])
    }

    @Test func maximumCallbackIsAcceptedAndOversizeCallbackDropsWhole() {
        let ring = RealtimeAudioRing(
            sampleRate: 48_000,
            channelCount: 1,
            minimumDurationSeconds: 0.001,
            maximumCallbackFrames: 4,
            slotCount: 2
        )
        let destination = makeDestination(capacity: 4)
        #expect(ring.push(buffer: makePCMBuffer(frames: 4), time: makeTime()) == .accepted(
            RealtimeAudioMetadata(
                sequence: 0,
                sourceFrameStart: 0,
                deviceSampleTime: 0,
                hostTime: nil,
                frameCount: 4
            )
        ))
        _ = ring.pop(into: destination)

        guard case .dropped(let oversized) = ring.push(
            buffer: makePCMBuffer(frames: 5),
            time: makeTime(sampleTime: 4)
        ) else {
            Issue.record("oversize callback must be rejected as one unit")
            return
        }
        #expect(oversized.frameCount == 5)
        #expect(oversized.sequence == 1)
        #expect(oversized.sourceFrameStart == 4)
        #expect(ring.takeDroppedSourceFrames() == 5)
        #expect(ring.count == 0)

        guard case .accepted(let afterGap) = ring.push(
            buffer: makePCMBuffer(frames: 4),
            time: makeTime(sampleTime: 9)
        ) else {
            Issue.record("valid callback after oversize drop should fit")
            return
        }
        #expect(afterGap.sequence == 2)
        #expect(afterGap.sourceFrameStart == 9)
    }

    @Test func callbackLargerThanTapHintIsCapturedWhole() {
        let frames = 8_192
        let ring = RealtimeAudioRing(
            sampleRate: 48_000,
            channelCount: 1
        )
        let source = makePCMBuffer(frames: frames, base: 0.5)
        guard case .accepted(let metadata) = ring.push(
            buffer: source,
            time: makeTime()
        ) else {
            Issue.record("an 8192-frame device callback must not be rejected")
            return
        }
        #expect(metadata.frameCount == frames)

        let destination = makeDestination(capacity: frames)
        #expect(ring.pop(into: destination) == metadata)
        #expect(destination.frameLength == AVAudioFrameCount(frames))
        #expect(destination.floatChannelData![0][0] == 0.5)
        #expect(destination.floatChannelData![0][frames - 1] == 0.5 + Float(frames - 1))
        #expect(ring.takeDroppedSourceFrames() == 0)
    }

    @Test func defaultCapacityPreallocatesAtLeastEightSeconds() {
        let ring = RealtimeAudioRing(
            sampleRate: 44_100,
            channelCount: 1,
            maximumCallbackFrames: 4_096
        )
        #expect(ring.frameCapacity >= 44_100 * 8)
    }

    @Test func durationCapacityDoesNotShrinkWithSmallCallbacks() {
        let ring = RealtimeAudioRing(
            sampleRate: 48_000,
            channelCount: 1,
            minimumDurationSeconds: 0.001,
            maximumCallbackFrames: 32
        )
        let oneFrame = makePCMBuffer(frames: 1)
        for index in 0..<48 {
            guard case .accepted = ring.push(
                buffer: oneFrame,
                time: makeTime(sampleTime: Int64(index))
            ) else {
                Issue.record("ring lost duration capacity at callback \(index)")
                return
            }
        }
        guard case .dropped = ring.push(
            buffer: oneFrame,
            time: makeTime(sampleTime: 48)
        ) else {
            Issue.record("49th frame should exceed the 48-frame duration bound")
            return
        }
        #expect(ring.takeDroppedSourceFrames() == 1)
    }

    @Test func fasterProducerStressPreservesAccountingAndPublication() {
        let callbackCount = 100_000
        let framesPerCallback = 32
        let ring = RealtimeAudioRing(
            sampleRate: 48_000,
            channelCount: 1,
            minimumDurationSeconds: 0.001,
            maximumCallbackFrames: framesPerCallback,
            slotCount: 32
        )
        let destination = makeDestination(capacity: framesPerCallback)
        let producer = DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let source = makePCMBuffer(frames: framesPerCallback, base: 0.25)
            for index in 0..<callbackCount {
                _ = ring.push(
                    buffer: source,
                    time: makeTime(sampleTime: Int64(index * framesPerCallback))
                )
            }
            producer.leave()
        }

        var accepted = 0
        var previousSequence: UInt64?
        repeat {
            while let item = ring.pop(into: destination) {
                if let previousSequence {
                    #expect(item.sequence > previousSequence)
                }
                previousSequence = item.sequence
                #expect(destination.frameLength == AVAudioFrameCount(framesPerCallback))
                #expect(destination.floatChannelData![0][0] == 0.25)
                accepted += 1
            }
            sched_yield()
        } while producer.wait(timeout: .now()) == .timedOut || ring.count > 0

        let droppedFrames = Int(ring.takeDroppedSourceFrames())
        #expect(droppedFrames.isMultiple(of: framesPerCallback))
        #expect(accepted + droppedFrames / framesPerCallback == callbackCount)
        #expect(ring.nextCallbackSequence == UInt64(callbackCount))

        guard case .accepted(let afterStress) = ring.push(
            buffer: makePCMBuffer(frames: framesPerCallback, base: 0.25),
            time: makeTime(sampleTime: Int64(callbackCount * framesPerCallback))
        ) else {
            Issue.record("drained ring should accept next callback")
            return
        }
        #expect(afterStress.sequence == UInt64(callbackCount))
        #expect(afterStress.sourceFrameStart == Int64(callbackCount * framesPerCallback))
    }
}
