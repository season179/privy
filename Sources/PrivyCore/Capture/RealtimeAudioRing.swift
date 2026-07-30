import Atomics
import AVFoundation
import Darwin

/// Metadata copied beside one native PCM callback. The sample position is the
/// ring's gap-preserving source timeline rather than conversion-completion time.
internal struct RealtimeAudioMetadata: Sendable, Equatable {
    let sequence: UInt64
    let sourceFrameStart: Int64
    let deviceSampleTime: Int64?
    let hostTime: UInt64?
    let frameCount: Int
}

internal enum RealtimeAudioPushResult: Sendable, Equatable {
    case accepted(RealtimeAudioMetadata)
    case dropped(RealtimeAudioMetadata)
}

private struct RealtimeAudioSlotMetadata {
    var sequence: UInt64 = 0
    var sourceFrameStart: Int64 = 0
    var storageFrameStart: UInt64 = 0
    var deviceSampleTime: Int64 = 0
    var hostTime: UInt64 = 0
    var frameCount: Int = 0
    var hasDeviceSampleTime = false
    var hasHostTime = false
}

/// A fixed-storage, nonblocking single-producer/single-consumer PCM ring.
///
/// Safety proof for `@unchecked Sendable`:
/// - exactly one AVAudioEngine tap calls `push`, and exactly one drain task calls
///   `pop`/`takeDroppedSourceFrames`;
/// - the producer writes a slot completely before publishing `writeIndex` with
///   release ordering; the consumer acquires that index before reading the slot;
/// - the consumer finishes copying a slot before publishing `readIndex` with
///   release ordering; the producer acquires it before reusing the slot; and
/// - raw storage, slot metadata, and capacity are allocated during init and are
///   never resized or replaced. The ring is destroyed only after tap removal and
///   drain-task termination.
internal final class RealtimeAudioRing: @unchecked Sendable {
    let sampleRate: Double
    let channelCount: Int
    let maximumCallbackFrames: Int
    /// Exact native-frame capacity, independent of callback quantum.
    let frameCapacity: Int
    /// One descriptor per possible one-frame callback guarantees descriptor capacity
    /// cannot reduce the advertised duration.
    let slotCount: Int

    private let samples: UnsafeMutablePointer<Float>
    private let metadata: UnsafeMutablePointer<RealtimeAudioSlotMetadata>
    private let writeIndex = ManagedAtomic<UInt64>(0)
    private let readIndex = ManagedAtomic<UInt64>(0)
    private let nextSequence = ManagedAtomic<UInt64>(0)
    private let nextSourceFrame = ManagedAtomic<UInt64>(0)
    private let acceptedWriteFrame = ManagedAtomic<UInt64>(0)
    private let acceptedReadFrame = ManagedAtomic<UInt64>(0)
    private let droppedSourceFrames = ManagedAtomic<UInt64>(0)

    internal init(
        sampleRate: Double,
        channelCount: Int,
        minimumDurationSeconds: Double = 8,
        maximumCallbackFrames: Int = 4_096,
        slotCount explicitSlotCount: Int? = nil
    ) {
        precondition(sampleRate > 0 && sampleRate.isFinite)
        precondition(channelCount > 0)
        precondition(maximumCallbackFrames > 0)
        precondition(minimumDurationSeconds > 0)

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maximumCallbackFrames = maximumCallbackFrames
        if let explicitSlotCount {
            precondition(explicitSlotCount > 0)
            self.slotCount = explicitSlotCount
            self.frameCapacity = explicitSlotCount * maximumCallbackFrames
        } else {
            self.frameCapacity = max(1, Int(ceil(sampleRate * minimumDurationSeconds)))
            self.slotCount = frameCapacity
        }

        let sampleCapacity = frameCapacity * channelCount
        self.samples = .allocate(capacity: sampleCapacity)
        self.samples.initialize(repeating: 0, count: sampleCapacity)
        self.metadata = .allocate(capacity: slotCount)
        self.metadata.initialize(repeating: RealtimeAudioSlotMetadata(), count: slotCount)
    }

    /// Realtime producer entry point. This method performs only bounded scalar work,
    /// pointer copies, and atomic operations. It never allocates, locks, waits, logs,
    /// creates a task, converts audio, or calls application/storage code.
    @inline(__always)
    internal func push(
        buffer: AVAudioPCMBuffer,
        time: AVAudioTime
    ) -> RealtimeAudioPushResult {
        let frameCount = Int(buffer.frameLength)
        let sequence = nextSequence.loadThenWrappingIncrement(ordering: .relaxed)
        let sourceBits = nextSourceFrame.loadThenWrappingIncrement(
            by: UInt64(frameCount),
            ordering: .relaxed
        )
        let item = RealtimeAudioMetadata(
            sequence: sequence,
            sourceFrameStart: Int64(bitPattern: sourceBits),
            deviceSampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
            hostTime: time.isHostTimeValid ? time.hostTime : nil,
            frameCount: frameCount
        )

        guard frameCount > 0,
              frameCount <= maximumCallbackFrames,
              Int(buffer.format.channelCount) == channelCount,
              !buffer.format.isInterleaved,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            droppedSourceFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
            return .dropped(item)
        }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let frameWrite = acceptedWriteFrame.load(ordering: .relaxed)
        let frameRead = acceptedReadFrame.load(ordering: .acquiring)
        guard write &- read < UInt64(slotCount),
              frameWrite &- frameRead + UInt64(frameCount) <= UInt64(frameCapacity) else {
            droppedSourceFrames.wrappingIncrement(by: UInt64(frameCount), ordering: .relaxed)
            return .dropped(item)
        }

        let frameOffset = Int(frameWrite % UInt64(frameCapacity))
        let firstCopyCount = min(frameCount, frameCapacity - frameOffset)
        let secondCopyCount = frameCount - firstCopyCount
        for channel in 0..<channelCount {
            let channelBase = channel * frameCapacity
            samples.advanced(by: channelBase + frameOffset).update(
                from: channels[channel],
                count: firstCopyCount
            )
            if secondCopyCount > 0 {
                samples.advanced(by: channelBase).update(
                    from: channels[channel] + firstCopyCount,
                    count: secondCopyCount
                )
            }
        }

        let slot = Int(write % UInt64(slotCount))
        metadata[slot] = RealtimeAudioSlotMetadata(
            sequence: sequence,
            sourceFrameStart: item.sourceFrameStart,
            storageFrameStart: frameWrite,
            deviceSampleTime: item.deviceSampleTime ?? 0,
            hostTime: item.hostTime ?? 0,
            frameCount: frameCount,
            hasDeviceSampleTime: item.deviceSampleTime != nil,
            hasHostTime: item.hostTime != nil
        )
        acceptedWriteFrame.store(frameWrite &+ UInt64(frameCount), ordering: .relaxed)
        writeIndex.store(write &+ 1, ordering: .releasing)
        return .accepted(item)
    }

    /// Consumer entry point. `destination` is allocated once by the drain task and
    /// reused; this method never exposes a pointer into a slot after publishing it free.
    internal func pop(into destination: AVAudioPCMBuffer) -> RealtimeAudioMetadata? {
        precondition(Int(destination.format.channelCount) == channelCount)
        precondition(!destination.format.isInterleaved)
        precondition(destination.format.commonFormat == .pcmFormatFloat32)
        precondition(Int(destination.frameCapacity) >= maximumCallbackFrames)

        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        guard read != write else { return nil }

        let slot = Int(read % UInt64(slotCount))
        let item = metadata[slot]
        destination.frameLength = AVAudioFrameCount(item.frameCount)
        guard let channels = destination.floatChannelData else {
            preconditionFailure("Float32 noninterleaved destination has no channel data")
        }
        let frameOffset = Int(item.storageFrameStart % UInt64(frameCapacity))
        let firstCopyCount = min(item.frameCount, frameCapacity - frameOffset)
        let secondCopyCount = item.frameCount - firstCopyCount
        for channel in 0..<channelCount {
            let channelBase = channel * frameCapacity
            channels[channel].update(
                from: samples.advanced(by: channelBase + frameOffset),
                count: firstCopyCount
            )
            if secondCopyCount > 0 {
                (channels[channel] + firstCopyCount).update(
                    from: samples.advanced(by: channelBase),
                    count: secondCopyCount
                )
            }
        }

        acceptedReadFrame.store(
            item.storageFrameStart &+ UInt64(item.frameCount),
            ordering: .releasing
        )
        readIndex.store(read &+ 1, ordering: .releasing)
        return RealtimeAudioMetadata(
            sequence: item.sequence,
            sourceFrameStart: item.sourceFrameStart,
            deviceSampleTime: item.hasDeviceSampleTime ? item.deviceSampleTime : nil,
            hostTime: item.hasHostTime ? item.hostTime : nil,
            frameCount: item.frameCount
        )
    }

    /// Atomically claims all producer-side overflow accounting accumulated so far.
    internal func takeDroppedSourceFrames() -> UInt64 {
        droppedSourceFrames.exchange(0, ordering: .acquiringAndReleasing)
    }

    /// Explicitly discards unread old-format slots after the tap has been removed.
    /// The returned exact frame count must be surfaced by the lifecycle owner.
    @discardableResult
    internal func discardAll() -> Int {
        var read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        var discarded = 0
        while read != write {
            let slot = Int(read % UInt64(slotCount))
            discarded += metadata[slot].frameCount
            read &+= 1
        }
        acceptedReadFrame.wrappingIncrement(by: UInt64(discarded), ordering: .releasing)
        readIndex.store(read, ordering: .releasing)
        return discarded
    }

    internal var count: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .acquiring)
        return Int(write &- read)
    }

    internal var nextCallbackSequence: UInt64 {
        nextSequence.load(ordering: .acquiring)
    }

    deinit {
        metadata.deinitialize(count: slotCount)
        metadata.deallocate()
        samples.deinitialize(count: frameCapacity * channelCount)
        samples.deallocate()
    }
}
