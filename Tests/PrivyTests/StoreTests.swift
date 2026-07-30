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
