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

    @Test func reconcileSurvivesAMidwayFileFailureAndSurfacesIt() async throws {
        // "DB/file-operation failure midway": one action cannot complete (its rename target
        // lives in a read-only directory, so `moveItem` throws), yet reconcile must not abort
        // and sibling actions must still commit. The failure is surfaced as a health row.
        let (layout, store, root) = try await makeLayoutAndStore()
        let db = layout.databaseURL.path
        let roDir = audioURL(layout, "ro")
        defer {
            // Restore write perms so cleanup can delete the read-only subtree.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path)
            try? FileManager.default.removeItem(at: root)
        }

        // Chunk A: decodable partial inside a read-only subdir → renaming it out throws EPERM.
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let aPath = "ro/2026-01-01T00-00-00.000000Z_blockA.ogg"
        _ = try await store.createChunk(newChunk(path: aPath))
        try writeValidOgg(at: audioURL(layout, aPath + ".partial"), durationSeconds: 1.0)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)

        // Chunk B: final `.ogg` at the (writable) top level → finalizes with no rename.
        let bPath = "2026-01-01T00-00-00.000000Z_okB.ogg"
        let bChunk = try await store.createChunk(newChunk(path: bPath))
        try writeValidOgg(at: audioURL(layout, bPath), durationSeconds: 1.0)

        // Reconcile must not throw: the failing action is caught, not propagated.
        _ = try await store.reconcile(storage: layout, at: reading())

        // Sibling action committed despite A's failure.
        let bCSV = try chunkRowCSV(db, id: bChunk.id)
        #expect(bCSV.hasPrefix("ready|"), "sibling chunk must still finalize")
        // The midway failure is surfaced, not silently swallowed.
        #expect(try healthKinds(db).contains("error"))
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
