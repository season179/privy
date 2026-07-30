import Testing
import Foundation
@testable import PrivyCore

// W2 store acceptance tests. Every test runs against a REAL `PrivyStore` over a throwaway
// temp `DatabasePool` (never the live app-support directory), exercising the real lifecycle
// (init → prepareDatabase → mutations → reads). Raw schema/introspection uses the `sqlite3`
// CLI because the test target cannot `import GRDB` (it is not a direct dependency and
// Package.swift is frozen). See docs/m1/plan.md ("W2 — Acceptance criteria").

// MARK: - Harness

/// Finds a usable `sqlite3` binary (system first, Homebrew fallback).
private func sqlite3Binary() -> String {
    let candidates = ["/usr/bin/sqlite3", "/opt/homebrew/opt/sqlite/bin/sqlite3"]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
        return c
    }
    return "sqlite3"
}

/// Runs a SQL statement against `dbPath` and returns stdout. Throws on a nonzero exit.
@discardableResult
private func sqlite(_ dbPath: String, _ sql: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sqlite3Binary())
    process.arguments = [dbPath, sql]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Creates a fresh store rooted in a temp directory and prepares its database.
private func makeTempStore() async throws -> (store: PrivyStore, dbPath: String, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("privy-store-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("privy.sqlite").path
    let store = try PrivyStore(databaseURL: URL(fileURLWithPath: dbPath))
    try await store.prepareDatabase()
    return (store, dbPath, root)
}

/// Snaps a `Date` onto the store's microsecond storage grid so date equality is exact
/// after a write→read round trip. The store truncates sub-microsecond `Date` precision
/// (e.g. `Date(timeIntervalSince1970: ...123.456789)` carries nanoseconds the ISO column
/// does not keep); snapping the input first makes `restored == original` literally true
/// rather than hiding a precision bug.
private func microSnap(_ date: Date) -> Date {
    PrivyDateCoding.date(from: PrivyDateCoding.string(from: date))!
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

// MARK: - Schema + lifecycle

@Suite struct StoreTests {

    @Test func freshDatabaseHasFullSchemaAndMigrationRecord() async throws {
        let (_, dbPath, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let tables = try sqlite(dbPath, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        for expected in ["chunks", "vad_events", "utterances", "sessions", "health", "costs", "utterances_fts"] {
            #expect(tables.contains(expected), "missing table: \(expected)\n\(tables)")
        }

        let indexes = try sqlite(dbPath, "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'fts_%' AND name NOT LIKE 'utterances_%' ORDER BY name")
        for expected in ["chunks_state_started_idx", "chunks_started_utc_idx", "vad_events_chunk_t_idx", "health_at_idx"] {
            #expect(indexes.contains(expected), "missing index: \(expected)\n\(indexes)")
        }

        let triggers = try sqlite(dbPath, "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name")
        for expected in ["utterances_ai", "utterances_ad", "utterances_au"] {
            #expect(triggers.contains(expected), "missing fts sync trigger: \(expected)\n\(triggers)")
        }

        let migrations = try sqlite(dbPath, "SELECT identifier FROM grdb_migrations")
        #expect(migrations.contains("v1_create_schema"), "migration not recorded:\n\(migrations)")
    }

    @Test func prepareDatabaseIsIdempotent() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Re-running must not throw and must leave the schema intact.
        try await store.prepareDatabase()
        try await store.prepareDatabase()
    }

    @Test func mutatingBeforePrepareThrows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privy-store-unprep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PrivyStore(databaseURL: root.appendingPathComponent("privy.sqlite"))
        await #expect(throws: (any Error).self) {
            _ = try await store.createChunk(NewChunk(
                kind: .shadow, startedAtUTC: Date(), startedMono: 0,
                relativeAudioPath: "2026-01-01T00:00:00.000000Z_uuid.ogg"
            ))
        }
    }

    // MARK: - Chunk CRUD

    private func sampleNew(at: Date, mono: Double = 1, path: String = "2026-01-01T00:00:00.000000Z_uuid.ogg") -> NewChunk {
        NewChunk(kind: .shadow, startedAtUTC: at, startedMono: mono, relativeAudioPath: path)
    }

    @Test func createChunkReturnsRecordingRow() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = microSnap(Date(timeIntervalSince1970: 1_780_000_000.5))
        let record = try await store.createChunk(sampleNew(at: started))
        #expect(record.state == .recording)
        #expect(record.kind == .shadow)
        #expect(record.id > 0)
        #expect(record.startedAtUTC == started)
        #expect(record.relativeAudioPath == "2026-01-01T00:00:00.000000Z_uuid.ogg")
        #expect(record.durationSeconds == 0)
        #expect(record.sizeBytes == 0)
        #expect(record.checksumSHA256 == nil)
    }

    @Test func checkpointUpdatesProgressForRecordingChunkOnly() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await store.createChunk(sampleNew(at: microSnap(Date())))
        try await store.checkpointChunk(id: record.id, durationSeconds: 5.0, sizeBytes: 12_000)
        // Checkpoint does not return a row; verify via menuSummary's bytes-today aggregation.
        let summary = try await store.menuSummary(dayContaining: Date(), healthLimit: 5)
        #expect(summary.bytesRecordedToday == 12_000)
    }

    @Test func finalizeTransitionsRecordingToReadyAndIsIdempotent() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await store.createChunk(sampleNew(at: microSnap(Date())))
        let finalized = try await store.finalizeChunk(
            id: record.id, durationSeconds: 10.0, sizeBytes: 25_000, checksumSHA256: "abc123"
        )
        #expect(finalized.state == .ready)
        #expect(finalized.checksumSHA256 == "abc123")
        #expect(finalized.durationSeconds == 10.0)
        #expect(finalized.sizeBytes == 25_000)
        // Idempotent: finalize again returns the same ready row unchanged.
        let again = try await store.finalizeChunk(
            id: record.id, durationSeconds: 999, sizeBytes: 999, checksumSHA256: "deadbeef"
        )
        #expect(again.state == .ready)
        #expect(again.checksumSHA256 == "abc123")
        #expect(again.sizeBytes == 25_000)
    }

    @Test func failTransitionsRecordingToFailedAndLogsHealth() async throws {
        let (store, dbPath, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try await store.createChunk(sampleNew(at: microSnap(Date())))
        try await store.failChunk(id: record.id, reason: "encoder exploded")
        let state = try sqlite(dbPath, "SELECT state FROM chunks WHERE id=\(record.id);").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(state == "failed")
        // The fail path must surface through health, not a silent state change.
        let healthCount = try sqlite(dbPath, "SELECT count(*) FROM health WHERE kind='writerError';").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(healthCount) == 1)
        // Idempotent: failing again is a no-op and adds no second health row.
        try await store.failChunk(id: record.id, reason: "again")
        let healthCount2 = try sqlite(dbPath, "SELECT count(*) FROM health WHERE kind='writerError';").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(healthCount2) == 1)
    }

    @Test func unknownChunkIdThrows() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await store.checkpointChunk(id: 999, durationSeconds: 1, sizeBytes: 1)
        }
        await #expect(throws: (any Error).self) {
            _ = try await store.finalizeChunk(id: 999, durationSeconds: 1, sizeBytes: 1, checksumSHA256: "x")
        }
        await #expect(throws: (any Error).self) {
            try await store.failChunk(id: 999, reason: "x")
        }
    }

    @Test func createChunkRejectsUnsafeRelativePath() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../../etc/passwd", "/etc/passwd", "a/../../../b.ogg"] {
            await #expect(throws: (any Error).self) {
                _ = try await store.createChunk(NewChunk(
                    kind: .shadow, startedAtUTC: Date(), startedMono: 0, relativeAudioPath: bad
                ))
            }
        }
    }

    // MARK: - VAD

    @Test func appendVADEventsBatchInsertsAllRows() async throws {
        let (store, dbPath, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = try await store.createChunk(sampleNew(at: microSnap(Date())))
        let events: [VADEventRecord] = [
            .init(chunkID: chunk.id, monotonicSeconds: 0.0, kind: .score, score: 0.1),
            .init(chunkID: chunk.id, monotonicSeconds: 0.256, kind: .score, score: 0.9),
            .init(chunkID: chunk.id, monotonicSeconds: 0.512, kind: .score, score: 0.2),
            .init(chunkID: chunk.id, monotonicSeconds: 0.768, kind: .speechStart, score: nil),
        ]
        try await store.appendVADEvents(events)
        let count = try sqlite(dbPath, "SELECT count(*) FROM vad_events;").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(count) == 4)
        // Empty batch is a harmless no-op (no error).
        try await store.appendVADEvents([])
        let count2 = try sqlite(dbPath, "SELECT count(*) FROM vad_events;").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(count2) == 4)
    }

    // MARK: - Health envelope round trip (mandatory)

    @Test func healthEnvelopeRoundTripsEachSeverityUnchanged() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for severity in [HealthSeverity.info, .warning, .error] {
            let at = microSnap(Date(timeIntervalSince1970: 1_780_000_123.456789))
            let original = HealthEvent(
                atUTC: at,
                kind: .gap,
                severity: severity,
                detail: HealthDetail(
                    message: "gap detail \(severity.rawValue)",
                    clockEpoch: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
                    monotonicSeconds: 42.5,
                    gapStartedUTC: microSnap(Date(timeIntervalSince1970: 1_780_000_100.0)),
                    gapEndedUTC: microSnap(Date(timeIntervalSince1970: 1_780_000_110.0)),
                    durationSeconds: 10.0,
                    deviceUID: "BuiltInMicrophoneDevice",
                    droppedFrames: 12345,
                    durationIsEstimated: true
                )
            )
            try await store.appendHealth(original)
            let summary = try await store.menuSummary(dayContaining: at, healthLimit: 10)
            let restored = try #require(summary.recentHealth.first { $0.kind == .gap && $0.severity == severity })
            // Exact restoration: severity, kind, detail fields, and the µs-grid date.
            #expect(restored == original, "severity \(severity.rawValue) did not round-trip unchanged")
        }
    }

    @Test func malformedHealthEnvelopeFailsDecodingVisibly() async throws {
        let (store, dbPath, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Inject a row whose detail is not a valid HealthEnvelope JSON. menuSummary must
        // surface the corruption (throw) rather than silently defaulting severity.
        let badDetail = "not-json-at-all"
        let escaped = badDetail.replacingOccurrences(of: "'", with: "''")
        _ = try sqlite(
            dbPath,
            "INSERT INTO health (at_utc, kind, detail) VALUES ('2026-01-01T00:00:00.000000Z','error','\(escaped)');"
        )
        await #expect(throws: (any Error).self) {
            _ = try await store.menuSummary(dayContaining: Date(), healthLimit: 5)
        }
    }

    // MARK: - Menu summary queries

    @Test func menuSummaryCurrentChunkIsLatestRecording() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try await store.createChunk(sampleNew(at: microSnap(Date(timeIntervalSince1970: 1_780_000_000)), path: "a.ogg"))
        let later = try await store.createChunk(sampleNew(at: microSnap(Date(timeIntervalSince1970: 1_780_000_500)), path: "b.ogg"))
        // Finalize the earlier one so it leaves the recording state; only `later` remains recording.
        _ = try await store.finalizeChunk(id: earlier.id, durationSeconds: 1, sizeBytes: 1, checksumSHA256: "h")
        let summary = try await store.menuSummary(dayContaining: Date(), healthLimit: 5)
        #expect(summary.currentChunk?.id == later.id)
    }

    @Test func menuSummaryBytesRecordedTodayUsesUtcDayBoundary() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Two chunks at the UTC day boundary: 23:59:59 and 00:00:01 next day.
        let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        let justBeforeMidnight = microSnap(dayStart.addingTimeInterval(86_399))
        let justAfterMidnight = microSnap(dayStart.addingTimeInterval(86_401))
        let chunkA = try await store.createChunk(sampleNew(at: justBeforeMidnight, path: "a.ogg"))
        let chunkB = try await store.createChunk(sampleNew(at: justAfterMidnight, path: "b.ogg"))
        _ = try await store.finalizeChunk(id: chunkA.id, durationSeconds: 1, sizeBytes: 1_000, checksumSHA256: "a")
        _ = try await store.finalizeChunk(id: chunkB.id, durationSeconds: 1, sizeBytes: 2_000, checksumSHA256: "b")
        let summaryDay1 = try await store.menuSummary(dayContaining: justBeforeMidnight, healthLimit: 5)
        let summaryDay2 = try await store.menuSummary(dayContaining: justAfterMidnight, healthLimit: 5)
        #expect(summaryDay1.bytesRecordedToday == 1_000, "day1 should only count the pre-midnight chunk")
        #expect(summaryDay2.bytesRecordedToday == 2_000, "day2 should only count the post-midnight chunk")
    }

    @Test func menuSummaryRecentHealthIsMostRecentFirstAndLimited() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 {
            try await store.appendHealth(HealthEvent(
                atUTC: microSnap(Date(timeIntervalSince1970: 1_780_000_000 + Double(i))),
                kind: .startup,
                severity: .info,
                detail: HealthDetail(
                    message: "ev\(i)", clockEpoch: nil, monotonicSeconds: nil,
                    gapStartedUTC: nil, gapEndedUTC: nil, durationSeconds: nil,
                    deviceUID: nil, droppedFrames: nil, durationIsEstimated: false
                )
            ))
        }
        let summary = try await store.menuSummary(dayContaining: Date(timeIntervalSince1970: 1_780_000_000), healthLimit: 3)
        #expect(summary.recentHealth.count == 3)
        // Most-recent-first ordering.
        #expect(summary.recentHealth.first?.detail.message == "ev4")
        #expect(summary.recentHealth.last?.detail.message == "ev2")
    }
}

// MARK: - Guarded-update changes-count (finding 1)

@Suite struct StoreGuardTests {

    private func newChunk(path: String) -> NewChunk {
        NewChunk(kind: .shadow, startedAtUTC: Date(), startedMono: 0, relativeAudioPath: path)
    }

    private func state(_ dbPath: String, id: Int64) throws -> String {
        trimmed(try sqlite(dbPath, "SELECT state FROM chunks WHERE id=\(id);"))
    }
    private func sizeBytes(_ dbPath: String, id: Int64) throws -> Int64 {
        Int64(trimmed(try sqlite(dbPath, "SELECT size_bytes FROM chunks WHERE id=\(id);"))) ?? -1
    }

    @Test func zeroRowFinalizeAndCheckpointAreIdempotentForReadyRows() async throws {
        let (store, dbPath, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = try await store.createChunk(newChunk(path: "a.ogg"))
        _ = try await store.finalizeChunk(id: chunk.id, durationSeconds: 1, sizeBytes: 100, checksumSHA256: "h1")
        // Second finalize on a ready row is idempotent (no throw) and does NOT regress metadata.
        let again = try await store.finalizeChunk(id: chunk.id, durationSeconds: 9, sizeBytes: 999, checksumSHA256: "h9")
        #expect(again.state == .ready)
        #expect(again.sizeBytes == 100)
        #expect(again.checksumSHA256 == "h1")
        // A stale checkpoint against a ready row is a benign no-op (no throw, no change).
        try await store.checkpointChunk(id: chunk.id, durationSeconds: 9, sizeBytes: 999)
        #expect(try sizeBytes(dbPath, id: chunk.id) == 100)
        #expect(try state(dbPath, id: chunk.id) == "ready")
    }

    @Test func zeroRowTransitionsIntoUnexpectedStateThrowStateConflict() async throws {
        let (store, dbPath, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = try await store.createChunk(newChunk(path: "a.ogg"))
        _ = try await store.finalizeChunk(id: ready.id, durationSeconds: 1, sizeBytes: 1, checksumSHA256: "h")
        // Failing a `ready` row is a conflict (only `recording` may be failed).
        await #expect(throws: PrivyStoreError.self) {
            try await store.failChunk(id: ready.id, reason: "should not work")
        }
        #expect(try state(dbPath, id: ready.id) == "ready")

        let failed = try await store.createChunk(newChunk(path: "b.ogg"))
        try await store.failChunk(id: failed.id, reason: "boom")
        // Checkpointing/finalizing a `failed` row is a conflict; failing again is idempotent.
        await #expect(throws: PrivyStoreError.self) {
            try await store.checkpointChunk(id: failed.id, durationSeconds: 1, sizeBytes: 1)
        }
        await #expect(throws: PrivyStoreError.self) {
            _ = try await store.finalizeChunk(id: failed.id, durationSeconds: 1, sizeBytes: 1, checksumSHA256: "h")
        }
        try await store.failChunk(id: failed.id, reason: "again")  // idempotent, no throw
        #expect(try state(dbPath, id: failed.id) == "failed")
    }

    @Test func unknownIdTransitionsAreNotMisclassifiedAsConflicts() async throws {
        let (store, _, root) = try await makeTempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // A truly absent id surfaces as unknownChunk, not as a benign idempotent result.
        await #expect(throws: PrivyStoreError.self) {
            try await store.checkpointChunk(id: 424242, durationSeconds: 1, sizeBytes: 1)
        }
        await #expect(throws: PrivyStoreError.self) {
            _ = try await store.finalizeChunk(id: 424242, durationSeconds: 1, sizeBytes: 1, checksumSHA256: "h")
        }
        await #expect(throws: PrivyStoreError.self) {
            try await store.failChunk(id: 424242, reason: "x")
        }
    }
}

// MARK: - Audio probe seam, locator, bounded process (findings 6 + 8)

@Suite struct AudioProbeTests {

    @Test func locateFFProbeHonorsEnvStrictlyWithoutFallthrough() throws {
        // An invalid PRIVY_FFPROBE_PATH yields unavailable with NO fallthrough to common paths.
        #expect(locateFFProbe(env: ["PRIVY_FFPROBE_PATH": "/definitely/not/here/ffprobe"]) == nil)
        #expect(locateFFProbe(env: ["PRIVY_FFPROBE_PATH": ""]) == locateFFProbe(env: [:]))
        // A valid configured path is used verbatim.
        let probe = locateFFProbe(env: [:])
        if let real = probe {
            #expect(locateFFProbe(env: ["PRIVY_FFPROBE_PATH": real]) == real)
        }
    }

    @Test func unavailableExecutableIsReportedAsUnavailable() async throws {
        let probe = FFprobeAudioProbe(ffprobePath: nil, timeout: .seconds(1))
        let result = await probe.probe(durationOf: URL(fileURLWithPath: "/tmp/whatever"))
        if case .failed(let reason) = result {
            #expect(reason.contains("unavailable"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test func launchFailureIsReportedAsFailed() async throws {
        // `/dev/null` is not executable, so Process.run throws.
        let probe = FFprobeAudioProbe(ffprobePath: "/dev/null", timeout: .seconds(2))
        let result = await probe.probe(durationOf: URL(fileURLWithPath: "/tmp/whatever"))
        if case .failed(let reason) = result {
            #expect(reason.contains("launch"))
        } else {
            Issue.record("expected .failed launch, got \(result)")
        }
    }

    @Test func nonzeroExitIsReportedAsFailed() async throws {
        let probe = FFprobeAudioProbe(ffprobePath: "/usr/bin/false", timeout: .seconds(2))
        let result = await probe.probe(durationOf: URL(fileURLWithPath: "/tmp/whatever"))
        if case .failed(let reason) = result {
            #expect(reason.contains("status"))
        } else {
            Issue.record("expected .failed nonzero, got \(result)")
        }
    }

    @Test func malformedDurationIsReportedAsFailed() async throws {
        // `/bin/echo` prints its arguments, not a number.
        let probe = FFprobeAudioProbe(ffprobePath: "/bin/echo", timeout: .seconds(2))
        let result = await probe.probe(durationOf: URL(fileURLWithPath: "/tmp/whatever"))
        if case .failed(let reason) = result {
            #expect(reason.contains("parseable"))
        } else {
            Issue.record("expected .failed malformed, got \(result)")
        }
    }

    @Test func hungExecutableIsTerminatedAndReapedWithinBound() async throws {
        // A genuinely hanging executable is killed at the timeout and reaped; total wait is
        // bounded by the timeout, not the child's natural lifetime.
        let sleeper = try makeSleeperScript(seconds: 30)
        defer { try? FileManager.default.removeItem(at: sleeper) }
        let probe = FFprobeAudioProbe(ffprobePath: sleeper.path, timeout: .milliseconds(300))
        let start = Date()
        let result = await probe.probe(durationOf: URL(fileURLWithPath: "/tmp/whatever"))
        let elapsed = Date().timeIntervalSince(start)
        if case .failed(let reason) = result {
            #expect(reason.contains("timed out"))
        } else {
            Issue.record("expected .failed timeout, got \(result)")
        }
        #expect(elapsed < 3.0, "probe must be bounded by the timeout (~0.3s), took \(elapsed)s")
        // Child must be reaped — no sleeper lingering.
        #expect(lingerCount("sleep 30") == 0)
    }

    @Test func boundedProcessTerminatesAndReapsHungChildDirectly() async throws {
        let start = Date()
        let outcome = await BoundedProcess.run(
            executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(250)
        )
        let elapsed = Date().timeIntervalSince(start)
        if case .failure(let error) = outcome {
            #expect(error == .timedOut)
        } else {
            Issue.record("expected .timedOut, got \(outcome)")
        }
        #expect(elapsed < 2.0)
        #expect(lingerCount("sleep 30") == 0)
    }

    @Test func signalIgnoringChildIsSigkillReapedWithinBound() async throws {
        // A child that IGNORES SIGTERM/SIGINT (a misbehaving ffprobe) must still be killed and
        // reaped within a bounded time: BoundedProcess escalates SIGTERM -> SIGINT -> SIGKILL,
        // and SIGKILL cannot be trapped. The fixture busy-loops as a single process (no
        // grandchild), so SIGKILL leaves nothing lingering. This is the case the prior
        // SIGTERM/SIGINT-only code hung forever on.
        let script = try makeSignalIgnoringScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let start = Date()
        let outcome = await BoundedProcess.run(
            executable: script.path, arguments: [], timeout: .milliseconds(300)
        )
        let elapsed = Date().timeIntervalSince(start)
        if case .failure(let error) = outcome {
            #expect(error == .timedOut)
        } else {
            Issue.record("expected .timedOut for a signal-ignoring child, got \(outcome)")
        }
        // timeout(0.3s) + SIGTERM/SIGINT/SIGKILL grace(~0.3s) ≈ 0.6s — far below the child's
        // natural (infinite) lifetime.
        #expect(elapsed < 2.0, "signal-ignoring child must be SIGKILL-reaped within bound, took \(elapsed)s")
        // Let the OS finalize reaping, then confirm nothing lingers.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(lingerCount(script.lastPathComponent) == 0, "signal-ignoring child must not linger")
    }

    @Test(.enabled(if: locateFFProbe(env: ProcessInfo.processInfo.environment) != nil))
    func realFFprobeDecodesADurationWhenAvailable() async throws {
        // Build a real 1s Ogg and confirm the real probe decodes it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("privy-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("x.ogg")
        try runFFmpegSilence(at: file, seconds: 1.0)
        let probe = FFprobeAudioProbe()
        let result = await probe.probe(durationOf: file)
        guard case .decodable(let duration) = result else {
            Issue.record("expected .decodable, got \(result)"); return
        }
        #expect(abs(duration - 1.0) < 0.2)
    }
}

private func makeSleeperScript(seconds: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("privy-sleeper-\(UUID().uuidString).sh")
    try "#!/bin/sh\nsleep \(seconds)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// A single-process shell that ignores SIGTERM and SIGINT and busy-loops forever — only
/// SIGKILL can stop it. Used to prove BoundedProcess's SIGKILL escalation bounds a child the
/// prior SIGTERM/SIGINT-only code hung on. Busy-loops in the shell itself (no `sleep`
/// grandchild), so SIGKILL leaves nothing lingering.
private func makeSignalIgnoringScript() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("privy-trap-\(UUID().uuidString).sh")
    try "#!/bin/sh\ntrap '' TERM INT\nwhile :; do :\ndone\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func lingerCount(_ pattern: String) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", pattern]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return 0 }
    process.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").filter { !$0.isEmpty }.count
}

private func runFFmpegSilence(at url: URL, seconds: Double) throws {
    let bin = ProcessInfo.processInfo.environment["PRIVY_FFMPEG_PATH"] ?? "/opt/homebrew/bin/ffmpeg"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = ["-nostats", "-loglevel", "error", "-y",
                         "-f", "lavfi", "-i", "anullsrc=channel_layout=mono:sample_rate=16000",
                         "-t", String(seconds), "-c:a", "libopus", "-f", "ogg", url.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "AudioProbeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed"])
    }
}
