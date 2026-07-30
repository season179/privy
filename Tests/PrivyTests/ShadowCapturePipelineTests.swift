import Foundation
import Testing
@testable import PrivyCore

actor PipelineFakeCapture: AudioCapturing {
    nonisolated let streams: CaptureStreams
    private let audioContinuation: AsyncStream<AudioBlock16k>.Continuation
    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation

    private(set) var startCount = 0
    private(set) var stops: [StopReason] = []
    private(set) var restarts: [RestartReason] = []
    var restartError: (any Error)?

    init() {
        let audio = AsyncStream<AudioBlock16k>.makeStream(bufferingPolicy: .bufferingOldest(80))
        let events = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(80))
        streams = CaptureStreams(audio: audio.stream, events: events.stream)
        audioContinuation = audio.continuation
        eventContinuation = events.continuation
    }

    func start() async throws { startCount += 1 }

    func stop(reason: StopReason) async { stops.append(reason) }

    func restart(reason: RestartReason) async throws {
        restarts.append(reason)
        if let restartError { throw restartError }
    }

    func emit(_ block: AudioBlock16k) { audioContinuation.yield(block) }
    func emit(_ event: CaptureEvent) { eventContinuation.yield(event) }

    func finish() {
        audioContinuation.finish()
        eventContinuation.finish()
    }
}

actor SnapshotRecorder {
    private var values: [PipelineSnapshot] = []
    func append(_ value: PipelineSnapshot) { values.append(value) }
    func latest() -> PipelineSnapshot? { values.last }
}

private struct PipelineFixture {
    let pipeline: ShadowCapturePipeline
    let capture: PipelineFakeCapture
    let store: RecordingFakeStore
    let clock: TestClock
    let model: DeterministicVADModel
    let snapshots: SnapshotRecorder
    let root: URL
    let snapshotTask: Task<Void, Never>
}

private func makePipelineFixture(
    rotationSamples: Int = ShadowChunkWriter.rotationSamples,
    vadLaneCapacity: Int = 8,
    model: DeterministicVADModel = DeterministicVADModel()
) throws -> PipelineFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("privy-pipeline-tests-\(UUID())", isDirectory: true)
    let audio = root.appendingPathComponent("Audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    let layout = StorageLayout(
        rootDirectory: root,
        databaseURL: root.appendingPathComponent("test.sqlite"),
        audioDirectory: audio
    )
    let store = RecordingFakeStore()
    let writer = ShadowChunkWriter(
        store: store,
        storage: layout,
        rotationSamples: rotationSamples
    )
    let capture = PipelineFakeCapture()
    let clock = TestClock(wall: Date(timeIntervalSince1970: 1_700_000_000), mono: 0)
    let vad = VADService(model: model)
    let pipeline = ShadowCapturePipeline(
        capture: capture,
        writer: writer,
        vad: vad,
        store: store,
        clock: clock,
        vadLaneCapacity: vadLaneCapacity
    )
    let recorder = SnapshotRecorder()
    let stream = pipeline.snapshots
    let task = Task {
        for await snapshot in stream {
            await recorder.append(snapshot)
        }
    }
    return PipelineFixture(
        pipeline: pipeline,
        capture: capture,
        store: store,
        clock: clock,
        model: model,
        snapshots: recorder,
        root: root,
        snapshotTask: task
    )
}

private func pipelineBlock(
    count: Int = 1_600,
    start: Int64,
    sequence: UInt64,
    reading: ClockReading,
    captureEpoch: UUID
) -> AudioBlock16k {
    AudioBlock16k(
        captureEpoch: captureEpoch,
        sequence: sequence,
        streamSampleStart: start,
        firstSampleTime: reading,
        samples: [Float](repeating: 0.05, count: count)
    )
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while ContinuousClock().now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func cleanUp(_ fixture: PipelineFixture) async {
    await fixture.pipeline.shutdown()
    await fixture.capture.finish()
    fixture.snapshotTask.cancel()
    try? FileManager.default.removeItem(at: fixture.root)
}

@Suite struct ShadowCapturePipelineTests {
    @Test func pausingForOneFakeClockHourProducesZeroGapErrorOrWatchdogRestartEvents() async throws {
        let fixture = try makePipelineFixture()
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let epoch = UUID()
        let firstSample = fixture.clock.now()
        fixture.clock.advance(seconds: 0.1)
        await fixture.capture.emit(pipelineBlock(
            start: 0,
            sequence: 0,
            reading: firstSample,
            captureEpoch: epoch
        ))
        #expect(await waitUntil {
            (await fixture.store.allChunks()).contains { $0.state == .recording }
        })

        let deadline = fixture.clock.now().wallUTC.addingTimeInterval(3_600)
        await fixture.pipeline.pause(untilUTC: deadline)
        fixture.clock.advance(seconds: 3_600)
        await fixture.pipeline.tick()
        #expect(await waitUntil { await fixture.capture.restarts.contains(.manualRetry) })

        let health = await fixture.store.allHealth()
        #expect(health.filter { $0.kind == .gap }.isEmpty)
        #expect(health.filter { $0.kind == .error }.isEmpty)
        #expect(health.filter {
            $0.kind == .engineRestart && $0.detail.message.contains("heartbeat")
        }.isEmpty)
        #expect((await fixture.capture.restarts).filter { $0 == .heartbeatTimeout }.isEmpty)
        await fixture.pipeline.shutdown()
    }

    @Test func wakingAfterLongSleepAndAudioWithinGraceProducesExactlyOneSleepOneWakeOneMeasuredSleepGapAndNoWatchdogFault() async throws {
        let fixture = try makePipelineFixture()
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let firstEpoch = UUID()
        let firstSample = fixture.clock.now()
        fixture.clock.advance(seconds: 0.1)
        await fixture.capture.emit(pipelineBlock(
            start: 0,
            sequence: 0,
            reading: firstSample,
            captureEpoch: firstEpoch
        ))
        #expect(await waitUntil {
            if case .recording = await fixture.snapshots.latest()?.capture { return true }
            return false
        })

        let sleep = fixture.clock.now()
        await fixture.pipeline.handle(.willSleep(sleep))
        fixture.clock.advanceLikeSleep(seconds: 3_600)
        let wake = fixture.clock.now()
        await fixture.pipeline.handle(.didWake(wake))

        let wakeFirstSample = fixture.clock.now()
        fixture.clock.advance(seconds: 0.1)
        await fixture.capture.emit(pipelineBlock(
            start: 0,
            sequence: 0,
            reading: wakeFirstSample,
            captureEpoch: UUID()
        ))
        #expect(await waitUntil {
            if case .recording = await fixture.snapshots.latest()?.capture { return true }
            return false
        })
        await fixture.pipeline.tick()

        let health = await fixture.store.allHealth()
        #expect(health.filter { $0.kind == .sleep }.count == 1)
        #expect(health.filter { $0.kind == .wake }.count == 1)
        let gaps = health.filter { $0.kind == .gap }
        #expect(gaps.count == 1)
        #expect(gaps.first?.detail.durationSeconds == 3_600)
        #expect(gaps.first?.detail.durationIsEstimated == false)
        #expect(health.filter {
            $0.kind == .error || $0.detail.message.contains("wake grace") || $0.detail.message.contains("heartbeat")
        }.isEmpty)
        #expect((await fixture.capture.restarts).filter { $0 == .heartbeatTimeout }.isEmpty)
        await fixture.pipeline.shutdown()
    }

    @Test func heartbeatLossRestartsOnceThenPublishesErrorAndGap() async throws {
        let fixture = try makePipelineFixture()
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let reading = fixture.clock.now()
        fixture.clock.advance(seconds: 0.1)
        await fixture.capture.emit(pipelineBlock(
            start: 0,
            sequence: 0,
            reading: reading,
            captureEpoch: UUID()
        ))
        #expect(await waitUntil {
            if case .recording = await fixture.snapshots.latest()?.capture { return true }
            return false
        })

        fixture.clock.advance(seconds: 2.1)
        await fixture.pipeline.tick()
        #expect((await fixture.capture.restarts).filter { $0 == .heartbeatTimeout }.count == 1)
        #expect(await waitUntil {
            if case .recovering = await fixture.snapshots.latest()?.capture { return true }
            return false
        })

        fixture.clock.advance(seconds: 3.0)
        await fixture.pipeline.tick()
        #expect(await waitUntil {
            if case .error = await fixture.snapshots.latest()?.capture { return true }
            return false
        })
        let health = await fixture.store.allHealth()
        #expect(health.filter { $0.kind == .gap }.count == 1)
        #expect(health.filter { $0.kind == .error }.count == 1)
        #expect((await fixture.capture.restarts).filter { $0 == .heartbeatTimeout }.count == 1)
        await fixture.pipeline.shutdown()
    }

    @Test func queueOverrunAndDeviceBurstAreVisibleAndDeviceRestartIsCoalesced() async throws {
        let fixture = try makePipelineFixture()
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let at = fixture.clock.now()
        await fixture.capture.emit(.queueOverrun(at, droppedSourceFrames: 4_800, durationSeconds: 0.1))
        await fixture.pipeline.handle(.deviceListChanged(at))
        await fixture.pipeline.handle(.defaultInputChanged(at, deviceUID: "airpods"))
        try await Task.sleep(for: .milliseconds(650))

        let health = await fixture.store.allHealth()
        #expect(health.filter { $0.kind == .queueOverrun }.count == 1)
        #expect(health.filter { $0.kind == .gap }.count == 1)
        #expect(health.filter { $0.kind == .vadGap }.count == 1)
        #expect(health.filter { $0.kind == .deviceChange }.count == 1)
        #expect((await fixture.capture.restarts).filter { $0 == .deviceChange }.count == 1)
        await fixture.pipeline.shutdown()
    }

    @Test func delayedVADLaneDropsAreReportedWhileWriterKeepsRecording() async throws {
        let model = DeterministicVADModel(delay: .milliseconds(300))
        let fixture = try makePipelineFixture(vadLaneCapacity: 1, model: model)
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let epoch = UUID()
        for index in 0 ..< 6 {
            let reading = fixture.clock.now()
            fixture.clock.advance(seconds: 0.256)
            await fixture.capture.emit(pipelineBlock(
                count: 4_096,
                start: Int64(index * 4_096),
                sequence: UInt64(index),
                reading: reading,
                captureEpoch: epoch
            ))
        }

        #expect(await waitUntil {
            (await fixture.store.allHealth()).contains { $0.kind == .vadGap && $0.detail.message.contains("lane full") }
        })
        let chunks = await fixture.store.allChunks()
        #expect(chunks.contains { $0.state == .recording })
        if case .recording = await fixture.snapshots.latest()?.capture {} else {
            Issue.record("slow VAD must not stop or back-pressure recording")
        }
        await fixture.pipeline.shutdown()
    }

    @Test func failingVADReportsErrorWhileWriterAndTruthfulSnapshotStayRecording() async throws {
        let model = DeterministicVADModel()
        await model.setFailure(true)
        let fixture = try makePipelineFixture(model: model)
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let reading = fixture.clock.now()
        fixture.clock.advance(seconds: 0.256)
        await fixture.capture.emit(pipelineBlock(
            count: 4_096,
            start: 0,
            sequence: 0,
            reading: reading,
            captureEpoch: UUID()
        ))

        #expect(await waitUntil {
            (await fixture.store.allHealth()).contains { $0.kind == .vadError && $0.detail.message.contains("processing") }
        })
        #expect((await fixture.store.allChunks()).contains { $0.state == .recording })
        let latest = await fixture.snapshots.latest()
        if case .recording = latest?.capture {} else {
            Issue.record("VAD failure must not change observed recording reality")
        }
        guard case .failed = latest?.vad else {
            Issue.record("snapshot must surface failed VAD status")
            await fixture.pipeline.shutdown()
            return
        }
        await fixture.pipeline.shutdown()
    }

    @Test func VADBoundaryAfterRotationMapsToChunkContainingSourceWindowEnd() async throws {
        let model = DeterministicVADModel(
            probabilities: [0.9, 0.8, 0.7, 0.6],
            boundaries: [.speechStart, nil, nil, nil]
        )
        let fixture = try makePipelineFixture(rotationSamples: 3_200, model: model)
        defer { fixture.snapshotTask.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.pipeline.start()
        let epoch = UUID()
        for index in 0 ..< 4 {
            let reading = fixture.clock.now()
            fixture.clock.advance(seconds: 0.256)
            await fixture.capture.emit(pipelineBlock(
                count: 4_096,
                start: Int64(index * 4_096),
                sequence: UInt64(index),
                reading: reading,
                captureEpoch: epoch
            ))
        }
        #expect(await waitUntil {
            (await fixture.store.allVADEvents()).filter { $0.kind == .score }.count >= 4
        })

        let chunks = await fixture.store.allChunks()
        let boundary = try #require((await fixture.store.allVADEvents()).first { $0.kind == .speechStart })
        let firstChunk = try #require(chunks.first)
        let secondChunk = try #require(chunks.dropFirst().first)
        #expect(firstChunk.startedMono == 0)
        #expect(firstChunk.durationSeconds == 0.2)
        #expect(secondChunk.startedMono == 0.2)
        #expect(boundary.monotonicSeconds == 0.256)
        #expect(boundary.chunkID == secondChunk.id)
        await fixture.pipeline.shutdown()
    }
}
