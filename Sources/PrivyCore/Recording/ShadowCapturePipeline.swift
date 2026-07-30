import Foundation

actor ShadowCapturePipeline: ShadowCaptureControlling {
    private struct VADLaneItem: Sendable {
        let block: AudioBlock16k
        let generation: UInt64
    }

    private struct ChunkSpan: Sendable {
        let record: ChunkRecord
        var endMonotonic: Double?
    }

    private struct AccountedOverrun: Sendable {
        let captureEpoch: UUID
        let streamEndBeforeDrop: Int64
        let expectedResumedStreamStart: Int64
    }

    nonisolated let snapshots: AsyncStream<PipelineSnapshot>

    private let snapshotContinuation: AsyncStream<PipelineSnapshot>.Continuation
    private let capture: any AudioCapturing
    private let writer: any ShadowChunkWriting
    private let vad: any VADAnalyzing
    private let store: any PrivyStoring
    private let clock: any PrivyClock
    private let vadLane: AsyncStream<VADLaneItem>
    private let vadContinuation: AsyncStream<VADLaneItem>.Continuation

    private var watchdog: GapWatchdog
    private var captureReality: CaptureReality = .stopped
    private var vadRuntimeStatus: VADRuntimeStatus = .notStarted
    private var currentChunk: ChunkRecord?
    private var bytesRecordedToday: Int64 = 0
    private var recentHealth: [HealthEvent] = []
    private var lastAudioAtUTC: Date?
    private var engineRunning = false
    private var shuttingDown = false
    private var sleepStarted: ClockReading?
    private var pendingRecoveryGapStart: ClockReading?
    private var pauseDeadlineUTC: Date?
    private var pausedIntentionally = false
    private var pendingDeviceUID: String?
    private var deviceRestartGeneration: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var intentionalStopReason: StopReason?
    private var terminalFailureInProgress = false
    private var accountedOverrun: AccountedOverrun?

    private var lastCaptureEpoch: UUID?
    private var lastSequence: UInt64?
    private var lastStreamEnd: Int64?
    private var inFlightCaptureEpoch: UUID?
    private var inFlightStreamEnd: Int64?
    private var vadGeneration: UInt64 = 0
    private var chunkSpans: [ChunkSpan] = []
    private var pendingVADEvents: [VADEventRecord] = []
    private var vadPersistenceFailed = false
    private var discardedErrorSamples: Int64 = 0
    private var discardedErrorStartedAt: ClockReading?
    private var discardedErrorEndedAt: ClockReading?

    private var audioTask: Task<Void, Never>?
    private var captureEventTask: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?
    private var vadPreparationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var deviceRestartTask: Task<Void, Never>?
    private var discardedErrorTask: Task<Void, Never>?

    init(
        capture: any AudioCapturing,
        writer: any ShadowChunkWriting,
        vad: any VADAnalyzing,
        store: any PrivyStoring,
        clock: any PrivyClock,
        vadLaneCapacity: Int = 8
    ) {
        precondition(vadLaneCapacity > 0)
        self.capture = capture
        self.writer = writer
        self.vad = vad
        self.store = store
        self.clock = clock
        self.watchdog = GapWatchdog(clock: clock)

        let snapshotPair = AsyncStream<PipelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.snapshots = snapshotPair.stream
        self.snapshotContinuation = snapshotPair.continuation

        let vadPair = AsyncStream<VADLaneItem>.makeStream(
            bufferingPolicy: .bufferingOldest(vadLaneCapacity)
        )
        self.vadLane = vadPair.stream
        self.vadContinuation = vadPair.continuation
    }

    func start() async {
        guard case .stopped = captureReality else { return }
        shuttingDown = false
        terminalFailureInProgress = false
        intentionalStopReason = nil
        captureReality = .starting
        publishSnapshot()

        do {
            let summary = try await store.menuSummary(
                dayContaining: clock.now().wallUTC,
                healthLimit: 20
            )
            bytesRecordedToday = summary.bytesRecordedToday
            recentHealth = summary.recentHealth
        } catch {
            captureReality = .error("store unavailable: \(error)")
            appendLocalHealth(
                kind: .error,
                severity: .error,
                at: clock.now(),
                message: "cannot load pipeline summary: \(error)"
            )
            publishSnapshot()
            return
        }

        await persistHealth(kind: .startup, severity: .info, at: clock.now(), message: "shadow pipeline starting")
        await persistHealth(kind: .vadPreparing, severity: .info, at: clock.now(), message: "preparing speech model")
        vadRuntimeStatus = .preparingModel

        let streams = capture.streams
        audioTask = Task { [weak self] in
            for await block in streams.audio {
                guard !Task.isCancelled else { break }
                await self?.receive(block)
            }
        }
        captureEventTask = Task { [weak self] in
            for await event in streams.events {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
        vadTask = Task { [weak self] in
            await self?.consumeVADLane()
        }
        vadPreparationTask = Task { [weak self] in
            guard let self else { return }
            await self.vad.prepare()
            await self.vadPreparationCompleted()
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { break }
                await self?.tick()
            }
        }

        do {
            try await capture.start()
            // The first successfully written audio block is still required before the
            // observed state can become `.recording`.
        } catch {
            await enterTerminalCaptureError(
                message: "capture start failed: \(error)",
                at: clock.now(),
                recoverWriter: false
            )
        }
        publishSnapshot()
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        lifecycleGeneration &+= 1
        intentionalStopReason = .shutdown
        watchdog.disarm()
        pauseDeadlineUTC = nil
        deviceRestartTask?.cancel()
        timerTask?.cancel()

        let now = clock.now()
        do {
            apply(try await writer.close(reason: .shutdown, at: now))
        } catch {
            await reportWriterError(error, at: now)
        }
        await capture.stop(reason: .shutdown)
        engineRunning = false
        currentChunk = nil
        captureReality = .stopped

        audioTask?.cancel()
        captureEventTask?.cancel()
        vadPreparationTask?.cancel()
        discardedErrorTask?.cancel()
        await flushDiscardedErrorBlocks(at: now)
        vadContinuation.finish()
        await vadTask?.value
        await flushVADEvents()
        await persistHealth(kind: .recordingStopped, severity: .info, at: now, message: "shadow recording stopped")
        snapshotContinuation.finish()
    }

    func pause(untilUTC: Date?) async {
        guard !shuttingDown, !terminalFailureInProgress else { return }
        lifecycleGeneration &+= 1
        intentionalStopReason = .manualPause
        watchdog.disarm()
        pauseDeadlineUTC = untilUTC
        pausedIntentionally = true
        captureReality = .paused(untilUTC: untilUTC)
        publishSnapshot()

        let now = clock.now()
        do {
            apply(try await writer.close(reason: .manualPause, at: now))
        } catch {
            await reportWriterError(error, at: now)
        }
        await capture.stop(reason: .manualPause)
        engineRunning = false
        currentChunk = nil
        resetCaptureContinuity()
        await persistHealth(
            kind: .recordingStopped,
            severity: .info,
            at: now,
            message: untilUTC == nil ? "recording paused until resumed" : "recording paused until \(untilUTC!)"
        )
        publishSnapshot()
    }

    func resume() async {
        guard !shuttingDown, !terminalFailureInProgress else { return }
        guard pausedIntentionally else { return }
        pauseDeadlineUTC = nil
        pausedIntentionally = false
        await restartCapture(reason: .manualRetry, message: "manual resume")
    }

    func handle(_ event: MonitorEvent) async {
        guard !shuttingDown else { return }
        switch event {
        case .willSleep(let at):
            await willSleep(at: at)
        case .didWake(let at):
            await didWake(at: at)
        case .defaultInputChanged(_, let deviceUID):
            scheduleDeviceRestart(deviceUID: deviceUID)
        case .deviceListChanged:
            scheduleDeviceRestart(deviceUID: nil)
        }
    }

    private func willSleep(at: ClockReading) async {
        lifecycleGeneration &+= 1
        intentionalStopReason = .systemSleep
        watchdog.disarm()
        sleepStarted = at
        captureReality = .recovering("system sleep")
        publishSnapshot()
        await persistHealth(kind: .sleep, severity: .info, at: at, message: "system will sleep")

        do {
            apply(try await writer.close(reason: .systemSleep, at: at))
        } catch {
            await reportWriterError(error, at: at)
        }
        await capture.stop(reason: .systemSleep)
        engineRunning = false
        currentChunk = nil
        resetCaptureContinuity()
        publishSnapshot()
    }

    private func didWake(at: ClockReading) async {
        await persistHealth(kind: .wake, severity: .info, at: at, message: "system did wake")
        if let sleepStarted {
            let duration = max(0, clock.elapsedSeconds(from: sleepStarted, to: at))
            await persistHealth(
                kind: .gap,
                severity: .warning,
                at: at,
                message: "measured system sleep gap",
                gapStarted: sleepStarted,
                gapEnded: at,
                durationSeconds: duration
            )
            self.sleepStarted = nil
        }

        if pausedIntentionally {
            if let pauseDeadlineUTC, at.wallUTC >= pauseDeadlineUTC {
                self.pauseDeadlineUTC = nil
                pausedIntentionally = false
                await restartCapture(reason: .manualRetry, message: "timed pause expired during sleep")
            } else {
                captureReality = .paused(untilUTC: pauseDeadlineUTC)
                publishSnapshot()
            }
            return
        }

        intentionalStopReason = nil
        captureReality = .recovering("waking audio capture")
        watchdog.beginWakeGrace(at: at)
        publishSnapshot()
        do {
            try await capture.restart(reason: .systemWake)
            await persistHealth(
                kind: .engineRestart,
                severity: .info,
                at: at,
                message: "capture rebuilt after wake"
            )
        } catch {
            await enterTerminalCaptureError(
                message: "wake restart failed: \(error)",
                at: at,
                recoverWriter: true
            )
        }
        publishSnapshot()
    }

    private func scheduleDeviceRestart(deviceUID: String?) {
        pendingDeviceUID = deviceUID ?? pendingDeviceUID
        deviceRestartGeneration &+= 1
        let generation = deviceRestartGeneration
        deviceRestartTask?.cancel()
        deviceRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.performDeviceRestart(generation: generation)
        }
    }

    private func performDeviceRestart(generation: UInt64) async {
        guard generation == deviceRestartGeneration, !shuttingDown else { return }
        // A real device change is also the recovery path from terminal input loss.
        // The failure episode remains latched until fresh audio reaches a new chunk.
        let now = clock.now()
        let uid = pendingDeviceUID
        pendingDeviceUID = nil
        lifecycleGeneration &+= 1
        intentionalStopReason = .deviceChange
        watchdog.disarm()
        captureReality = .recovering("audio device changed")
        publishSnapshot()
        await persistHealth(
            kind: .deviceChange,
            severity: .info,
            at: now,
            message: "audio input configuration changed",
            deviceUID: uid
        )
        do {
            apply(try await writer.close(reason: .deviceChange, at: now))
        } catch {
            await reportWriterError(error, at: now)
            return
        }
        currentChunk = nil
        resetCaptureContinuity()
        await restartCapture(
            reason: .deviceChange,
            message: "capture rebuilt for device change",
            deviceUID: uid
        )
    }

    private func restartCapture(
        reason: RestartReason,
        message: String,
        deviceUID: String? = nil
    ) async {
        let now = clock.now()
        intentionalStopReason = nil
        watchdog.disarm()
        captureReality = .recovering(message)
        publishSnapshot()
        do {
            try await capture.restart(reason: reason)
            await persistHealth(
                kind: .engineRestart,
                severity: .info,
                at: now,
                message: message,
                deviceUID: deviceUID
            )
        } catch {
            await enterTerminalCaptureError(
                message: "capture restart failed: \(error)",
                at: now,
                recoverWriter: true
            )
        }
        publishSnapshot()
    }

    // MARK: - Capture input

    private func receive(_ block: AudioBlock16k) async {
        guard !shuttingDown else { return }
        switch captureReality {
        case .paused, .stopped:
            return
        case .error:
            recordDiscardedErrorBlock(block)
            return
        case .starting, .recording, .recovering:
            break
        }

        let generation = lifecycleGeneration
        let discontinuity = reconciledContinuityGap(
            continuityGap(before: block),
            before: block
        )
        inFlightCaptureEpoch = block.captureEpoch
        inFlightStreamEnd = block.streamSampleStart + Int64(block.samples.count)
        let transitions: [WriterTransition]
        do {
            // Lossless-priority lane: this always completes before the VAD copy is
            // offered to its bounded, best-effort lane.
            transitions = try await writer.append(block)
        } catch {
            clearInFlightBlock()
            if generation != lifecycleGeneration || shuttingDown {
                await reportWriterError(error, at: block.firstSampleTime)
                await closeWriterAfterStaleAppend(at: block.firstSampleTime)
                return
            }
            await enterTerminalCaptureError(
                message: "writer failed: \(error)",
                at: clock.now(),
                recoverWriter: false,
                writerFailure: error
            )
            return
        }

        guard generation == lifecycleGeneration, !shuttingDown else {
            clearInFlightBlock()
            apply(transitions)
            await closeWriterAfterStaleAppend(at: block.firstSampleTime)
            return
        }
        switch captureReality {
        case .paused, .stopped, .error:
            clearInFlightBlock()
            apply(transitions)
            await closeWriterAfterStaleAppend(at: block.firstSampleTime)
            return
        case .starting, .recording, .recovering:
            apply(transitions)
        }

        if let discontinuity {
            vadGeneration &+= 1
            await persistHealth(
                kind: .gap,
                severity: .warning,
                at: block.firstSampleTime,
                message: discontinuity.message,
                durationSeconds: discontinuity.duration,
                droppedFrames: discontinuity.droppedFrames
            )
            await persistHealth(
                kind: .vadGap,
                severity: .warning,
                at: block.firstSampleTime,
                message: "VAD continuity reset after source discontinuity",
                durationSeconds: discontinuity.duration,
                droppedFrames: discontinuity.droppedFrames
            )
        }

        lastCaptureEpoch = block.captureEpoch
        lastSequence = block.sequence
        lastStreamEnd = block.streamSampleStart + Int64(block.samples.count)
        clearInFlightBlock()
        engineRunning = true
        currentChunk = await writer.activeChunk()

        let heartbeat = readingAtEnd(of: block)
        let now = clock.now()
        let age = clock.elapsedSeconds(from: heartbeat, to: now)
        lastAudioAtUTC = heartbeat.wallUTC
        if age >= 0, age < 2, currentChunk != nil {
            if let gapStart = pendingRecoveryGapStart {
                await persistHealth(
                    kind: .gap,
                    severity: .warning,
                    at: now,
                    message: "audio resumed after heartbeat restart",
                    gapStarted: gapStart,
                    gapEnded: now,
                    durationSeconds: max(0, clock.elapsedSeconds(from: gapStart, to: now))
                )
                pendingRecoveryGapStart = nil
            }
            if watchdog.isInWakeGrace {
                watchdog.arm(withFreshHeartbeat: now)
            } else if watchdog.isArmed {
                watchdog.heartbeat(now)
            } else {
                watchdog.arm(withFreshHeartbeat: now)
            }
            if captureReality != .recording {
                captureReality = .recording
                // A fresh heartbeat reaching an open writer proves recovery completed;
                // allow controls and future terminal episodes to run normally again.
                terminalFailureInProgress = false
                await persistHealth(
                    kind: .recordingStarted,
                    severity: .info,
                    at: now,
                    message: "fresh audio reached the open shadow chunk"
                )
            }
        } else {
            if !watchdog.isArmed, !watchdog.isInWakeGrace {
                watchdog.arm(withFreshHeartbeat: heartbeat)
            }
            captureReality = .recovering("audio heartbeat is stale")
        }
        publishSnapshot()

        let item = VADLaneItem(block: block, generation: vadGeneration)
        switch vadContinuation.yield(item) {
        case .enqueued:
            break
        case .dropped:
            vadGeneration &+= 1
            await persistHealth(
                kind: .vadGap,
                severity: .warning,
                at: now,
                message: "VAD lane full; dropped one \(block.samples.count)-sample converted block",
                durationSeconds: Double(block.samples.count) / Double(privySampleRate)
            )
        case .terminated:
            if !shuttingDown {
                vadGeneration &+= 1
                await persistHealth(
                    kind: .vadGap,
                    severity: .error,
                    at: now,
                    message: "VAD lane terminated; dropped one converted block",
                    durationSeconds: Double(block.samples.count) / Double(privySampleRate)
                )
            }
        @unknown default:
            vadGeneration &+= 1
            await persistHealth(
                kind: .vadGap,
                severity: .error,
                at: now,
                message: "unknown VAD lane yield result; block not trusted"
            )
        }
    }

    private func receive(_ event: CaptureEvent) async {
        guard !shuttingDown else { return }
        switch event {
        case .engineStarted:
            engineRunning = true
            if case .stopped = captureReality { captureReality = .starting }

        case .engineStopped(let at, let reason):
            engineRunning = false
            if reason == .fatalError {
                await enterTerminalCaptureError(
                    message: "capture engine stopped fatally",
                    at: at,
                    recoverWriter: true
                )
            }

        case .configurationChanged:
            scheduleDeviceRestart(deviceUID: nil)

        case .inputUnavailable(let at, let detail):
            await enterTerminalCaptureError(
                message: "input unavailable: \(detail)",
                at: at,
                recoverWriter: true
            )

        case .queueOverrun(let at, let droppedFrames, let duration):
            vadGeneration &+= 1
            let baselineEpoch = inFlightCaptureEpoch ?? lastCaptureEpoch
            let baselineEnd = inFlightStreamEnd ?? lastStreamEnd
            if let baselineEpoch, let baselineEnd {
                let normalizedDrop = max(0, Int64((duration * Double(privySampleRate)).rounded()))
                if let existing = accountedOverrun,
                   existing.captureEpoch == baselineEpoch,
                   existing.streamEndBeforeDrop == baselineEnd {
                    accountedOverrun = AccountedOverrun(
                        captureEpoch: existing.captureEpoch,
                        streamEndBeforeDrop: existing.streamEndBeforeDrop,
                        expectedResumedStreamStart: existing.expectedResumedStreamStart + normalizedDrop
                    )
                } else {
                    accountedOverrun = AccountedOverrun(
                        captureEpoch: baselineEpoch,
                        streamEndBeforeDrop: baselineEnd,
                        expectedResumedStreamStart: baselineEnd + normalizedDrop
                    )
                }
            } else {
                accountedOverrun = nil
            }
            captureReality = .recovering("capture queue overrun")
            await persistHealth(
                kind: .queueOverrun,
                severity: .warning,
                at: at,
                message: "capture queue dropped source frames",
                durationSeconds: duration,
                droppedFrames: Int64(droppedFrames)
            )
            await persistHealth(
                kind: .gap,
                severity: .warning,
                at: at,
                message: "audio gap from capture queue overrun",
                durationSeconds: duration,
                droppedFrames: Int64(droppedFrames)
            )
            await persistHealth(
                kind: .vadGap,
                severity: .warning,
                at: at,
                message: "VAD continuity reset after queue overrun",
                durationSeconds: duration,
                droppedFrames: Int64(droppedFrames)
            )

        case .conversionFailed(let at, let detail):
            vadGeneration &+= 1
            captureReality = .recovering("audio conversion failed")
            await persistHealth(
                kind: .gap,
                severity: .error,
                at: at,
                message: "audio conversion failed: \(detail)"
            )
        }
        publishSnapshot()
    }

    private struct ContinuityGap {
        let message: String
        let duration: Double?
        let droppedFrames: Int64?
    }

    private func continuityGap(before block: AudioBlock16k) -> ContinuityGap? {
        guard let lastCaptureEpoch, let lastSequence, let lastStreamEnd else { return nil }
        guard lastCaptureEpoch != block.captureEpoch
                || lastSequence &+ 1 != block.sequence
                || lastStreamEnd != block.streamSampleStart else { return nil }
        let missing = max(0, block.streamSampleStart - lastStreamEnd)
        return ContinuityGap(
            message: "source timeline discontinuity before sequence \(block.sequence)",
            duration: missing > 0 ? Double(missing) / Double(privySampleRate) : nil,
            droppedFrames: missing > 0 ? missing : nil
        )
    }

    private func reconciledContinuityGap(
        _ measured: ContinuityGap?,
        before block: AudioBlock16k
    ) -> ContinuityGap? {
        guard let accountedOverrun else { return measured }
        self.accountedOverrun = nil
        guard accountedOverrun.captureEpoch == block.captureEpoch,
              block.streamSampleStart >= accountedOverrun.streamEndBeforeDrop else {
            return measured
        }

        let unaccountedSamples = max(
            0,
            block.streamSampleStart - accountedOverrun.expectedResumedStreamStart
        )
        guard unaccountedSamples > 0 else { return nil }
        return ContinuityGap(
            message: "unaccounted source timeline discontinuity after queue overrun before sequence \(block.sequence)",
            duration: Double(unaccountedSamples) / Double(privySampleRate),
            droppedFrames: unaccountedSamples
        )
    }

    // MARK: - VAD lane

    private func consumeVADLane() async {
        var consumedGeneration: UInt64?
        for await item in vadLane {
            guard !Task.isCancelled else { break }
            guard !vadPersistenceFailed else { continue }
            if consumedGeneration != item.generation {
                await vad.reset(afterGapAt: item.block.firstSampleTime)
                consumedGeneration = item.generation
            }
            do {
                let observations = try await vad.process(item.block)
                await consume(observations)
            } catch {
                let status = await vad.status()
                vadRuntimeStatus = status
                await persistHealth(
                    kind: .vadError,
                    severity: .error,
                    at: clock.now(),
                    message: "VAD processing failed without stopping recording: \(error)"
                )
            }
        }
    }

    private func vadPreparationCompleted() async {
        vadRuntimeStatus = await vad.status()
        switch vadRuntimeStatus {
        case .ready:
            await persistHealth(kind: .vadReady, severity: .info, at: clock.now(), message: "speech model ready")
        case .failed(let message):
            await persistHealth(
                kind: .vadError,
                severity: .error,
                at: clock.now(),
                message: "speech model unavailable; recording continues: \(message)"
            )
        case .notStarted, .preparingModel:
            break
        }
        publishSnapshot()
    }

    private func consume(_ observations: [VADObservation]) async {
        for observation in observations {
            guard let chunkID = chunkID(containing: observation.monotonicSeconds) else {
                await persistHealth(
                    kind: .vadGap,
                    severity: .warning,
                    at: clock.now(),
                    message: "VAD observation could not be mapped to a chunk at monotonic \(observation.monotonicSeconds)"
                )
                continue
            }
            pendingVADEvents.append(VADEventRecord(
                chunkID: chunkID,
                monotonicSeconds: observation.monotonicSeconds,
                kind: .score,
                score: observation.probability
            ))
            if let boundary = observation.boundary {
                pendingVADEvents.append(VADEventRecord(
                    chunkID: chunkID,
                    monotonicSeconds: observation.monotonicSeconds,
                    kind: boundary,
                    score: nil
                ))
            }
        }
        let scoreCount = pendingVADEvents.reduce(into: 0) { count, event in
            if event.kind == .score { count += 1 }
        }
        if scoreCount >= 4 {
            await flushVADEvents()
        }
    }

    private func flushVADEvents() async {
        guard !pendingVADEvents.isEmpty else { return }
        let events = pendingVADEvents
        do {
            try await store.appendVADEvents(events)
            pendingVADEvents.removeFirst(events.count)
        } catch {
            pendingVADEvents.removeAll()
            vadPersistenceFailed = true
            let message = "VAD observations could not be persisted; recording continues: \(error)"
            vadRuntimeStatus = .failed(message)
            await vad.reset(afterGapAt: clock.now())
            await persistVADHealthBestEffort(message: message, at: clock.now())
            publishSnapshot()
        }
    }

    private func chunkID(containing monotonicSeconds: Double) -> Int64? {
        chunkSpans.reversed().first { span in
            guard monotonicSeconds >= span.record.startedMono else { return false }
            if let end = span.endMonotonic {
                return monotonicSeconds < end
            }
            return true
        }?.record.id
    }

    // MARK: - Watchdog

    func tick() async {
        guard !shuttingDown else { return }
        switch captureReality {
        case .error, .stopped:
            return
        case .starting, .recording, .paused, .recovering:
            break
        }
        let now = clock.now()
        if let pauseDeadlineUTC, now.wallUTC >= pauseDeadlineUTC {
            if pausedIntentionally {
                self.pauseDeadlineUTC = nil
                pausedIntentionally = false
                await restartCapture(reason: .manualRetry, message: "timed pause expired")
            }
            return
        }

        let actions = watchdog.tick(at: now)
        for action in actions {
            switch action {
            case .restart(let heartbeat, let detectedAt):
                lifecycleGeneration &+= 1
                intentionalStopReason = .restart
                watchdog.disarm()
                pendingRecoveryGapStart = heartbeat
                captureReality = .recovering("audio heartbeat timed out")
                publishSnapshot()
                do {
                    apply(try await writer.close(reason: .restart, at: detectedAt))
                    currentChunk = nil
                    resetCaptureContinuity()
                } catch {
                    pendingRecoveryGapStart = nil
                    await enterTerminalCaptureError(
                        message: "writer failed during heartbeat restart: \(error)",
                        at: detectedAt,
                        recoverWriter: false,
                        writerFailure: error
                    )
                    continue
                }
                intentionalStopReason = nil
                do {
                    try await capture.restart(reason: .heartbeatTimeout)
                    await persistHealth(
                        kind: .engineRestart,
                        severity: .warning,
                        at: detectedAt,
                        message: "one restart attempt after 2-second heartbeat timeout"
                    )
                    if captureReality != .recording {
                        watchdog.beginRestartRecovery(since: heartbeat)
                    }
                } catch {
                    captureReality = .recovering("heartbeat restart failed")
                    watchdog.beginRestartRecovery(since: heartbeat)
                    await persistHealth(
                        kind: .error,
                        severity: .error,
                        at: detectedAt,
                        message: "heartbeat restart attempt failed: \(error)"
                    )
                }

            case .heartbeatFault(let heartbeat, let detectedAt):
                pendingRecoveryGapStart = nil
                await enterTerminalCaptureError(
                    message: "capture declared dead after 5-second heartbeat timeout",
                    at: detectedAt,
                    recoverWriter: true,
                    gapStarted: heartbeat,
                    gapMessage: "audio heartbeat absent after restart attempt"
                )

            case .wakeGraceExpired(let wake, let detectedAt):
                await enterTerminalCaptureError(
                    message: "10-second wake grace expired",
                    at: detectedAt,
                    recoverWriter: true,
                    gapStarted: wake,
                    gapMessage: "wake recovery produced no fresh audio"
                )
            }
        }
        publishSnapshot()
    }

    // MARK: - Terminal failure and discarded audio

    private func enterTerminalCaptureError(
        message: String,
        at: ClockReading,
        recoverWriter: Bool,
        writerFailure: Error? = nil,
        gapStarted: ClockReading? = nil,
        gapMessage: String? = nil
    ) async {
        if terminalFailureInProgress {
            // Duplicate fatal callbacks emitted by the stop path observe `.error` and
            // are ignored. A recovery attempt that has moved back to `.recovering`
            // must still fail visibly instead of being swallowed by this re-entry guard.
            guard case .recovering = captureReality else { return }
            lifecycleGeneration &+= 1
            intentionalStopReason = .fatalError
            watchdog.disarm()
            captureReality = .error(message)
            publishSnapshot()
            // The first episode already terminally resolved its writer; this branch
            // handles failure before recovery has accepted fresh audio into a new chunk.
            await capture.stop(reason: .fatalError)
            engineRunning = false
            if let writerFailure {
                await reportWriterError(writerFailure, at: at)
            }
            await persistHealth(kind: .error, severity: .error, at: at, message: message)
            publishSnapshot()
            return
        }
        if case .error = captureReality { return }
        terminalFailureInProgress = true
        defer { terminalFailureInProgress = false }
        lifecycleGeneration &+= 1
        intentionalStopReason = .fatalError
        watchdog.disarm()
        captureReality = .error(message)
        publishSnapshot()

        await capture.stop(reason: .fatalError)
        engineRunning = false

        if let writerFailure {
            await reportWriterError(writerFailure, at: at)
        }
        if recoverWriter {
            let hadActiveChunk = await writer.activeChunk() != nil
            do {
                apply(try await writer.close(reason: .fatalError, at: at))
                if hadActiveChunk {
                    await persistHealth(
                        kind: .recovery,
                        severity: .warning,
                        at: at,
                        message: "fatal writer recovery terminally resolved the active chunk"
                    )
                }
            } catch {
                await reportWriterError(error, at: at)
            }
        }
        currentChunk = nil

        if let gapStarted, let gapMessage {
            await persistHealth(
                kind: .gap,
                severity: .error,
                at: at,
                message: gapMessage,
                gapStarted: gapStarted,
                gapEnded: at,
                durationSeconds: max(0, clock.elapsedSeconds(from: gapStarted, to: at))
            )
        }
        await persistHealth(kind: .error, severity: .error, at: at, message: message)
        await flushDiscardedErrorBlocks(at: at)
        publishSnapshot()
    }

    private func closeWriterAfterStaleAppend(at: ClockReading) async {
        let reason = intentionalStopReason ?? .restart
        let hadActiveChunk = await writer.activeChunk() != nil
        do {
            apply(try await writer.close(reason: reason, at: at))
            if reason == .fatalError, hadActiveChunk {
                await persistHealth(
                    kind: .recovery,
                    severity: .warning,
                    at: at,
                    message: "fatal writer recovery resolved a chunk opened by an interleaved append"
                )
            }
        } catch {
            await reportWriterError(error, at: at)
        }
        currentChunk = nil
    }

    private func recordDiscardedErrorBlock(_ block: AudioBlock16k) {
        discardedErrorSamples += Int64(block.samples.count)
        if discardedErrorStartedAt == nil {
            discardedErrorStartedAt = block.firstSampleTime
        }
        discardedErrorEndedAt = readingAtEnd(of: block)
        discardedErrorTask?.cancel()
        discardedErrorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.flushDiscardedErrorBlocks(at: nil)
        }
    }

    private func flushDiscardedErrorBlocks(at reading: ClockReading?) async {
        guard discardedErrorSamples > 0,
              let started = discardedErrorStartedAt,
              let ended = discardedErrorEndedAt else { return }
        let samples = discardedErrorSamples
        discardedErrorSamples = 0
        discardedErrorStartedAt = nil
        discardedErrorEndedAt = nil
        discardedErrorTask?.cancel()
        discardedErrorTask = nil
        await persistHealth(
            kind: .gap,
            severity: .error,
            at: reading ?? ended,
            message: "discarded \(samples) converted samples after terminal capture failure",
            gapStarted: started,
            gapEnded: ended,
            durationSeconds: Double(samples) / Double(privySampleRate)
        )
    }

    private func persistVADHealthBestEffort(message: String, at: ClockReading) async {
        let event = makeHealthEvent(
            kind: .vadError,
            severity: .error,
            at: at,
            message: message
        )
        do {
            try await store.appendHealth(event)
        } catch {
            appendLocalHealth(
                kind: .vadError,
                severity: .error,
                at: at,
                message: "\(message); health persistence also failed: \(error)"
            )
            return
        }
        recentHealth.append(event)
        if recentHealth.count > 20 {
            recentHealth.removeFirst(recentHealth.count - 20)
        }
    }

    // MARK: - Writer transitions and health

    private func apply(_ transitions: [WriterTransition]) {
        for transition in transitions {
            switch transition {
            case .opened(let record):
                currentChunk = record
                chunkSpans.append(ChunkSpan(record: record, endMonotonic: nil))

            case .checkpointed:
                break

            case .finalized(let record):
                if let index = chunkSpans.lastIndex(where: { $0.record.id == record.id }) {
                    chunkSpans[index].endMonotonic = record.startedMono + record.durationSeconds
                }
                if currentChunk?.id == record.id {
                    currentChunk = nil
                }
                bytesRecordedToday += record.sizeBytes
            }
        }
    }

    private func reportWriterError(_ error: Error, at: ClockReading) async {
        await persistHealth(
            kind: .writerError,
            severity: .error,
            at: at,
            message: "shadow writer failure: \(error)"
        )
    }

    @discardableResult
    private func persistHealth(
        kind: HealthKind,
        severity: HealthSeverity,
        at: ClockReading,
        message: String,
        gapStarted: ClockReading? = nil,
        gapEnded: ClockReading? = nil,
        durationSeconds: Double? = nil,
        deviceUID: String? = nil,
        droppedFrames: Int64? = nil
    ) async -> Bool {
        let event = makeHealthEvent(
            kind: kind,
            severity: severity,
            at: at,
            message: message,
            gapStarted: gapStarted,
            gapEnded: gapEnded,
            durationSeconds: durationSeconds,
            deviceUID: deviceUID,
            droppedFrames: droppedFrames
        )
        do {
            try await store.appendHealth(event)
            recentHealth.append(event)
            if recentHealth.count > 20 {
                recentHealth.removeFirst(recentHealth.count - 20)
            }
            publishSnapshot()
            return true
        } catch {
            recentHealth.append(event)
            appendLocalHealth(
                kind: .error,
                severity: .error,
                at: at,
                message: "health event \(kind.rawValue) could not be persisted: \(error)"
            )
            publishSnapshot()
            return false
        }
    }

    private func appendLocalHealth(
        kind: HealthKind,
        severity: HealthSeverity,
        at: ClockReading,
        message: String
    ) {
        recentHealth.append(makeHealthEvent(
            kind: kind,
            severity: severity,
            at: at,
            message: message
        ))
        if recentHealth.count > 20 {
            recentHealth.removeFirst(recentHealth.count - 20)
        }
    }

    private func makeHealthEvent(
        kind: HealthKind,
        severity: HealthSeverity,
        at: ClockReading,
        message: String,
        gapStarted: ClockReading? = nil,
        gapEnded: ClockReading? = nil,
        durationSeconds: Double? = nil,
        deviceUID: String? = nil,
        droppedFrames: Int64? = nil
    ) -> HealthEvent {
        HealthEvent(
            atUTC: at.wallUTC,
            kind: kind,
            severity: severity,
            detail: HealthDetail(
                message: message,
                clockEpoch: at.clockEpoch,
                monotonicSeconds: at.monotonicSeconds,
                gapStartedUTC: gapStarted?.wallUTC,
                gapEndedUTC: gapEnded?.wallUTC,
                durationSeconds: durationSeconds,
                deviceUID: deviceUID,
                droppedFrames: droppedFrames,
                durationIsEstimated: false
            )
        )
    }

    private func clearInFlightBlock() {
        inFlightCaptureEpoch = nil
        inFlightStreamEnd = nil
    }

    private func resetCaptureContinuity() {
        lastCaptureEpoch = nil
        lastSequence = nil
        lastStreamEnd = nil
        clearInFlightBlock()
        accountedOverrun = nil
        vadGeneration &+= 1
    }

    private func readingAtEnd(of block: AudioBlock16k) -> ClockReading {
        let duration = Double(block.samples.count) / Double(privySampleRate)
        return ClockReading(
            wallUTC: block.firstSampleTime.wallUTC.addingTimeInterval(duration),
            monotonicSeconds: block.firstSampleTime.monotonicSeconds + duration,
            clockEpoch: block.firstSampleTime.clockEpoch
        )
    }

    private func publishSnapshot() {
        snapshotContinuation.yield(PipelineSnapshot(
            capture: captureReality,
            vad: vadRuntimeStatus,
            currentChunk: currentChunk,
            bytesRecordedToday: bytesRecordedToday,
            recentHealth: Array(recentHealth.suffix(20)),
            lastAudioAtUTC: lastAudioAtUTC
        ))
    }
}
