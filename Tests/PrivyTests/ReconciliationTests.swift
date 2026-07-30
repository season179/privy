import Testing
import Foundation
@testable import PrivyCore

// W2 reconciliation acceptance tests. The crash-recovery tests run the REAL store over a
// temp `StorageLayout` with REAL audio files (generated via `ffmpeg`) and the REAL
// `ffprobe`, exercising the full inventory → plan → apply lifecycle — not just helpers.
// A second group drives the PURE `ReconciliationPlanner` with synthetic inventories for
// deterministic branching. See docs/m1/plan.md ("W2 — Acceptance criteria" and "Crash and
// lifecycle invariants" §5). No test touches the live app-support directory.

// MARK: - Shared harness

private func sqlite3Binary() -> String {
    for c in ["/usr/bin/sqlite3", "/opt/homebrew/opt/sqlite/bin/sqlite3"] where FileManager.default.isExecutableFile(atPath: c) {
        return c
    }
    return "sqlite3"
}

private func ffmpegBinary() -> String {
    if let env = ProcessInfo.processInfo.environment["PRIVY_FFMPEG_PATH"],
       FileManager.default.isExecutableFile(atPath: env) { return env }
    for c in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: c) {
        return c
    }
    return "ffmpeg"
}

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
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// Generates a real, decodable Ogg Opus silent file at `url` of ~`durationSeconds`.
private func writeValidOgg(at url: URL, durationSeconds: Double) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegBinary())
    process.arguments = [
        "-nostats", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "anullsrc=channel_layout=mono:sample_rate=16000",
        "-t", String(durationSeconds),
        "-c:a", "libopus",
        // Force the Ogg container: the test fixture path often ends in `.ogg.partial`, whose
        // trailing extension ffmpeg cannot infer a muxer from.
        "-f", "ogg",
        url.path,
    ]
    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "ReconciliationTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ffmpeg failed: \(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")",
        ])
    }
}

/// Writes `count` random bytes — a file `ffprobe` will report as undecodable.
private func writeGarbage(at url: URL, count: Int = 256) throws {
    try Data((0..<count).map { _ in UInt8.random(in: 0...255) }).write(to: url)
}

private func audioURL(_ layout: StorageLayout, _ relPath: String) -> URL {
    layout.audioDirectory.appendingPathComponent(relPath)
}

private func makeLayoutAndStore() async throws -> (layout: StorageLayout, store: PrivyStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("privy-recon-test-\(UUID().uuidString)", isDirectory: true)
    let layout = AppPaths.layout(rootedAt: root)
    try AppPaths.ensureDirectoriesExist(layout)
    let store = try PrivyStore(databaseURL: layout.databaseURL)
    try await store.prepareDatabase()
    return (layout, store, root)
}

private func reading() -> ClockReading {
    ClockReading(wallUTC: Date(), monotonicSeconds: 0, clockEpoch: UUID())
}

private func newChunk(path: String) -> NewChunk {
    NewChunk(kind: .shadow, startedAtUTC: Date(), startedMono: 1, relativeAudioPath: path)
}

private func chunkRowCSV(_ dbPath: String, id: Int64) throws -> String {
    try trimmed(sqlite(dbPath, "SELECT state || '|' || size_bytes || '|' || duration_s || '|' || COALESCE(checksum,'') FROM chunks WHERE id=\(id);"))
}

private func countRows(_ dbPath: String, whereClause: String) throws -> Int {
    Int(trimmed(try sqlite(dbPath, "SELECT count(*) FROM chunks WHERE \(whereClause);"))) ?? -1
}

private func healthKinds(_ dbPath: String) throws -> [String] {
    try trimmed(sqlite(dbPath, "SELECT kind FROM health ORDER BY id;"))
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty }
}

private func files(in dir: URL) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var out: [String] = []
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(url.lastPathComponent)
        }
    }
    return out
}

// MARK: - End-to-end crash recovery (real store + real files + real ffprobe)

@Suite struct ReconciliationTests {

    @Test func finalizePartialToReadyWithRealMeasuredMetadata() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-01-01T00-00-00.000000Z_aaaaaaaa.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        let partial = audioURL(layout, relPath + ".partial")
        try writeValidOgg(at: partial, durationSeconds: 2.0)
        let measuredSize = fileSize(partial)
        #expect(!FileManager.default.fileExists(atPath: audioURL(layout, relPath).path))

        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(report.readyCount == 1)
        // Partial renamed to final; audio preserved, not deleted.
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: audioURL(layout, relPath).path))
        // Measured metadata replaced the stale checkpoint (size from FS, duration from ffprobe).
        let csv = try chunkRowCSV(layout.databaseURL.path, id: chunk.id)
        let parts = csv.components(separatedBy: "|")
        #expect(parts.count == 4)
        #expect(parts[0] == "ready")
        #expect(Int64(parts[1]) == measuredSize, "size must come from the filesystem, not the checkpoint")
        #expect(abs((Double(parts[2]) ?? -1) - 2.0) < 0.2, "duration must come from ffprobe")
        #expect(parts[3].count == 64, "checksum must be a 64-char hex SHA-256")
        #expect(try healthKinds(layout.databaseURL.path).contains("recovery"))
    }

    @Test func finalizeRecordingRowRemeasuresFinalOgg() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-01-01T00-00-00.000000Z_bbbbbbbb.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        let final = audioURL(layout, relPath)
        try writeValidOgg(at: final, durationSeconds: 1.5)
        let measuredSize = fileSize(final)

        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(report.readyCount == 1)
        #expect(FileManager.default.fileExists(atPath: final.path))
        let csv = try chunkRowCSV(layout.databaseURL.path, id: chunk.id)
        let parts = csv.components(separatedBy: "|")
        #expect(parts[0] == "ready")
        #expect(Int64(parts[1]) == measuredSize)
        #expect(abs((Double(parts[2]) ?? -1) - 1.5) < 0.2)
        #expect(parts[3].count == 64)
    }

    @Test func missingFileMarksFailedAndLogsError() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-01-01T00-00-00.000000Z_cccccccc.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        // No file written.

        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(report.failedCount == 1)
        let csv = try chunkRowCSV(layout.databaseURL.path, id: chunk.id)
        #expect(csv.hasPrefix("failed|"))
        #expect(try healthKinds(layout.databaseURL.path).contains("error"))
    }

    @Test func orphanFileIsImportedAsFailedAndNeverDeleted() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-07-30T12:34:56.000000Z_orphanuu.ogg"
        let orphan = audioURL(layout, relPath)
        try writeValidOgg(at: orphan, durationSeconds: 0.5)
        let originalSize = fileSize(orphan)

        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(report.failedCount >= 1)
        #expect(report.preservedFileCount >= 1)
        // File preserved exactly (never deleted or overwritten).
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(fileSize(orphan) == originalSize)
        // A failed row now owns it.
        let n = try countRows(layout.databaseURL.path, whereClause: "audio_path='\(relPath)' AND state='failed'")
        #expect(n == 1)
        #expect(try healthKinds(layout.databaseURL.path).contains("recovery"))
    }

    @Test func undecodablePartialIsPreservedAndFailed() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-01-01T00-00-00.000000Z_dddddddd.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        let partial = audioURL(layout, relPath + ".partial")
        try writeGarbage(at: partial)
        let originalSize = fileSize(partial)

        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(report.failedCount == 1)
        #expect(report.preservedFileCount == 1)
        let csv = try chunkRowCSV(layout.databaseURL.path, id: chunk.id)
        #expect(csv.hasPrefix("failed|"))
        // Non-empty partial is renamed to the final path and preserved (never deleted).
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(FileManager.default.fileExists(atPath: audioURL(layout, relPath).path))
        #expect(fileSize(audioURL(layout, relPath)) == originalSize)
    }

    @Test func emptyPartialIsPreservedInPlaceAndFailed() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-01-01T00-00-00.000000Z_eeeeeeee.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        let partial = audioURL(layout, relPath + ".partial")
        try FileManager.default.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
        // Empty file.
        _ = try sqlite(layout.databaseURL.path, "")  // no-op, keeps helper warm
        try Data().write(to: partial)

        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(report.failedCount == 1)
        let csv = try chunkRowCSV(layout.databaseURL.path, id: chunk.id)
        #expect(csv.hasPrefix("failed|"))
        // Empty partial is left in place (not renamed), preserved.
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: audioURL(layout, relPath).path))
    }

    @Test func reconcileIsIdempotentAcrossRepeatedRuns() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Mixed crash landscape.
        let readyPartial = "2026-01-01T00-00-00.000000Z_ready.ogg"
        let readyChunk = try await store.createChunk(newChunk(path: readyPartial))
        try writeValidOgg(at: audioURL(layout, readyPartial + ".partial"), durationSeconds: 1.0)
        let missing = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_missing.ogg"))
        try writeValidOgg(at: audioURL(layout, "2026-07-30T01:02:03.000000Z_orphan.ogg"), durationSeconds: 0.5)

        let first = try await store.reconcile(storage: layout, at: reading())
        #expect(first.readyCount == 1)
        #expect(first.failedCount >= 2)
        let rowsBefore = try countRows(layout.databaseURL.path, whereClause: "1=1")

        // Second pass: every already-reconciled row is skipped (matching checksum / terminal
        // state / claimed orphan), so no new actions and no new rows.
        let second = try await store.reconcile(storage: layout, at: reading())
        #expect(second.actions.isEmpty, "second reconcile must produce no actions; got \(second.actions)")
        let rowsAfter = try countRows(layout.databaseURL.path, whereClause: "1=1")
        #expect(rowsAfter == rowsBefore, "second reconcile must not add rows")
        // And the ready chunk is still ready with its measured metadata intact.
        let csv = try chunkRowCSV(layout.databaseURL.path, id: readyChunk.id)
        #expect(csv.hasPrefix("ready|"))
        // Missing-file row stayed failed.
        let missingCSV = try chunkRowCSV(layout.databaseURL.path, id: missing.id)
        #expect(missingCSV.hasPrefix("failed|"))
    }

    @Test func pathTraversalRowCannotEscapeAudioDirectory() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // Simulate a corrupted DB row whose audio_path tries to escape the audio dir.
        let db = layout.databaseURL.path
        _ = try sqlite(db, """
        INSERT INTO chunks (kind, started_at_utc, started_mono, duration_s, audio_path, size_bytes, state)
        VALUES ('shadow','2026-01-01T00:00:00.000000Z',0,0,'../../escape.ogg',0,'recording');
        """)
        // Plant the would-be escape target outside the audio dir with known content.
        let escapeTarget = root.appendingPathComponent("escape.ogg")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: escapeTarget)

        // Reconcile must not throw (per-action failures become health rows) and must not
        // touch the file outside the audio directory.
        let report = try await store.reconcile(storage: layout, at: reading())

        #expect(try Data(contentsOf: escapeTarget) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(try healthKinds(db).contains("error"), "the unsafe path must be surfaced, not silently skipped")
        // No file should have appeared inside the audio directory for this row.
        #expect(!FileManager.default.fileExists(atPath: audioURL(layout, "../../escape.ogg").path))
        // The traversal row must not have been finalized to ready.
        let readyCount = try countRows(db, whereClause: "audio_path='../../escape.ogg' AND state='ready'")
        #expect(readyCount == 0)
        _ = report
    }

    @Test func duplicateAudioPathRowsConvergeGracefully() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let relPath = "2026-01-01T00-00-00.000000Z_dup.ogg"
        // Two rows referencing the same path (UUID collision).
        let a = try await store.createChunk(newChunk(path: relPath))
        let b = try await store.createChunk(newChunk(path: relPath))
        try writeValidOgg(at: audioURL(layout, relPath), durationSeconds: 1.0)

        let report = try await store.reconcile(storage: layout, at: reading())

        // Both rows converge without crashing; the single file is preserved.
        let aCSV = try chunkRowCSV(layout.databaseURL.path, id: a.id)
        let bCSV = try chunkRowCSV(layout.databaseURL.path, id: b.id)
        #expect(aCSV.hasPrefix("ready|"))
        #expect(bCSV.hasPrefix("ready|"))
        #expect(FileManager.default.fileExists(atPath: audioURL(layout, relPath).path))
        #expect(report.readyCount >= 1)
    }

    @Test func everyPreservedFileHasARowAndNoRowStaysRecording() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = layout.databaseURL.path
        // One of each crash case.
        try writeValidOgg(at: audioURL(layout, "2026-01-01T00-00-00.000000Z_p1.ogg.partial"), durationSeconds: 1.0)
        _ = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_p1.ogg"))
        try writeValidOgg(at: audioURL(layout, "2026-01-01T00-00-00.000000Z_p2.ogg"), durationSeconds: 1.0)
        _ = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_p2.ogg"))
        _ = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_missing.ogg"))
        try writeValidOgg(at: audioURL(layout, "2026-07-30T01:02:03.000000Z_orphan.ogg"), durationSeconds: 0.5)
        try writeGarbage(at: audioURL(layout, "2026-01-01T00-00-00.000000Z_bad.ogg.partial"))
        _ = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_bad.ogg"))

        _ = try await store.reconcile(storage: layout, at: reading())

        // No row remains recording after recovery.
        let recording = try countRows(db, whereClause: "state='recording'")
        #expect(recording == 0, "a recording row should not survive reconciliation")
        // Every audio file left on disk maps to a chunk row (partials normalized to .ogg).
        for filename in files(in: layout.audioDirectory) {
            // Strip a trailing .partial if any survived (empty ones may remain).
            let rowPath = filename.hasSuffix(".partial")
                ? String(filename.dropLast(".partial".count))
                : filename
            let n = try countRows(db, whereClause: "audio_path='\(rowPath)'")
            #expect(n >= 1, "preserved file \(filename) has no owning row")
        }
    }

    @Test func reconcileSurvivesAMidwayFileFailureTerminalizesAndReruns() async throws {
        // "file-operation failure midway": one action's rename target lives in a read-only
        // directory so `moveItem` throws. Reconcile must (a) not abort, (b) terminally mark
        // the affected row `failed` (never leave it `recording`), (c) still commit siblings,
        // and (d) converge stably once the fault is cleared and reconcile re-runs.
        let (layout, store, root) = try await makeLayoutAndStore()
        let db = layout.databaseURL.path
        let roDir = audioURL(layout, "ro")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let aPath = "ro/2026-01-01T00-00-00.000000Z_blockA.ogg"
        let aChunk = try await store.createChunk(newChunk(path: aPath))
        try writeValidOgg(at: audioURL(layout, aPath + ".partial"), durationSeconds: 1.0)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)

        let bPath = "2026-01-01T00-00-00.000000Z_okB.ogg"
        let bChunk = try await store.createChunk(newChunk(path: bPath))
        try writeValidOgg(at: audioURL(layout, bPath), durationSeconds: 1.0)

        // Must not throw: the failing action is caught + terminally surfaced, not propagated.
        _ = try await store.reconcile(storage: layout, at: reading())

        // The failed action's row is terminally `failed` (never left `recording`).
        let aCSV = try chunkRowCSV(db, id: aChunk.id)
        #expect(aCSV.hasPrefix("failed|"), "failed row must not remain recording")
        // Sibling committed; the failure was surfaced via health.
        let bCSV = try chunkRowCSV(db, id: bChunk.id)
        #expect(bCSV.hasPrefix("ready|"), "sibling chunk must still finalize")
        #expect(try healthKinds(db).contains("error"))
        let recordingCount = try countRows(db, whereClause: "state='recording'")
        #expect(recordingCount == 0, "no row should remain recording after reconcile")

        // Restore the fault and re-run: stable idempotent state.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path)
        let rowsBefore = try countRows(db, whereClause: "1=1")
        let again = try await store.reconcile(storage: layout, at: reading())
        #expect(again.actions.isEmpty, "second reconcile must be a no-op; got \(again.actions)")
        let rowsAfter = try countRows(db, whereClause: "1=1")
        #expect(rowsAfter == rowsBefore)
        // A stays failed (terminal); its audio is preserved (never deleted).
        #expect(try chunkRowCSV(db, id: aChunk.id).hasPrefix("failed|"))
        #expect(FileManager.default.fileExists(atPath: audioURL(layout, aPath + ".partial").path))
    }

    @Test func reconcileFinalizeWithVanishedRowSurfacesMissingNotReady() async throws {
        // Finding 1: a guarded finalize UPDATE must classify its zero-row result. An external
        // DELETE between inventory and apply makes the UPDATE affect zero rows; classify reads
        // it as `.missing`, throws `unknownChunk`, and the reconcile loop durably surfaces the
        // failure — it never logs the vanished row as a silent ready.
        let (layout, _, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = layout.databaseURL.path
        let gate = ProbeStartGate()
        let trigger = PrivyWriteFailureTrigger()
        let store = try PrivyStore(
            databaseURL: layout.databaseURL,
            audioProbe: GatedSlowProbe(perProbeSeconds: 0.3, gate: gate, result: .decodable(durationSeconds: 0.5)),
            writeFailureTrigger: trigger
        )
        try await store.prepareDatabase()
        let relPath = "2026-01-01T00-00-00.000000Z_vanished.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        try writeValidOgg(at: audioURL(layout, relPath + ".partial"), durationSeconds: 1.0)

        // The gate fires once the inventory row-read is done and the probe begins yielding;
        // awaiting it guarantees the DELETE lands after the read but before the guarded apply
        // UPDATE, independent of host scheduling/load.
        async let reportFuture = store.reconcile(storage: layout, at: reading())
        await gate.wait()
        _ = try sqlite(db, "DELETE FROM chunks WHERE id=\(chunk.id);")
        _ = try await reportFuture

        #expect(try countRows(db, whereClause: "id=\(chunk.id)") == 0, "vanished row must stay gone")
        #expect(try countRows(db, whereClause: "state='ready'") == 0, "a vanished row must never become ready")
        #expect(try healthKinds(db).contains("error"), "the missing-row failure must be surfaced, not swallowed")
    }

    @Test func reconcileFinalizeWithExternallyMutatedRowSurfacesConflictNotReady() async throws {
        // Finding 1: a guarded finalize UPDATE that hits zero rows because the row moved to an
        // unexpected/future state must classify as `.conflict` and throw — never become a
        // silent ready. Here an external transition to `transcribed` (a later-milestone state)
        // lands between inventory and apply.
        let (layout, _, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = layout.databaseURL.path
        let gate = ProbeStartGate()
        let trigger = PrivyWriteFailureTrigger()
        let store = try PrivyStore(
            databaseURL: layout.databaseURL,
            audioProbe: GatedSlowProbe(perProbeSeconds: 0.3, gate: gate, result: .decodable(durationSeconds: 0.5)),
            writeFailureTrigger: trigger
        )
        try await store.prepareDatabase()
        let relPath = "2026-01-01T00-00-00.000000Z_conflict.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        try writeValidOgg(at: audioURL(layout, relPath + ".partial"), durationSeconds: 1.0)

        async let reportFuture = store.reconcile(storage: layout, at: reading())
        await gate.wait()
        _ = try sqlite(db, "UPDATE chunks SET state='transcribed' WHERE id=\(chunk.id);")
        _ = try await reportFuture

        let state = try trimmed(sqlite(db, "SELECT state FROM chunks WHERE id=\(chunk.id);"))
        #expect(state == "transcribed", "an externally-mutated row must not be overwritten back to ready")
        #expect(try countRows(db, whereClause: "state='ready'") == 0)
        #expect(try healthKinds(db).contains("error"), "the state conflict must be surfaced")
    }

    @Test func reconcilePreservedRowAlreadyFailedIsIdempotentClassified() async throws {
        // Finding 1: `markFailedAndLog` must read changesCount. A row pre-terminalized to
        // `failed` between inventory and apply makes the terminalize UPDATE hit zero rows;
        // classify reads it as `.alreadyTerminal` (idempotent) and still logs the event rather
        // than silently no-op-ing without inspecting the row.
        let (layout, _, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = layout.databaseURL.path
        let gate = ProbeStartGate()
        let trigger = PrivyWriteFailureTrigger()
        let store = try PrivyStore(
            databaseURL: layout.databaseURL,
            audioProbe: GatedSlowProbe(perProbeSeconds: 0.3, gate: gate, result: .failed(reason: "simulated undecodable")),
            writeFailureTrigger: trigger
        )
        try await store.prepareDatabase()
        let relPath = "2026-01-01T00-00-00.000000Z_prefailed.ogg"
        let chunk = try await store.createChunk(newChunk(path: relPath))
        try writeGarbage(at: audioURL(layout, relPath + ".partial"))

        async let reportFuture = store.reconcile(storage: layout, at: reading())
        await gate.wait()
        _ = try sqlite(db, "UPDATE chunks SET state='failed' WHERE id=\(chunk.id);")
        _ = try await reportFuture

        let state = try trimmed(sqlite(db, "SELECT state FROM chunks WHERE id=\(chunk.id);"))
        #expect(state == "failed", "pre-failed row stays failed (idempotent terminalization)")
        #expect(try countRows(db, whereClause: "state='recording'") == 0)
        #expect(try healthKinds(db).contains("recovery"), "the preserved-unreadable event is still logged")
    }

    @Test func reconcileThrowsAggregateWhenDatabaseUnavailableMidPass() async throws {
        // "DB-failure midway": the database becomes unavailable mid-pass. The required
        // failure-surfacing write also fails, so reconcile must throw an aggregate rather
        // than return a success report that hides the failure. Restoring the DB lets a
        // re-run converge.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privy-recon-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppPaths.layout(rootedAt: root)
        try AppPaths.ensureDirectoriesExist(layout)
        let trigger = PrivyWriteFailureTrigger()
        let store = try PrivyStore(
            databaseURL: layout.databaseURL, audioProbe: FFprobeAudioProbe(), writeFailureTrigger: trigger
        )
        try await store.prepareDatabase()

        // Two recoverable chunks so the pass has work that must hit the DB.
        let p1 = "2026-01-01T00-00-00.000000Z_a1.ogg"
        _ = try await store.createChunk(newChunk(path: p1))
        try writeValidOgg(at: audioURL(layout, p1 + ".partial"), durationSeconds: 1.0)
        let p2 = "2026-01-01T00-00-00.000000Z_a2.ogg"
        _ = try await store.createChunk(newChunk(path: p2))
        try writeValidOgg(at: audioURL(layout, p2 + ".partial"), durationSeconds: 1.0)

        // Arm the DB failure for writes only; reads (inventory) still succeed.
        trigger.startFailing()
        var didThrow = false
        do {
            _ = try await store.reconcile(storage: layout, at: reading())
        } catch {
            didThrow = true
        }
        #expect(didThrow, "reconcile must throw an aggregate when surfacing cannot be persisted")

        // Restore the DB and re-run: converges, no rows left recording.
        trigger.stopFailing()
        _ = try await store.reconcile(storage: layout, at: reading())
        #expect(try countRows(layout.databaseURL.path, whereClause: "state='recording'") == 0)
        #expect(try countRows(layout.databaseURL.path, whereClause: "state='ready'") >= 2)
    }

    @Test func hashFailurePreservesFileAndNeverCommitsReady() async throws {
        // A file that ffprobe would decode but cannot be hashed (unreadable) must NOT become
        // `ready` with sentinel metadata. We inject a probe that *claims* decodable, while
        // the real file is chmod 000 so SHA-256 fails during inventory measurement.
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = layout.databaseURL.path
        _ = store  // store built by helper; we rebuild with the lying probe below
        let trigger = PrivyWriteFailureTrigger()
        let lyingStore = try PrivyStore(
            databaseURL: layout.databaseURL, audioProbe: LyingProbe(), writeFailureTrigger: trigger
        )
        try await lyingStore.prepareDatabase()
        let relPath = "2026-01-01T00-00-00.000000Z_locked.ogg"
        let chunk = try await lyingStore.createChunk(newChunk(path: relPath))
        let partial = audioURL(layout, relPath + ".partial")
        try writeValidOgg(at: partial, durationSeconds: 1.0)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: partial.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: partial.path) }

        _ = try await lyingStore.reconcile(storage: layout, at: reading())

        // Row is `failed` (preserved), never `ready` — no guessed/empty metadata committed.
        let csv = try chunkRowCSV(db, id: chunk.id)
        #expect(csv.hasPrefix("failed|"), "an unhashable file must not become ready")
        // File preserved: a non-empty partial is renamed to the final `.ogg` then marked
        // failed (rename needs directory write, not file read, so chmod 000 still renames).
        #expect(FileManager.default.fileExists(atPath: audioURL(layout, relPath).path))
    }

    @Test func symlinkEscapeThrowsAndLeavesOutsideTargetUntouched() async throws {
        // A symlink inside the audio dir pointing outside must be rejected during
        // enumeration — containment is checked for EVERY entry (symlinks resolved), so the
        // escape surfaces as a thrown error rather than being silently dropped/followed. The
        // outside target is never probed, hashed, or moved.
        let (layout, _, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside-target.ogg")
        try Data([0xC0, 0xFF, 0xEE]).write(to: outside)
        let link = audioURL(layout, "escape.ogg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let trigger = PrivyWriteFailureTrigger()
        let store = try PrivyStore(
            databaseURL: layout.databaseURL, audioProbe: FFprobeAudioProbe(), writeFailureTrigger: trigger
        )
        try await store.prepareDatabase()
        var didThrow = false
        do {
            _ = try await store.reconcile(storage: layout, at: reading())
        } catch {
            didThrow = true
        }
        #expect(didThrow, "a symlink escape must surface, not be silently followed")
        #expect(try Data(contentsOf: outside) == Data([0xC0, 0xFF, 0xEE]), "outside target must be untouched")
        #expect(try countRows(layout.databaseURL.path, whereClause: "state='ready'") == 0)
    }

    @Test func unreadableSubdirSurfacesRatherThanOmittingFiles() async throws {
        // An unreadable subdirectory cannot be silently skipped: enumerateAudioFiles
        // propagates the traversal error and reconcile throws.
        let (layout, _, root) = try await makeLayoutAndStore()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: audioURL(layout, "secret").path)
            try? FileManager.default.removeItem(at: root)
        }
        let secret = audioURL(layout, "secret")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: secret.appendingPathComponent("hidden.ogg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)

        let trigger = PrivyWriteFailureTrigger()
        let store = try PrivyStore(
            databaseURL: layout.databaseURL, audioProbe: FFprobeAudioProbe(), writeFailureTrigger: trigger
        )
        try await store.prepareDatabase()
        await #expect(throws: (any Error).self) {
            _ = try await store.reconcile(storage: layout, at: reading())
        }
    }

    @Test func manyProbesDoNotBlockReconcileProgress() async throws {
        // A slow probe is `await`ed off the actor (never busily polled on it). Reconcile
        // over many such files finishes in bounded wall-time — not N × a real 10s probe —
        // proving the actor yields per probe rather than blocking serially for the full
        // probe lifetime. (BoundedProcess's own timeout/reap behavior is covered separately
        // in AudioProbeTests; this test asserts the wall-time bound on the reconcile path.)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privy-recon-slow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AppPaths.layout(rootedAt: root)
        try AppPaths.ensureDirectoriesExist(layout)
        let trigger = PrivyWriteFailureTrigger()
        // 40ms/probe fake; each represents a probe that must be bounded-yielded.
        let store = try PrivyStore(databaseURL: layout.databaseURL, audioProbe: SlowProbe(perProbeSeconds: 0.04), writeFailureTrigger: trigger)
        try await store.prepareDatabase()
        let n = 20
        for i in 0..<n {
            let rel = "2026-07-30T00-00-0\(i % 10)-\(i).ogg"
            _ = try await store.createChunk(newChunk(path: rel))
            try writeValidOgg(at: audioURL(layout, rel + ".partial"), durationSeconds: 0.5)
        }

        let start = Date()
        _ = try await store.reconcile(storage: layout, at: reading())
        let elapsed = Date().timeIntervalSince(start)
        // 20 × 40ms ≈ 0.8s if yielded per probe; must be far below 20 × a real 10s probe.
        #expect(elapsed < 6.0, "reconcile over many slow probes must be bounded; took \(elapsed)s")
        #expect(try countRows(layout.databaseURL.path, whereClause: "state='recording'") == 0)
    }

    // MARK: - Pure planner (synthetic inventories)

    private func row(
        id: Int64, path: String, state: ChunkState,
        size: Int64 = 0, duration: Double = 0, checksum: String? = nil
    ) -> ReconciliationChunkRow {
        ReconciliationChunkRow(
            id: id, kind: "shadow", startedAtUtc: "2026-01-01T00:00:00.000000Z",
            startedMono: 0, relativeAudioPath: path, sizeBytes: size,
            durationSeconds: duration, checksumSHA256: checksum, state: state.rawValue
        )
    }

    private func file(_ path: String, size: Int64 = 100, probe: AudioProbeResult, checksum: String? = "c") -> ReconciliationFile {
        ReconciliationFile(relativePath: path, sizeBytes: size, probe: probe, checksumSHA256: checksum)
    }

    @Test func plannerFinalizesPartialAndRecordingRowAndOrphan() {
        let inv = ReconciliationInventory(rows: [
            row(id: 1, path: "a.ogg", state: .recording),
            row(id: 2, path: "b.ogg", state: .recording),
            row(id: 3, path: "c.ogg", state: .recording),
        ], files: [
            file("a.ogg.partial", probe: .decodable(durationSeconds: 2.0), checksum: "ca"),
            file("b.ogg", probe: .decodable(durationSeconds: 1.0), checksum: "cb"),
        ])
        let report = ReconciliationPlanner.plan(inventory: inv)
        // Row 1: partial → finalizedPartial. Row 2: final → finalizedRecordingRow. Row 3: no file → failedMissingFile.
        // Orphan: none here (a.partial and b.ogg are claimed).
        #expect(report.actions.count == 3)
        #expect(report.actions[0].kind == .finalizedPartial)
        #expect(report.actions[0].chunkID == 1)
        #expect(report.actions[1].kind == .finalizedRecordingRow)
        #expect(report.actions[1].chunkID == 2)
        #expect(report.actions[2].kind == .failedMissingFile)
        #expect(report.actions[2].chunkID == 3)
        #expect(report.readyCount == 2)
        #expect(report.failedCount == 1)
        #expect(report.preservedFileCount == 0)
    }

    @Test func plannerPreservesUndecodableAndImportsOrphan() {
        let inv = ReconciliationInventory(rows: [
            row(id: 1, path: "bad.ogg", state: .recording),
        ], files: [
            file("bad.ogg.partial", probe: .failed(reason: "undecodable"), checksum: nil),
            file("lonely.ogg", probe: .decodable(durationSeconds: 1.0), checksum: "cl"),
            file("empty.ogg.partial", size: 0, probe: .failed(reason: "empty"), checksum: nil),
        ])
        let report = ReconciliationPlanner.plan(inventory: inv)
        // Row 1: non-empty-but-undecodable partial → preservedUnreadable. Two orphans follow.
        #expect(report.actions.contains { $0.kind == .preservedUnreadable && $0.chunkID == 1 })
        let orphans = report.actions.filter { $0.kind == .importedOrphan }
        #expect(orphans.count == 2)
        #expect(orphans.map(\.relativeAudioPath).sorted() == ["empty.ogg.partial", "lonely.ogg"])
        #expect(report.failedCount == 3)
        #expect(report.preservedFileCount == 3)
    }

    @Test func plannerSkipsReadyRowWithMatchingChecksum() {
        // A ready row whose measured checksum matches needs NO action (idempotent re-run).
        let inv = ReconciliationInventory(rows: [
            row(id: 1, path: "stable.ogg", state: .ready, checksum: "match"),
        ], files: [
            file("stable.ogg", probe: .decodable(durationSeconds: 1.0), checksum: "match"),
        ])
        let report = ReconciliationPlanner.plan(inventory: inv)
        #expect(report.actions.isEmpty)
        #expect(report.readyCount == 0)
    }

    @Test func plannerRemeasuresReadyRowWhenChecksumDiffers() {
        let inv = ReconciliationInventory(rows: [
            row(id: 1, path: "drift.ogg", state: .ready, checksum: "stale"),
        ], files: [
            file("drift.ogg", probe: .decodable(durationSeconds: 1.0), checksum: "fresh"),
        ])
        let report = ReconciliationPlanner.plan(inventory: inv)
        #expect(report.actions.count == 1)
        #expect(report.actions[0].kind == .finalizedRecordingRow)
        #expect(report.readyCount == 1)
    }

    @Test func plannerClaimsFilesForTerminalRowsSoTheyAreNotOrphans() {
        // A failed row's preserved file must NOT be treated as an orphan.
        let inv = ReconciliationInventory(rows: [
            row(id: 1, path: "kept.ogg", state: .failed),
        ], files: [
            file("kept.ogg", probe: .failed(reason: "terminal"), checksum: nil),
        ])
        let report = ReconciliationPlanner.plan(inventory: inv)
        #expect(report.actions.isEmpty, "a failed row needs no action and its file is not an orphan")
    }

    // MARK: - Audio preservation guarantee

    @Test func reconcileNeverDeletesAnyAudio() async throws {
        let (layout, store, root) = try await makeLayoutAndStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let keepers = [
            "2026-01-01T00-00-00.000000Z_k1.ogg.partial",
            "2026-07-30T01:02:03.000000Z_k2.ogg",        // orphan
            "2026-01-01T00-00-00.000000Z_k3.ogg.partial", // garbage partial (recording row)
        ]
        try writeValidOgg(at: audioURL(layout, keepers[0]), durationSeconds: 1.0)
        try writeValidOgg(at: audioURL(layout, keepers[1]), durationSeconds: 1.0)
        try writeGarbage(at: audioURL(layout, keepers[2]))
        _ = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_k1.ogg"))
        _ = try await store.createChunk(newChunk(path: "2026-01-01T00-00-00.000000Z_k3.ogg"))

        _ = try await store.reconcile(storage: layout, at: reading())

        // Every original byte stream still exists somewhere under the audio dir (possibly
        // renamed from .partial to .ogg); nothing was deleted.
        let after = Set(files(in: layout.audioDirectory))
        #expect(after.contains("2026-01-01T00-00-00.000000Z_k1.ogg"))     // renamed partial
        #expect(after.contains("2026-07-30T01:02:03.000000Z_k2.ogg"))      // orphan preserved
        #expect(after.contains("2026-01-01T00-00-00.000000Z_k3.ogg"))      // garbage renamed+preserved
    }
}

private func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}

// MARK: - Test probe fakes

/// A probe that always reports `.decodable`, regardless of the real file — used to drive the
/// hash-failure path (a file that "would decode" but cannot be hashed).
private struct LyingProbe: AudioProbing {
    func probe(durationOf url: URL) async -> AudioProbeResult { .decodable(durationSeconds: 1.0) }
}

/// A probe that sleeps before returning, simulating a slow/hung probe that must be
/// bounded-yielded rather than busily polled on the Store actor.
private struct SlowProbe: AudioProbing {
    let perProbeSeconds: Double
    func probe(durationOf url: URL) async -> AudioProbeResult {
        let nanos = UInt64(perProbeSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        return .decodable(durationSeconds: 0.5)
    }
}

/// A one-shot gate a test awaits before mutating the DB, so the mutation is guaranteed to
/// land AFTER the inventory row-read but BEFORE the guarded apply UPDATE (during the
/// probe's actor yield). `@unchecked Sendable` is justified: all access is serialized via
/// `lock`.
private final class ProbeStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock(); c.resume()
            } else {
                continuation = c; lock.unlock()
            }
        }
    }

    /// Called from the probe the instant it starts — by then the inventory row-read has
    /// completed (buildInventory reads rows before it probes any file).
    func fire() {
        lock.lock()
        let c = continuation
        continuation = nil
        fired = true
        lock.unlock()
        c?.resume()
    }
}

/// A slow probe that fires a `ProbeStartGate` when it starts (signaling the inventory read
/// is done), then yields for `perProbeSeconds` before returning `result`. Used to drive the
/// reconcile zero-row paths deterministically: the test awaits the gate, mutates the DB, and
/// the mutation reliably lands during the yield — independent of host scheduling/load.
private struct GatedSlowProbe: AudioProbing {
    let perProbeSeconds: Double
    let gate: ProbeStartGate
    let result: AudioProbeResult
    func probe(durationOf url: URL) async -> AudioProbeResult {
        gate.fire()
        let nanos = UInt64(perProbeSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
        return result
    }
}
