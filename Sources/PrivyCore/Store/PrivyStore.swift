import Foundation
import GRDB
import CryptoKit

// `PrivyStore`: the SQLite-backed `PrivyStoring` actor. Wraps a GRDB `DatabasePool` in WAL
// mode with foreign keys on, runs the versioned migrator, and implements the chunk/VAD/
// health CRUD plus deterministic startup reconciliation.
//
// Design notes:
// - `ReconciliationPlanner` is pure; this actor builds the inventory (DB rows + measured
//   files), hands it to the planner, and applies the resulting actions idempotently.
// - State transitions use guarded `WHERE state IN (...)` updates so a duplicate
//   finalize/fail/reconcile can never regress a terminal row.
// - Every relative audio path is validated to stay inside `StorageLayout.audioDirectory`;
//   a path that escapes is rejected, never silently resolved elsewhere.
// - Recovered files are remeasured (filesystem size, `ffprobe`-decoded duration, SHA-256)
//   before they may become `ready`; a missing/failed/undecodable probe preserves the file
//   and marks the row `failed`. No recovered audio is ever deleted.

public actor PrivyStore: PrivyStoring {

    // MARK: - Lifecycle

    private let dbPool: DatabasePool
    private var prepared = false
    private var ffprobePath: String?

    /// Creates the store and opens its `DatabasePool` (WAL, foreign keys on). The parent
    /// directory is created if missing so a fresh layout works without an extra step.
    public init(databaseURL: URL) throws {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true // default, but explicit: the schema relies on FKs
        // WAL is automatic for DatabasePool (GRDB opens pools in WAL); no journalMode set.
        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
    }

    public func prepareDatabase() async throws {
        let migrator = PrivyDatabaseMigrations.makeMigrator()
        try migrator.migrate(dbPool)
        prepared = true
    }

    private func requirePrepared() throws {
        guard prepared else { throw PrivyStoreError.notPrepared }
    }

    /// Forces GRDB's *synchronous* `write` overload. The async overload is selected by
    /// default whenever `T: Sendable` and the closure is `@Sendable`-eligible (the sync
    /// overload is `@_disfavoredOverload`); typing the parameter as a plain non-`@Sendable`
    /// `(Database) throws -> T` makes only the sync overload viable, so every store method
    /// stays synchronous and runs on the actor without an `await` cascade.
    private func writeSync<T>(_ updates: (Database) throws -> T) throws -> T {
        try dbPool.write(updates)
    }

    /// Synchronous `read`, for the same reason as `writeSync`.
    private func readSync<T>(_ value: (Database) throws -> T) throws -> T {
        try dbPool.read(value)
    }

    // MARK: - Chunks

    public func createChunk(_ chunk: NewChunk) async throws -> ChunkRecord {
        try requirePrepared()
        try validateRelativePath(chunk.relativeAudioPath)
        return try writeSync { db in
            var row = ChunkRow(new: chunk)
            try row.insert(db)
            return try row.toRecord()
        }
    }

    public func checkpointChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64) async throws {
        try requirePrepared()
        try writeSync { db in
            guard let existing = try ChunkRow.fetchOne(db, key: id) else {
                throw PrivyStoreError.unknownChunk(id: id)
            }
            // Stale checkpoint against an already-terminal row is benign (no-op); only a
            // `recording` row accepts progress updates.
            guard existing.state == ChunkState.recording.rawValue else { return }
            try db.execute(
                sql: "UPDATE chunks SET duration_s = ?, size_bytes = ? WHERE id = ? AND state = ?",
                arguments: [durationSeconds, sizeBytes, id, ChunkState.recording.rawValue]
            )
        }
    }

    public func finalizeChunk(
        id: Int64,
        durationSeconds: Double,
        sizeBytes: Int64,
        checksumSHA256: String
    ) async throws -> ChunkRecord {
        try requirePrepared()
        return try writeSync { db in
            guard let existing = try ChunkRow.fetchOne(db, key: id) else {
                throw PrivyStoreError.unknownChunk(id: id)
            }
            // Idempotent: an already-`ready` chunk returns unchanged. A non-recording,
            // non-ready state means the caller and the row disagree — surface it.
            if existing.state == ChunkState.ready.rawValue {
                return try existing.toRecord()
            }
            guard existing.state == ChunkState.recording.rawValue else {
                throw PrivyStoreError.inconsistentRow("cannot finalize chunk \(id) in state \(existing.state)")
            }
            try db.execute(
                sql: """
                    UPDATE chunks
                    SET duration_s = ?, size_bytes = ?, checksum = ?, state = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: [durationSeconds, sizeBytes, checksumSHA256,
                            ChunkState.ready.rawValue, id, ChunkState.recording.rawValue]
            )
            guard let updated = try ChunkRow.fetchOne(db, key: id) else {
                throw PrivyStoreError.inconsistentRow("chunk \(id) vanished after finalize")
            }
            return try updated.toRecord()
        }
    }

    public func failChunk(id: Int64, reason: String) async throws {
        try requirePrepared()
        try writeSync { db in
            guard let existing = try ChunkRow.fetchOne(db, key: id) else {
                throw PrivyStoreError.unknownChunk(id: id)
            }
            // Idempotent: already-failed is a no-op.
            if existing.state == ChunkState.failed.rawValue { return }
            guard existing.state == ChunkState.recording.rawValue else {
                throw PrivyStoreError.inconsistentRow("cannot fail chunk \(id) in state \(existing.state)")
            }
            try db.execute(
                sql: "UPDATE chunks SET state = ? WHERE id = ? AND state = ?",
                arguments: [ChunkState.failed.rawValue, id, ChunkState.recording.rawValue]
            )
            // Record why it failed, surfaced through health (no silent state change).
            try insertHealth(
                db,
                event: HealthEvent(
                    atUTC: Date(),
                    kind: .writerError,
                    severity: .error,
                    detail: HealthDetail(
                        message: "chunk \(id) failed: \(reason)",
                        clockEpoch: nil,
                        monotonicSeconds: nil,
                        gapStartedUTC: nil,
                        gapEndedUTC: nil,
                        durationSeconds: nil,
                        deviceUID: nil,
                        droppedFrames: nil,
                        durationIsEstimated: false
                    )
                )
            )
        }
    }

    // MARK: - VAD + health writes

    public func appendVADEvents(_ events: [VADEventRecord]) async throws {
        try requirePrepared()
        guard !events.isEmpty else { return }
        try writeSync { db in
            for event in events {
                var row = VADEventRow(event)
                try row.insert(db)
            }
        }
    }

    public func appendHealth(_ event: HealthEvent) async throws {
        try requirePrepared()
        try writeSync { db in try insertHealth(db, event: event) }
    }

    /// Shared insert used by both the public `appendHealth` and in-transaction reconciliation
    /// health rows, so every health write goes through the same envelope encoding.
    /// `nonisolated` because it touches only its arguments (no actor state); this lets it run
    /// inside GRDB's synchronous write closures without a cross-actor `await`.
    nonisolated private func insertHealth(_ db: Database, event: HealthEvent) throws {
        var row = try HealthRow(event)
        try row.insert(db)
    }

    // MARK: - Menu summary

    public func menuSummary(dayContaining: Date, healthLimit: Int) async throws -> MenuSummary {
        try requirePrepared()
        return try readSync { db in
            let currentChunk = try ChunkRow
                .filter(Column("state") == ChunkState.recording.rawValue)
                .order(Column("started_at_utc").desc, Column("id").desc)
                .fetchOne(db)?
                .toRecord()

            let day = Self.utcDayBounds(containing: dayContaining)
            let bytesToday = try Int64.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(size_bytes), 0)
                    FROM chunks
                    WHERE started_at_utc >= ? AND started_at_utc < ?
                    """,
                arguments: [day.start, day.end]
            ) ?? 0

            let limit = max(0, healthLimit)
            let healthRows = try HealthRow
                .order(Column("at_utc").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
            // Most-recent-first is the natural menu order; decode every row and fail
            // visibly on a malformed envelope rather than silently dropping it.
            let recentHealth = try healthRows.map { try $0.toEvent() }

            return MenuSummary(
                currentChunk: currentChunk,
                bytesRecordedToday: bytesToday,
                recentHealth: recentHealth
            )
        }
    }

    // MARK: - Reconciliation

    /// Runs startup reconciliation: builds a measured inventory (DB rows + probed files),
    /// asks the pure `ReconciliationPlanner` for an ordered plan, and applies each action
    /// idempotently.
    ///
    /// The returned `ReconciliationReport` reflects the *plan* (what reconcile determined
    /// from the inventory): `readyCount`/`failedCount`/`preservedFileCount` are projected
    /// counts, not a tally of actual apply outcomes. Per-action failures are surfaced as
    /// persisted `.error` health rows (never silently discarded) and the next reconcile
    /// re-attempts the action; re-runs converge because every transition is guarded.
    public func reconcile(storage: StorageLayout, at: ClockReading) async throws -> ReconciliationReport {
        try requirePrepared()
        // Build the measured inventory, plan idempotently, then apply each action.
        let inventory = try buildInventory(storage: storage)
        let plan = ReconciliationPlanner.plan(inventory: inventory)
        for action in plan.actions {
            // Per-action best effort: a single bad file must not abort recovery of the
            // rest. Failures are persisted as health rows and the next reconcile re-attempts.
            do {
                try apply(action: action, inventory: inventory, storage: storage, at: at)
            } catch {
                // Surface the failure as a persisted health row (no silent discard); the
                // next reconcile re-attempts the action idempotently.
                try? writeSync { db in
                    try insertHealth(db, event: HealthEvent(
                        atUTC: at.wallUTC,
                        kind: .error,
                        severity: .error,
                        detail: healthDetail(message: "reconciliation action failed: \(error) — \(action.detail)")
                    ))
                }
            }
        }
        return plan
    }

    // MARK: - Inventory

    /// Reads every chunk row and measures every audio file under `storage.audioDirectory`.
    /// Only files attached to a `recording`/`ready` row are probed (the only ones that can
    /// become `ready`); orphans and terminal-row files are not probed or hashed.
    private func buildInventory(storage: StorageLayout) throws -> ReconciliationInventory {
        let rows: [ReconciliationChunkRow] = try readSync { db -> [ReconciliationChunkRow] in
            let fetched = try ChunkRow.order(Column("id").asc).fetchAll(db)
            var mapped: [ReconciliationChunkRow] = []
            mapped.reserveCapacity(fetched.count)
            for row in fetched {
                guard let id = row.id else {
                    throw PrivyStoreError.inconsistentRow("chunk row missing id during inventory")
                }
                mapped.append(ReconciliationChunkRow(
                    id: id,
                    kind: row.kind,
                    startedAtUtc: row.startedAtUtc,
                    startedMono: row.startedMono,
                    relativeAudioPath: row.audioPath,
                    sizeBytes: row.sizeBytes,
                    durationSeconds: row.durationS,
                    checksumSHA256: row.checksum,
                    state: row.state
                ))
            }
            return mapped
        }

        // Paths that may legitimately become `ready` and therefore need a real probe.
        var probePaths = Set<String>()
        for row in rows where row.state == ChunkState.recording.rawValue || row.state == ChunkState.ready.rawValue {
            probePaths.insert(row.relativeAudioPath)
            probePaths.insert(ReconciliationPlanner.partialPath(for: row.relativeAudioPath))
        }

        let audioFiles = try enumerateAudioFiles(in: storage.audioDirectory)
        var files: [ReconciliationFile] = []
        files.reserveCapacity(audioFiles.count)
        for fileURL in audioFiles {
            let relativePath = try self.relativePath(of: fileURL, in: storage.audioDirectory)
            let size = fileSize(at: fileURL)
            let shouldProbe = probePaths.contains(relativePath)
            let probe: AudioProbeResult
            var checksum: String? = nil
            if shouldProbe {
                probe = probeAudio(at: fileURL)
                if case .decodable = probe {
                    checksum = sha256(of: fileURL)
                }
            } else {
                probe = (size == 0)
                    ? .failed(reason: "empty file")
                    : .failed(reason: "not probed (orphan or terminal row)")
            }
            files.append(ReconciliationFile(
                relativePath: relativePath,
                sizeBytes: size,
                probe: probe,
                checksumSHA256: checksum
            ))
        }

        return ReconciliationInventory(rows: rows, files: files)
    }

    // MARK: - Action application

    /// Applies one reconciliation action idempotently. All filesystem mutations happen here;
    /// the planner only decided what should happen. Each branch is safe to re-run.
    private func apply(
        action: ReconciliationAction,
        inventory: ReconciliationInventory,
        storage: StorageLayout,
        at: ClockReading
    ) throws {
        switch action.kind {
        case .finalizedRecordingRow:
            try applyFinalize(action: action, sourcePartial: false, inventory: inventory, storage: storage, at: at)
        case .finalizedPartial:
            try applyFinalize(action: action, sourcePartial: true, inventory: inventory, storage: storage, at: at)
        case .preservedUnreadable:
            try applyPreservedUnreadable(action: action, storage: storage, at: at)
        case .failedMissingFile:
            try applyFailedMissingFile(action: action, at: at)
        case .importedOrphan:
            try applyImportedOrphan(action: action, storage: storage, at: at)
        }
    }

    /// Finalizes a chunk to `ready`: renames a `.partial` to its final `.ogg` when needed,
    /// then writes the freshly measured size/duration/checksum with a guarded update.
    private func applyFinalize(
        action: ReconciliationAction,
        sourcePartial: Bool,
        inventory: ReconciliationInventory,
        storage: StorageLayout,
        at: ClockReading
    ) throws {
        guard let chunkID = action.chunkID else {
            throw PrivyStoreError.inconsistentRow("finalize action missing chunkID: \(action.detail)")
        }
        let finalURL = try resolveAudioURL(relativePath: action.relativeAudioPath, in: storage.audioDirectory)
        let partialURLValue = partialURL(for: finalURL) // <final>.partial
        // Reconcile the on-disk file to the final path first (idempotent rename).
        if sourcePartial {
            try renamePartialToFinalIfNeeded(partialURL: partialURLValue, finalURL: finalURL)
        }
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            // File vanished between inventory and apply: mark failed rather than publish
            // ready metadata for a missing file.
            try markFailedAndLog(
                chunkID: chunkID,
                kind: .error,
                severity: .error,
                message: "reconciliation finalize found no file for chunk \(chunkID): \(action.detail)",
                at: at
            )
            return
        }
        // Measured values come from the freshly built inventory (not the stale checkpoint).
        let measured = measuredValues(for: action.relativeAudioPath, partial: sourcePartial, in: inventory)
        try writeSync { db in
            try db.execute(
                sql: """
                    UPDATE chunks
                    SET duration_s = ?, size_bytes = ?, checksum = ?, state = ?
                    WHERE id = ? AND state IN (?, ?)
                    """,
                arguments: [
                    measured.durationSeconds, measured.sizeBytes, measured.checksum,
                    ChunkState.ready.rawValue,
                    chunkID,
                    ChunkState.recording.rawValue, ChunkState.ready.rawValue,
                ]
            )
            try insertHealth(db, event: HealthEvent(
                atUTC: at.wallUTC,
                kind: .recovery,
                severity: .info,
                detail: healthDetail(message: "reconciled chunk \(chunkID) to ready: \(action.detail)")
            ))
        }
    }

    /// Marks a chunk `failed` while preserving its file. Non-empty `.partial` files are
    /// renamed to the final `.ogg` first (the file is preserved, never deleted).
    private func applyPreservedUnreadable(
        action: ReconciliationAction,
        storage: StorageLayout,
        at: ClockReading
    ) throws {
        guard let chunkID = action.chunkID else {
            throw PrivyStoreError.inconsistentRow("preservedUnreadable action missing chunkID: \(action.detail)")
        }
        let finalURL = try resolveAudioURL(relativePath: action.relativeAudioPath, in: storage.audioDirectory)
        let partialURLValue = partialURL(for: finalURL)
        // Preserve a non-empty partial at the final path; empty partials are left in place.
        try renamePartialToFinalIfNeeded(partialURL: partialURLValue, finalURL: finalURL)
        try markFailedAndLog(
            chunkID: chunkID,
            kind: .recovery,
            severity: .warning,
            message: "preserved unreadable chunk \(chunkID) as failed: \(action.detail)",
            at: at
        )
    }

    private func applyFailedMissingFile(action: ReconciliationAction, at: ClockReading) throws {
        guard let chunkID = action.chunkID else {
            throw PrivyStoreError.inconsistentRow("failedMissingFile action missing chunkID: \(action.detail)")
        }
        try markFailedAndLog(
            chunkID: chunkID,
            kind: .error,
            severity: .error,
            message: "chunk \(chunkID) has no audio file: \(action.detail)",
            at: at
        )
    }

    /// Imports an orphan file as a new `failed` chunk row derived from its filename. The
    /// file is preserved (renamed to `.ogg` if a non-empty `.partial`); never discarded.
    private func applyImportedOrphan(
        action: ReconciliationAction,
        storage: StorageLayout,
        at: ClockReading
    ) throws {
        let originalURL = try resolveAudioURL(relativePath: action.relativeAudioPath, in: storage.audioDirectory)
        // Normalize a non-empty `.partial` orphan to its final `.ogg` path.
        var fileURL = originalURL
        var relativePath = action.relativePathForFile
        if action.relativePathForFile.hasSuffix(PartialSuffix) {
            let finalRel = String(action.relativePathForFile.dropLast(PartialSuffix.count))
            let finalURL = try resolveAudioURL(relativePath: finalRel, in: storage.audioDirectory)
            try renamePartialToFinalIfNeeded(partialURL: originalURL, finalURL: finalURL)
            fileURL = finalURL
            relativePath = finalRel
        }

        let size = fileSize(at: fileURL)
        let parsedStart = parseLeadingUTC(filename: fileURL.lastPathComponent)
        let startedAtUTC = parsedStart ?? at.wallUTC
        let usedFallback = (parsedStart == nil)

        try writeSync { db in
            // Idempotent: a prior reconcile may already have imported this orphan.
            if try ChunkRow.filter(Column("audio_path") == relativePath).fetchOne(db) != nil {
                return
            }
            var row = ChunkRow(
                id: nil,
                kind: ChunkKind.shadow.rawValue,
                startedAtUtc: PrivyDateCoding.string(from: startedAtUTC),
                startedMono: 0, // cross-process orphan: monotonic origin unknown
                durationS: 0,
                audioPath: relativePath,
                sizeBytes: size,
                checksum: nil,
                state: ChunkState.failed.rawValue,
                sessionId: nil
            )
            try row.insert(db)
            let newID = try row.id.require()
            try insertHealth(db, event: HealthEvent(
                atUTC: at.wallUTC,
                kind: .recovery,
                severity: .warning,
                detail: healthDetail(
                    message: "imported orphan audio as failed chunk \(newID): \(relativePath)\(usedFallback ? " (start time unknown, used reconcile time)" : "")"
                )
            ))
        }
    }

    // MARK: - Shared helpers

    /// Idempotently renames a non-empty `.partial` to its final `.ogg` when the final does
    /// not yet exist. If the final already exists (a prior pass renamed it), the partial is
    /// absent, or the partial is empty, this is a no-op — files are preserved, never
    /// deleted. Returns true when a rename actually occurred.
    @discardableResult
    private func renamePartialToFinalIfNeeded(partialURL: URL, finalURL: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: partialURL.path),
              !fm.fileExists(atPath: finalURL.path),
              fileSize(at: partialURL) > 0 else { return false }
        try fm.moveItem(at: partialURL, to: finalURL)
        return true
    }

    /// Guarded transition to `failed` plus a health row, in one transaction.
    private func markFailedAndLog(
        chunkID: Int64,
        kind: HealthKind,
        severity: HealthSeverity,
        message: String,
        at: ClockReading
    ) throws {
        try writeSync { db in
            try db.execute(
                sql: "UPDATE chunks SET state = ? WHERE id = ? AND state IN (?, ?)",
                arguments: [
                    ChunkState.failed.rawValue, chunkID,
                    ChunkState.recording.rawValue, ChunkState.ready.rawValue,
                ]
            )
            try insertHealth(db, event: HealthEvent(
                atUTC: at.wallUTC,
                kind: kind,
                severity: severity,
                detail: healthDetail(message: message)
            ))
        }
    }

    /// Builds a `HealthDetail` with the fields reconciliation populates. `nonisolated` so it
    /// can be called from inside GRDB write closures alongside `insertHealth`.
    nonisolated private func healthDetail(message: String) -> HealthDetail {
        HealthDetail(
            message: message,
            clockEpoch: nil,
            monotonicSeconds: nil,
            gapStartedUTC: nil,
            gapEndedUTC: nil,
            durationSeconds: nil,
            deviceUID: nil,
            droppedFrames: nil,
            durationIsEstimated: false
        )
    }

    /// Resolves the measured size/duration/checksum for a file from the inventory. For a
    /// partial source, looks up the `.partial` entry; otherwise the final entry.
    private func measuredValues(
        for relativePath: String,
        partial: Bool,
        in inventory: ReconciliationInventory
    ) -> (sizeBytes: Int64, durationSeconds: Double, checksum: String) {
        let lookup = partial
            ? ReconciliationPlanner.partialPath(for: relativePath)
            : relativePath
        let file = inventory.files.first { $0.relativePath == lookup }
        let duration: Double
        if case .decodable(let d) = file?.probe { duration = d } else { duration = 0 }
        return (
            sizeBytes: file?.sizeBytes ?? 0,
            durationSeconds: duration,
            checksum: file?.checksumSHA256 ?? ""
        )
    }

    // MARK: - Filesystem measurement

    /// Enumerates regular files under `directory` (recursively, since audio paths may name
    /// subdirectories). The directory itself need not exist yet.
    private func enumerateAudioFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// SHA-256 of a file, hex-encoded. Streams in chunks so large hour-long Opus files do
    /// not need to fit in memory.
    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 64 * 1024
        while true {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Probes a file with `ffprobe` for its decoded duration. A missing/unavailable/
    /// failing/undecodable probe is `.failed` — the caller preserves the file and marks
    /// the row `failed` rather than guessing ready duration.
    private func probeAudio(at url: URL) -> AudioProbeResult {
        guard let ffprobe = resolvedFFProbePath() else {
            return .failed(reason: "ffprobe unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            "-i", url.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failed(reason: "ffprobe could not run: \(error)")
        }
        // Bound ffprobe so a hung probe cannot wedge reconciliation.
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return .failed(reason: "ffprobe timed out")
        }
        guard process.terminationStatus == 0 else {
            return .failed(reason: "ffprobe exit status \(process.terminationStatus)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let duration = Double(trimmed), duration.isFinite, duration >= 0 else {
            return .failed(reason: "ffprobe returned no parseable duration")
        }
        return .decodable(durationSeconds: duration)
    }

    /// Locates `ffprobe` once: honors `PRIVY_FFPROBE_PATH`, then checks common Homebrew
    /// locations and `PATH`. Cached on the actor after first resolution.
    private func resolvedFFProbePath() -> String? {
        if let cached = ffprobePath { return cached }
        let candidates = [
            ProcessInfo.processInfo.environment["PRIVY_FFPROBE_PATH"],
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            ffprobePath = candidate
            return candidate
        }
        // Fall back to a PATH lookup (e.g. asdf/volta-managed binaries).
        if let found = findOnPath("ffprobe") {
            ffprobePath = found
            return found
        }
        return nil
    }

    // MARK: - Path safety

    /// Validates that `relativePath` is a simple relative path that cannot escape
    /// `audioDirectory`: not absolute, no `..` segment, no null bytes. Reconciliation and
    /// chunk creation both pass row/writer paths through this.
    private func validateRelativePath(_ relativePath: String) throws {
        try validateRelativePathSyntax(relativePath)
    }

    /// Shared syntax checks used by both `validateRelativePath` and `resolveAudioURL`.
    private func validateRelativePathSyntax(_ relativePath: String) throws {
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw PrivyStoreError.unsafeRelativePath("empty relative path")
        }
        guard !cleaned.contains("\0") else {
            throw PrivyStoreError.unsafeRelativePath("null byte in path: \(cleaned)")
        }
        // Reject absolute paths and any `..` component outright (defense in depth before
        // standardization, which would otherwise resolve them silently).
        if cleaned.hasPrefix("/") {
            throw PrivyStoreError.unsafeRelativePath("absolute path rejected: \(cleaned)")
        }
        let components = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") {
            throw PrivyStoreError.unsafeRelativePath("parent traversal rejected: \(cleaned)")
        }
    }

    /// Resolves `relativePath` under `audioDirectory` and guarantees the resolved URL is
    /// still inside it. Symlinks are resolved via standardization; any escape is rejected.
    private func resolveAudioURL(relativePath: String, in audioDirectory: URL) throws -> URL {
        try validateRelativePathSyntax(relativePath)
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = audioDirectory.appendingPathComponent(cleaned).standardizedFileURL
        let root = audioDirectory.standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        let resolvedPath = resolved.path
        if resolvedPath != root, !resolvedPath.hasPrefix(rootPrefix) {
            throw PrivyStoreError.unsafeRelativePath("escaped audio directory: \(cleaned)")
        }
        return resolved
    }

    /// The `.partial` companion URL of a final `.ogg` URL (derived, never persisted).
    private func partialURL(for finalURL: URL) -> URL {
        URL(fileURLWithPath: finalURL.path + PartialSuffix)
    }

    /// Computes the path of `fileURL` relative to `directory`, validating it stays inside.
    private func relativePath(of fileURL: URL, in directory: URL) throws -> String {
        let root = directory.standardizedFileURL.path
        let standardizedRoot = root.hasSuffix("/") ? root : root + "/"
        let abs = fileURL.standardizedFileURL.path
        guard abs.hasPrefix(standardizedRoot) else {
            throw PrivyStoreError.unsafeRelativePath("file outside audio directory: \(abs)")
        }
        return String(abs.dropFirst(standardizedRoot.count))
    }

    // MARK: - Filename parsing (best-effort, for orphan import)

    /// Parses a leading ISO-8601 UTC timestamp from an orphan filename. Returns nil if no
    /// parseable prefix is found (the caller falls back to the reconcile timestamp).
    private func parseLeadingUTC(filename: String) -> Date? {
        var stem = filename
        if stem.hasSuffix(PartialDotOggSuffix) {
            stem = String(stem.dropLast(PartialDotOggSuffix.count))
        } else if stem.hasSuffix(DotOggSuffix) {
            stem = String(stem.dropLast(DotOggSuffix.count))
        }
        // Try cumulative prefixes split at `_` so "2026-...Z_<uuid>" parses the date half.
        let parts = stem.split(separator: "_", omittingEmptySubsequences: true)
        var candidate = ""
        for part in parts {
            candidate = candidate.isEmpty ? String(part) : (candidate + "_" + String(part))
            if let date = PrivyDateCoding.date(from: candidate) { return date }
        }
        return nil
    }

    // MARK: - Static helpers

    /// UTC start (inclusive) and end (exclusive) ISO strings for the day containing `date`,
    /// used for `bytesRecordedToday` range queries.
    private static func utcDayBounds(containing date: Date) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let interval = calendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: date, duration: 86_400)
        return (
            start: PrivyDateCoding.string(from: interval.start),
            end: PrivyDateCoding.string(from: interval.end)
        )
    }

    private func findOnPath(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

// MARK: - File-extension constants

private let PartialSuffix = ".partial"
private let DotOggSuffix = ".ogg"
private let PartialDotOggSuffix = ".ogg.partial"

/// Conveniences on the action for the importer; the on-disk file for an orphan is named
/// by `action.relativeAudioPath` directly (its `.partial` form, if any).
private extension ReconciliationAction {
    var relativePathForFile: String { relativeAudioPath }
}

// MARK: - Optional require

private extension Optional {
    func require() throws -> Wrapped {
        guard let self else { throw PrivyStoreError.inconsistentRow("required value was nil") }
        return self
    }
}
