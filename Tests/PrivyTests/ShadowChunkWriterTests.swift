import Foundation
import OpusIO
import Testing
@testable import PrivyCore

actor RecordingFakeStore: PrivyStoring {
    enum FailurePoint: Sendable { case none, create, checkpoint, finalize, fail, health, vad }

    private var nextID: Int64 = 1
    private(set) var chunks: [Int64: ChunkRecord] = [:]
    private(set) var health: [HealthEvent] = []
    private(set) var vadEvents: [VADEventRecord] = []
    private(set) var operations: [String] = []
    var failure: FailurePoint = .none
    var persistentFailure = false

    func setFailure(_ point: FailurePoint, persistent: Bool = false) {
        failure = point
        persistentFailure = persistent
    }

    private func shouldFail(_ point: FailurePoint) -> Bool {
        guard failure == point else { return false }
        if !persistentFailure { failure = .none }
        return true
    }

    func prepareDatabase() async throws {}

    func createChunk(_ chunk: NewChunk) async throws -> ChunkRecord {
        if shouldFail(.create) { throw FakeStoreError.injected("create") }
        let record = ChunkRecord(
            id: nextID,
            kind: chunk.kind,
            startedAtUTC: chunk.startedAtUTC,
            startedMono: chunk.startedMono,
            durationSeconds: 0,
            relativeAudioPath: chunk.relativeAudioPath,
            sizeBytes: 0,
            checksumSHA256: nil,
            state: .recording
        )
        nextID += 1
        chunks[record.id] = record
        operations.append("create:\(record.id)")
        return record
    }

    func checkpointChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64) async throws {
        if shouldFail(.checkpoint) { throw FakeStoreError.injected("checkpoint") }
        guard let record = chunks[id] else { throw FakeStoreError.missing }
        chunks[id] = replace(record, duration: durationSeconds, size: sizeBytes, checksum: nil, state: .recording)
        operations.append("checkpoint:\(id)")
    }

    func finalizeChunk(
        id: Int64,
        durationSeconds: Double,
        sizeBytes: Int64,
        checksumSHA256: String
    ) async throws -> ChunkRecord {
        if shouldFail(.finalize) { throw FakeStoreError.injected("finalize") }
        guard let record = chunks[id] else { throw FakeStoreError.missing }
        let ready = replace(
            record,
            duration: durationSeconds,
            size: sizeBytes,
            checksum: checksumSHA256,
            state: .ready
        )
        chunks[id] = ready
        operations.append("finalize:\(id)")
        return ready
    }

    func failChunk(id: Int64, reason: String) async throws {
        if shouldFail(.fail) { throw FakeStoreError.injected("fail") }
        guard let record = chunks[id] else { throw FakeStoreError.missing }
        chunks[id] = replace(
            record,
            duration: record.durationSeconds,
            size: record.sizeBytes,
            checksum: record.checksumSHA256,
            state: .failed
        )
        operations.append("fail:\(id)")
    }

    func appendVADEvents(_ events: [VADEventRecord]) async throws {
        if shouldFail(.vad) { throw FakeStoreError.injected("vad") }
        vadEvents.append(contentsOf: events)
    }

    func appendHealth(_ event: HealthEvent) async throws {
        if shouldFail(.health) { throw FakeStoreError.injected("health") }
        health.append(event)
    }

    func menuSummary(dayContaining: Date, healthLimit: Int) async throws -> MenuSummary {
        MenuSummary(
            currentChunk: chunks.values.first(where: { $0.state == .recording }),
            bytesRecordedToday: chunks.values.reduce(0) { $0 + ($1.state == .ready ? $1.sizeBytes : 0) },
            recentHealth: Array(health.suffix(healthLimit))
        )
    }

    func reconcile(storage: StorageLayout, at: ClockReading) async throws -> ReconciliationReport {
        ReconciliationReport(actions: [], readyCount: 0, failedCount: 0, preservedFileCount: 0)
    }

    func allChunks() -> [ChunkRecord] { chunks.values.sorted { $0.id < $1.id } }
    func allHealth() -> [HealthEvent] { health }
    func allVADEvents() -> [VADEventRecord] { vadEvents }
    func operationLog() -> [String] { operations }

    private func replace(
        _ record: ChunkRecord,
        duration: Double,
        size: Int64,
        checksum: String?,
        state: ChunkState
    ) -> ChunkRecord {
        ChunkRecord(
            id: record.id,
            kind: record.kind,
            startedAtUTC: record.startedAtUTC,
            startedMono: record.startedMono,
            durationSeconds: duration,
            relativeAudioPath: record.relativeAudioPath,
            sizeBytes: size,
            checksumSHA256: checksum,
            state: state
        )
    }
}

enum FakeStoreError: Error {
    case injected(String)
    case missing
}

private final class ThrowingOggWriter: OggOpusWriting {
    let sampleRate: Int32 = 16_000
    func append(_ samples: [Float]) throws { throw FakeStoreError.injected("ogg append") }
    func finish() throws {}
    func durablyCloseWithoutEndOfStream() throws {}
    func synchronize() throws {}
}

private func writerFixture(rotationSamples: Int = ShadowChunkWriter.rotationSamples) throws -> (
    writer: ShadowChunkWriter,
    store: RecordingFakeStore,
    layout: StorageLayout,
    root: URL
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("privy-writer-tests-\(UUID())", isDirectory: true)
    let audio = root.appendingPathComponent("Audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    let layout = StorageLayout(
        rootDirectory: root,
        databaseURL: root.appendingPathComponent("test.sqlite"),
        audioDirectory: audio
    )
    let store = RecordingFakeStore()
    return (
        ShadowChunkWriter(store: store, storage: layout, rotationSamples: rotationSamples),
        store,
        layout,
        root
    )
}

private func audioBlock(
    samples: Int,
    start: Int64 = 0,
    sequence: UInt64 = 0,
    at: ClockReading = ClockReading(
        wallUTC: Date(timeIntervalSince1970: 1_700_000_000),
        monotonicSeconds: 100,
        clockEpoch: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
) -> AudioBlock16k {
    AudioBlock16k(
        captureEpoch: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        sequence: sequence,
        streamSampleStart: start,
        firstSampleTime: at,
        samples: (0 ..< samples).map { index in
            0.1 * sin(Float(index) * 2 * .pi * 440 / Float(privySampleRate))
        }
    )
}

@Suite struct ShadowChunkWriterTests {
    @Test(arguments: [
        StopReason.manualPause,
        .systemSleep,
        .deviceChange,
        .restart,
        .shutdown,
    ])
    func normalCloseReasonsMovePartialThenFinalize(reason: StopReason) async throws {
        let fixture = try writerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let transitions = try await fixture.writer.append(audioBlock(samples: 1_600))
        guard case .opened(let opened) = transitions.first else {
            Issue.record("expected opened transition")
            return
        }
        let final = fixture.layout.audioDirectory.appendingPathComponent(opened.relativeAudioPath)
        let partial = final.appendingPathExtension("partial")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: final.path))

        let closed = try await fixture.writer.close(reason: reason, at: audioBlock(samples: 1).firstSampleTime)
        #expect(closed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: final.path))
        let records = await fixture.store.allChunks()
        #expect(records.count == 1)
        #expect(records[0].state == .ready)
        #expect(records[0].durationSeconds == 0.1)
        #expect(records[0].sizeBytes > 0)
        #expect(records[0].checksumSHA256?.count == 64)

        let secondClose = try await fixture.writer.close(reason: reason, at: audioBlock(samples: 1).firstSampleTime)
        #expect(secondClose.isEmpty)
    }

    @Test func hourlyCrossingSplitsExactlyAndEOSLessChunkDecodes() async throws {
        #expect(ShadowChunkWriter.rotationSamples == 57_600_000)
        let fixture = try writerFixture(rotationSamples: 640)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let transitions = try await fixture.writer.append(audioBlock(samples: 1_000))
        _ = try await fixture.writer.close(reason: .shutdown, at: audioBlock(samples: 1).firstSampleTime)
        let records = await fixture.store.allChunks()
        #expect(records.count == 2)
        #expect(records.map(\.state) == [.ready, .ready])
        let persistedSamples = records.reduce(0) {
            $0 + Int(($1.durationSeconds * Double(privySampleRate)).rounded())
        }
        #expect(persistedSamples == 1_000)
        #expect(records[0].durationSeconds == Double(640) / Double(privySampleRate))
        #expect(records[1].durationSeconds == Double(360) / Double(privySampleRate))
        #expect(transitions.contains { if case .finalized = $0 { true } else { false } })

        guard executable("ffprobe") != nil, executable("ffmpeg") != nil else {
            print("SKIP: ffprobe/ffmpeg unavailable; hourly decodability check not run")
            return
        }
        for record in records {
            let url = fixture.layout.audioDirectory.appendingPathComponent(record.relativeAudioPath)
            #expect(try decodesWithFFmpeg(url))
            let measured = try ffprobeDuration(url)
            let duration = try #require(measured)
            #expect(abs(duration - record.durationSeconds) <= 0.020_001)
        }
    }

    @Test func fatalCloseTerminallyRecoversBeforeAnotherChunkOpens() async throws {
        let fixture = try writerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.writer.append(audioBlock(samples: 400))
        _ = try await fixture.writer.close(reason: .fatalError, at: audioBlock(samples: 1).firstSampleTime)
        let afterRecovery = await fixture.store.allChunks()
        #expect(afterRecovery.count == 1)
        #expect(afterRecovery[0].state == (executable("ffprobe") == nil ? .failed : .ready))

        _ = try await fixture.writer.append(audioBlock(samples: 320, start: 400, sequence: 1))
        let operations = await fixture.store.operationLog()
        let terminalIndex = try #require(operations.firstIndex { $0 == "finalize:1" || $0 == "fail:1" })
        let replacementIndex = try #require(operations.firstIndex(of: "create:2"))
        #expect(terminalIndex < replacementIndex)
    }

    @Test func failedOggWriteIsTerminallyFailedAndNeverSilentlyDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privy-write-failure-\(UUID())")
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingFakeStore()
        let writer = ShadowChunkWriter(
            store: store,
            storage: StorageLayout(
                rootDirectory: root,
                databaseURL: root.appendingPathComponent("test.sqlite"),
                audioDirectory: audio
            ),
            makeWriter: { _ in ThrowingOggWriter() }
        )

        await #expect(throws: (any Error).self) {
            try await writer.append(audioBlock(samples: 320))
        }
        let records = await store.allChunks()
        #expect(records.count == 1)
        #expect(records[0].state == .failed)
        #expect(await writer.activeChunk() == nil)
    }

    @Test func writerOpenFailureFailsCreatedRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privy-open-failure-\(UUID())")
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingFakeStore()
        let writer = ShadowChunkWriter(
            store: store,
            storage: StorageLayout(
                rootDirectory: root,
                databaseURL: root.appendingPathComponent("test.sqlite"),
                audioDirectory: audio
            ),
            makeWriter: { _ in throw FakeStoreError.injected("open") }
        )
        await #expect(throws: (any Error).self) {
            try await writer.append(audioBlock(samples: 320))
        }
        #expect(await store.allChunks().first?.state == .failed)
    }

    @Test func checkpointFailureRecoversRowBeforeReplacement() async throws {
        let fixture = try writerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.store.setFailure(.checkpoint)

        await #expect(throws: (any Error).self) {
            try await fixture.writer.append(audioBlock(samples: privySampleRate * 5))
        }
        let recovered = await fixture.store.allChunks()
        #expect(recovered.count == 1)
        #expect(recovered[0].state == (executable("ffprobe") == nil ? .failed : .ready))

        _ = try await fixture.writer.append(audioBlock(samples: 320, start: 80_000, sequence: 1))
        let operations = await fixture.store.operationLog()
        let replacementIndex = try #require(operations.firstIndex(of: "create:2"))
        let terminalIndex = try #require(operations.firstIndex { $0 == "finalize:1" || $0 == "fail:1" })
        #expect(terminalIndex < replacementIndex)
    }

    @Test func finalizeFailureFallsBackToFailedAndRenameFailurePreservesPartial() async throws {
        let finalizeFixture = try writerFixture()
        defer { try? FileManager.default.removeItem(at: finalizeFixture.root) }
        _ = try await finalizeFixture.writer.append(audioBlock(samples: 640))
        await finalizeFixture.store.setFailure(.finalize, persistent: true)
        await #expect(throws: (any Error).self) {
            try await finalizeFixture.writer.close(reason: .shutdown, at: audioBlock(samples: 1).firstSampleTime)
        }
        #expect(await finalizeFixture.store.allChunks().first?.state == .failed)

        let renameFixture = try writerFixture()
        defer { try? FileManager.default.removeItem(at: renameFixture.root) }
        let opened = try await renameFixture.writer.append(audioBlock(samples: 320))
        guard case .opened(let record) = opened.first else { return }
        let final = renameFixture.layout.audioDirectory.appendingPathComponent(record.relativeAudioPath)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await renameFixture.writer.close(reason: .shutdown, at: audioBlock(samples: 1).firstSampleTime)
        }
        #expect(await renameFixture.store.allChunks().first?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: final.appendingPathExtension("partial").path))
    }

    @Test func storeOutageDuringTerminalRecoveryBlocksReplacement() async throws {
        let fixture = try writerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.writer.append(audioBlock(samples: 320))
        await fixture.store.setFailure(.finalize, persistent: true)
        // `failChunk` is a different operation and must also fail to make recovery
        // terminally impossible. Switch failure when finalize has been attempted.
        let final = try #require((await fixture.store.allChunks()).first)
        let finalURL = fixture.layout.audioDirectory.appendingPathComponent(final.relativeAudioPath)
        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: false)
        await fixture.store.setFailure(.fail, persistent: true)
        await #expect(throws: (any Error).self) {
            try await fixture.writer.close(reason: .shutdown, at: audioBlock(samples: 1).firstSampleTime)
        }
        await #expect(throws: (any Error).self) {
            try await fixture.writer.append(audioBlock(samples: 320, start: 320, sequence: 1))
        }
        #expect((await fixture.store.allChunks()).count == 1)
    }

    @Test func deliberatelyUnfinalizedSynchronizedOutputIsDecodable() throws {
        guard executable("ffprobe") != nil, executable("ffmpeg") != nil else {
            print("SKIP: ffprobe/ffmpeg unavailable; crash-truncated decodability check not run")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("privy-unfinalized-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("unfinalized.ogg.partial")
        let opusWriter = try OggOpusWriter(url: url)
        try opusWriter.append(audioBlock(samples: privySampleRate * 2).samples)
        try opusWriter.synchronize()
        _ = Unmanaged.passRetained(opusWriter) // Deliberately model process death: no deinit/EOS.
        #expect(try decodesWithFFmpeg(url))
        let measured = try ffprobeDuration(url)
        #expect(try #require(measured) > 1.9)
    }
}

private func executable(_ name: String) -> URL? {
    let fm = FileManager.default
    let fixed = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
    if let path = fixed.first(where: fm.isExecutableFile(atPath:)) {
        return URL(fileURLWithPath: path)
    }
    return (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
        .first { fm.isExecutableFile(atPath: $0.path) }
}

private func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, text)
}

private func ffprobeDuration(_ url: URL) throws -> Double? {
    guard let probe = executable("ffprobe") else { return nil }
    let result = try run(probe, [
        "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", url.path,
    ])
    guard result.0 == 0 else { return nil }
    return Double(result.1.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func decodesWithFFmpeg(_ url: URL) throws -> Bool {
    guard let ffmpeg = executable("ffmpeg") else { return false }
    return try run(ffmpeg, ["-v", "error", "-i", url.path, "-f", "null", "-"]).0 == 0
}
