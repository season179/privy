import AVFoundation
import CoreAudio
import Darwin
import Foundation

internal enum CaptureEngineError: Error, Equatable {
    case inputUnavailable(String)
    case unsupportedInputFormat(String)
}

internal protocol CaptureEngineSleeping: Sendable {
    func sleep(seconds: Double) async
}

internal struct ContinuousCaptureEngineSleeper: CaptureEngineSleeping {
    func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// A narrow callback capture: configuration notifications receive only the event
/// continuation, never CaptureEngine or the audio continuation. AsyncStream continuations
/// are Sendable and `yield` is thread-safe; the stream is unbounded so events cannot be
/// evicted by a concurrent producer.
internal struct CaptureEventEmitter: Sendable {
    let continuation: AsyncStream<CaptureEvent>.Continuation

    func emit(_ event: CaptureEvent) {
        _ = continuation.yield(event)
    }
}

private struct ConvertedOverrun {
    var at: ClockReading
    var droppedFrames: Int
    var nextSampleStart: Int64
}

/// Owns the bounded stream continuations and centralizes inspection of every audio
/// `yield` result. Used by CaptureEngine and directly by deterministic backpressure tests.
/// AsyncStream continuations are Sendable and thread-safe; only the actor drain path
/// yields audio, while actor and notification paths may safely yield independent events.
internal struct CaptureOutput: Sendable {
    let streams: CaptureStreams
    let eventEmitter: CaptureEventEmitter
    private let audioContinuation: AsyncStream<AudioBlock16k>.Continuation

    init() {
        var audioContinuation: AsyncStream<AudioBlock16k>.Continuation!
        let audio = AsyncStream(
            AudioBlock16k.self,
            bufferingPolicy: .bufferingOldest(80)
        ) { audioContinuation = $0 }

        var eventContinuation: AsyncStream<CaptureEvent>.Continuation!
        let events = AsyncStream(CaptureEvent.self, bufferingPolicy: .unbounded) {
            eventContinuation = $0
        }
        self.audioContinuation = audioContinuation
        self.eventEmitter = CaptureEventEmitter(continuation: eventContinuation)
        self.streams = CaptureStreams(audio: audio, events: events)
    }

    /// Returns false after stream termination. Consecutive rejected blocks from this
    /// conversion batch are coalesced into one exact normalized-range event.
    @discardableResult
    func yield(_ blocks: [AudioBlock16k]) -> Bool {
        var pending: ConvertedOverrun?

        for block in blocks {
            switch audioContinuation.yield(block) {
            case .enqueued:
                if let pending { emitOverrun(pending) }
                pending = nil
            case .dropped(let dropped):
                if var current = pending,
                   current.nextSampleStart == dropped.streamSampleStart {
                    current.droppedFrames += dropped.samples.count
                    current.nextSampleStart += Int64(dropped.samples.count)
                    pending = current
                } else {
                    if let pending { emitOverrun(pending) }
                    pending = ConvertedOverrun(
                        at: dropped.firstSampleTime,
                        droppedFrames: dropped.samples.count,
                        nextSampleStart: dropped.streamSampleStart + Int64(dropped.samples.count)
                    )
                }
            case .terminated:
                if let pending { emitOverrun(pending) }
                return false
            @unknown default:
                if let pending { emitOverrun(pending) }
                return false
            }
        }
        if let pending { emitOverrun(pending) }
        return true
    }

    func emit(_ event: CaptureEvent) {
        eventEmitter.emit(event)
    }

    /// Finalizes converter state through the same path used by CaptureEngine.stop and
    /// conversion-failure recovery. Returns whether downstream conversion may continue.
    func finalizeConversion(
        _ converter: AudioConverter16k,
        afterTermination terminated: Bool
    ) -> Bool {
        if terminated {
            if let block = converter.discardPendingPackage() {
                emit(.queueOverrun(
                    block.firstSampleTime,
                    droppedSourceFrames: block.samples.count,
                    durationSeconds: Double(block.samples.count) / Double(privySampleRate)
                ))
            }
            return false
        }
        return yield(converter.finish())
    }

    private func emitOverrun(_ overrun: ConvertedOverrun) {
        emit(.queueOverrun(
            overrun.at,
            droppedSourceFrames: overrun.droppedFrames,
            durationSeconds: Double(overrun.droppedFrames) / Double(privySampleRate)
        ))
    }

}

/// Production AVAudioEngine capture source. The actor owns engine lifecycle and one
/// non-main drain/conversion task; the realtime tap owns only a preallocated ring.
public actor CaptureEngine: AudioCapturing {
    public nonisolated let streams: CaptureStreams

    private let clock: any PrivyClock
    private let engine: AVAudioEngine
    private let output: CaptureOutput
    private let forceInputUnavailable: Bool
    private let restartDebounceSeconds: Double
    private let restartSleeper: any CaptureEngineSleeping

    private var ring: RealtimeAudioRing?
    private var converter: AudioConverter16k?
    private var scratchBuffer: AVAudioPCMBuffer?
    private var captureEpoch: UUID?
    private var drainTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var tapInstalled = false
    private var running = false
    private var starting = false
    private var conversionTerminated = false
    private var restartDeadlineMonotonic: Double?
    private var pendingRestartReason: RestartReason?
    private var pendingRestartTask: Task<Void, Error>?

    public init(clock: any PrivyClock) {
        let output = CaptureOutput()
        self.clock = clock
        self.engine = AVAudioEngine()
        self.output = output
        self.streams = output.streams
        self.forceInputUnavailable = false
        self.restartDebounceSeconds = 0.5
        self.restartSleeper = ContinuousCaptureEngineSleeper()
    }

    /// Deterministic lifecycle seam; tests can force no input and manually advance the
    /// restart debounce without touching system audio hardware or wall-clock sleeps.
    internal init(
        clock: any PrivyClock,
        forceInputUnavailable: Bool,
        restartDebounceSeconds: Double = 0.5,
        restartSleeper: any CaptureEngineSleeping = ContinuousCaptureEngineSleeper()
    ) {
        precondition(restartDebounceSeconds > 0)
        let output = CaptureOutput()
        self.clock = clock
        self.engine = AVAudioEngine()
        self.output = output
        self.streams = output.streams
        self.forceInputUnavailable = forceInputUnavailable
        self.restartDebounceSeconds = restartDebounceSeconds
        self.restartSleeper = restartSleeper
    }

    public func start() async throws {
        guard !running, !starting else { return }
        starting = true
        defer { starting = false }

        let unavailableDetail = "No usable default input device"
        guard !forceInputUnavailable else {
            let reading = clock.now()
            output.emit(.inputUnavailable(reading, detail: unavailableDetail))
            throw CaptureEngineError.inputUnavailable(unavailableDetail)
        }

        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            let reading = clock.now()
            output.emit(.inputUnavailable(reading, detail: unavailableDetail))
            throw CaptureEngineError.inputUnavailable(unavailableDetail)
        }
        guard nativeFormat.commonFormat == .pcmFormatFloat32,
              !nativeFormat.isInterleaved else {
            let detail = "Unsupported input PCM format: \(nativeFormat)"
            output.emit(.inputUnavailable(clock.now(), detail: detail))
            throw CaptureEngineError.unsupportedInputFormat(detail)
        }

        let tapBufferHintFrames = 4_096
        // AVAudioEngine treats the tap size as a hint and devices can deliver larger
        // callbacks. Keep a generous hard ceiling so 8192-frame device quanta fit.
        let maximumCallbackFrames = 16_384
        // Every allocation occurs before installTap. The callback sees only this fully
        // initialized fixed ring.
        let ring = RealtimeAudioRing(
            sampleRate: nativeFormat.sampleRate,
            channelCount: Int(nativeFormat.channelCount),
            minimumDurationSeconds: 8,
            maximumCallbackFrames: maximumCallbackFrames
        )
        let converter: AudioConverter16k
        do {
            converter = try AudioConverter16k(inputFormat: nativeFormat)
        } catch {
            let detail = "Cannot convert input format: \(error)"
            output.emit(.conversionFailed(clock.now(), detail: detail))
            throw error
        }
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: nativeFormat,
            frameCapacity: AVAudioFrameCount(maximumCallbackFrames)
        ) else {
            throw AudioConverter16kError.cannotAllocateBuffer
        }

        let epoch = UUID()
        conversionTerminated = false
        self.ring = ring
        self.converter = converter
        self.scratchBuffer = scratch
        self.captureEpoch = epoch

        let tap = Self.makeTap(ring: ring)
        input.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(tapBufferHintFrames),
            format: nativeFormat,
            block: tap
        )
        tapInstalled = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil,
            using: Self.makeConfigurationHandler(emitter: output.eventEmitter, clock: clock)
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTapAndObserver()
            self.ring = nil
            self.converter = nil
            self.scratchBuffer = nil
            self.captureEpoch = nil
            let detail = "Input engine failed to start: \(error.localizedDescription)"
            output.emit(.inputUnavailable(clock.now(), detail: detail))
            throw error
        }

        running = true
        output.emit(.engineStarted(clock.now(), deviceUID: Self.defaultInputDeviceUID()))
        drainTask = Task { [weak self] in
            await self?.drainLoop(epoch: epoch)
        }
    }

    public func stop(reason: StopReason) async {
        guard running || tapInstalled || drainTask != nil else { return }
        let wasRunning = running
        running = false
        removeTapAndObserver()
        engine.stop()

        let task = drainTask
        drainTask = nil
        task?.cancel()
        await task?.value

        // Tap removal freezes the producer. Drain every accepted old-format slot before
        // finishing the converter, then explicitly discard anything left if downstream
        // termination stopped conversion.
        if let ring { emitRingDrops(from: ring) }
        while !conversionTerminated, ring?.count ?? 0 > 0 {
            _ = drainOne()
        }
        if let converter,
           !output.finalizeConversion(converter, afterTermination: conversionTerminated) {
            conversionTerminated = true
        }
        if let ring {
            emitDiscardedSourceFrames(ring.discardAll(), sampleRate: ring.sampleRate)
        }

        ring = nil
        converter = nil
        scratchBuffer = nil
        captureEpoch = nil
        conversionTerminated = false
        if wasRunning {
            output.emit(.engineStopped(clock.now(), reason: reason))
        }
    }

    public func restart(reason: RestartReason) async throws {
        let requestedDeadline = clock.now().monotonicSeconds + restartDebounceSeconds
        restartDeadlineMonotonic = requestedDeadline
        pendingRestartReason = coalescedRestartReason(pendingRestartReason, reason)

        // A request arriving while one debounce/attempt is pending is fully absorbed.
        // Only the first caller waits for, and receives errors from, the scheduled attempt.
        guard pendingRestartTask == nil else { return }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performDebouncedRestart()
        }
        pendingRestartTask = task
        try await task.value
    }

    private func performDebouncedRestart() async throws {
        defer {
            pendingRestartTask = nil
            restartDeadlineMonotonic = nil
            pendingRestartReason = nil
        }

        while let deadline = restartDeadlineMonotonic {
            let remaining = deadline - clock.now().monotonicSeconds
            guard remaining > 0 else { break }
            await restartSleeper.sleep(seconds: remaining)
        }

        let reason = pendingRestartReason ?? .manualRetry
        let stopReason: StopReason = reason == .deviceChange ? .deviceChange : .restart
        await stop(reason: stopReason)
        try await start()
    }

    private func coalescedRestartReason(
        _ pending: RestartReason?,
        _ incoming: RestartReason
    ) -> RestartReason {
        // Preserve device-change terminal semantics if any signal in the burst carries it.
        if pending == .deviceChange || incoming == .deviceChange { return .deviceChange }
        return incoming
    }

    private func drainLoop(epoch: UUID) async {
        while !Task.isCancelled, running, !conversionTerminated, captureEpoch == epoch {
            if drainOne() {
                await Task.yield()
            } else if !conversionTerminated {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    /// Returns true while conversion may continue; false means the converted stream
    /// terminated or conversion failed visibly.
    private func drainOne() -> Bool {
        guard let ring, let converter, let scratchBuffer, let captureEpoch else {
            return false
        }
        emitRingDrops(from: ring)
        guard let metadata = ring.pop(into: scratchBuffer) else { return false }

        let sourceMetadata = AudioConverterSourceMetadata(
            captureEpoch: captureEpoch,
            sequence: metadata.sequence,
            sourceFrameStart: metadata.sourceFrameStart,
            firstSampleTime: captureTime(for: metadata)
        )
        do {
            let blocks = try converter.process(scratchBuffer, metadata: sourceMetadata)
            let alive = output.yield(blocks)
            if !alive { conversionTerminated = true }
            return alive
        } catch {
            output.emit(.conversionFailed(
                clock.now(),
                detail: "16 kHz conversion failed: \(error)"
            ))
            // Preserve exact accounting for valid samples packaged before this callback
            // failed, then separately account the rejected source callback itself.
            _ = output.finalizeConversion(converter, afterTermination: true)
            emitDiscardedSourceFrames(metadata.frameCount, sampleRate: ring.sampleRate)
            conversionTerminated = true
            return false
        }
    }

    private func emitDiscardedSourceFrames(_ frames: Int, sampleRate: Double) {
        guard frames > 0 else { return }
        output.emit(.queueOverrun(
            clock.now(),
            droppedSourceFrames: frames,
            durationSeconds: Double(frames) / sampleRate
        ))
    }

    private func emitRingDrops(from ring: RealtimeAudioRing) {
        var remaining = ring.takeDroppedSourceFrames()
        while remaining > 0 {
            let count = min(remaining, UInt64(Int.max))
            output.emit(.queueOverrun(
                clock.now(),
                droppedSourceFrames: Int(count),
                durationSeconds: Double(count) / ring.sampleRate
            ))
            remaining -= count
        }
    }

    private func captureTime(for metadata: RealtimeAudioMetadata) -> ClockReading {
        let now = clock.now()
        guard let hostTime = metadata.hostTime else { return now }
        let currentHostTime = mach_absolute_time()
        guard currentHostTime >= hostTime else { return now }
        let age = AVAudioTime.seconds(forHostTime: currentHostTime - hostTime)
        guard age.isFinite, age >= 0 else { return now }
        return ClockReading(
            wallUTC: now.wallUTC.addingTimeInterval(-age),
            monotonicSeconds: now.monotonicSeconds - age,
            clockEpoch: now.clockEpoch
        )
    }

    private func removeTapAndObserver() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Nonisolated factory is load-bearing: closures created in actor/main-actor
    /// contexts can carry dynamic isolation and trap on CoreAudio's realtime thread.
    private nonisolated static func makeTap(
        ring: RealtimeAudioRing
    ) -> AVAudioNodeTapBlock {
        { @Sendable buffer, time in
            _ = ring.push(buffer: buffer, time: time)
        }
    }

    private nonisolated static func makeConfigurationHandler(
        emitter: CaptureEventEmitter,
        clock: any PrivyClock
    ) -> @Sendable (Notification) -> Void {
        { @Sendable _ in
            emitter.emit(.configurationChanged(clock.now()))
        }
    }

    private nonisolated static func defaultInputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }
}
