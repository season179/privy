import Foundation
import GRDB
import CryptoKit

// `PrivyStore`: the SQLite-backed `PrivyStoring` actor. Wraps a GRDB `DatabasePool` in WAL
// mode with foreign keys on, runs the versioned migrator, and implements the chunk/VAD/
// health CRUD plus deterministic startup reconciliation.
//
// Design notes:
// - DB access goes through the internal `PrivyDBAccess` seam (sync write/read) so tests can
//   inject failure modes; production wraps a `DatabasePool`.
// - `ReconciliationPlanner` is pure; this actor builds the inventory (DB rows + measured
//   files), hands it to the planner, and applies the resulting actions idempotently.
// - State transitions are guarded `WHERE state = ...` updates AND the changed-row count is
//   checked: one changed row = success; zero rows is an idempotent success only when the
//   row is already in the intended terminal state, otherwise a state-conflict error.
// - Every relative audio path is canonicalized (symlinks resolved) and containment-checked
//   against the canonical audio root; a path that escapes is rejected, never silently used.
// - Recovered files are remeasured (filesystem size, `ffprobe`-decoded duration, SHA-256)
//   and revalidated at apply time before they may become `ready`; any missing/failed/
//   undecodable measurement preserves the file and marks the row `failed`. No recovered
//   audio is ever deleted, and no guessed/sentinel metadata is ever committed as `ready`.
// - A per-action apply failure terminally marks the affected row `failed` (file preserved)
//   and logs a health row; if that durable surfacing itself fails (DB unavailable),
//   reconcile throws an aggregate error after finishing the pass. Nothing is swallowed.

public actor PrivyStore: PrivyStoring {

    // MARK: - Lifecycle

    private let dbPool: DatabasePool        // used only for migration
    private let db: any PrivyDBAccess        // read/write seam
    private let audioProbe: any AudioProbing // injectable probe seam
    private var prepared = false

    /// Creates the store and opens its `DatabasePool` (WAL, foreign keys on). The parent
    /// directory is created if missing so a fresh layout works without an extra step.
    public init(databaseURL: URL) throws {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true // default, but explicit: the schema relies on FKs
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        self.dbPool = pool
        self.db = GRDBDBAccess(pool: pool)
        self.audioProbe = FFprobeAudioProbe()
    }

    /// Internal initializer exposing the audio-probe seam and an optional write-failure
    /// trigger for tests. It opens the `DatabasePool` itself (so tests need not depend on
    /// GRDB directly); the trigger, when present, gates writes so a mid-reconcile DB failure
    /// is deterministically injectable. Not part of the public API.
    internal init(
        databaseURL: URL,
        audioProbe: any AudioProbing,
        writeFailureTrigger: PrivyWriteFailureTrigger? = nil
    ) throws {
        let parent = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        self.dbPool = pool
        let base = GRDBDBAccess(pool: pool)
        self.db = writeFailureTrigger.map { GatedDBAccess(base, trigger: $0) } ?? base
        self.audioProbe = audioProbe
    }

    /// Direct-injection initializer (GRDB required). Kept for completeness.
    internal init(dbPool: DatabasePool, db: any PrivyDBAccess, audioProbe: any AudioProbing) {
        self.dbPool = dbPool
        self.db = db
        self.audioProbe = audioProbe
    }

    public func prepareDatabase() async throws {
        let migrator = PrivyDatabaseMigrations.makeMigrator()
        try migrator.migrate(dbPool)
        prepared = true
    }

    private func requirePrepared() throws {
        guard prepared else { throw PrivyStoreError.notPrepared }
    }

    // MARK: - Chunks

    public func createChunk(_ chunk: NewChunk) async throws -> ChunkRecord {
        try requirePrepared()
        try validateRelativePath(chunk.relativeAudioPath)
        return try db.write { db in
            var row = ChunkRow(new: chunk)
            try row.insert(db)
            return try row.toRecord()
        }
    }

    public func checkpointChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64) async throws {
        try requirePrepared()
        try db.write { db in
            try db.execute(
                sql: "UPDATE chunks SET duration_s = ?, size_bytes = ? WHERE id = ? AND state = ?",
                arguments: [durationSeconds, sizeBytes, id, ChunkState.recording.rawValue]
            )
            if db.changesCount == 1 { return }
            // Zero rows: classify by the row's actual state.
            let actual = try String.fetchOne(
                db, sql: "SELECT state FROM chunks WHERE id = ?", arguments: [id]
            )
            switch actual {
            case nil:
                throw PrivyStoreError.unknownChunk(id: id)
            case ChunkState.ready.rawValue:
                return // stale checkpoint against an already-finalized chunk — benign idempotent
            case let other:
                throw PrivyStoreError.stateConflict(id: id, expected: ChunkState.recording.rawValue, actual: other ?? "<unknown>")
            }
        }
    }

    public func finalizeChunk(
        id: Int64,
        durationSeconds: Double,
        sizeBytes: Int64,
        checksumSHA256: String
    ) async throws -> ChunkRecord {
        try requirePrepared()
        return try db.write { db -> ChunkRecord in
            try db.execute(
                sql: """
                    UPDATE chunks
                    SET duration_s = ?, size_bytes = ?, checksum = ?, state = ?
                    WHERE id = ? AND state = ?
                    """,
                arguments: [durationSeconds, sizeBytes, checksumSHA256,
                            ChunkState.ready.rawValue, id, ChunkState.recording.rawValue]
            )
            if db.changesCount == 1,
               let updated = try ChunkRow.fetchOne(db, key: id) {
                return try updated.toRecord()
            }
            // Zero rows: idempotent only if already ready; otherwise a real conflict.
            let actual = try String.fetchOne(
                db, sql: "SELECT state FROM chunks WHERE id = ?", arguments: [id]
            )
            switch actual {
            case nil:
                throw PrivyStoreError.unknownChunk(id: id)
            case ChunkState.ready.rawValue:
                guard let ready = try ChunkRow.fetchOne(db, key: id) else {
                    throw PrivyStoreError.inconsistentRow("chunk \(id) vanished after idempotent finalize")
                }
                return try ready.toRecord()
            case let other:
                throw PrivyStoreError.stateConflict(id: id, expected: ChunkState.recording.rawValue, actual: other ?? "<unknown>")
            }
        }
    }

    public func failChunk(id: Int64, reason: String) async throws {
        try requirePrepared()
        try db.write { db in
            try db.execute(
                sql: "UPDATE chunks SET state = ? WHERE id = ? AND state = ?",
                arguments: [ChunkState.failed.rawValue, id, ChunkState.recording.rawValue]
            )
            if db.changesCount == 1 {
                try insertHealth(db, event: HealthEvent(
                    atUTC: Date(),
                    kind: .writerError,
                    severity: .error,
                    detail: healthDetail(message: "chunk \(id) failed: \(reason)")
                ))
                return
            }
            let actual = try String.fetchOne(
                db, sql: "SELECT state FROM chunks WHERE id = ?", arguments: [id]
            )
            switch actual {
            case nil:
                throw PrivyStoreError.unknownChunk(id: id)
            case ChunkState.failed.rawValue:
                return // already failed — idempotent
            case let other:
                throw PrivyStoreError.stateConflict(id: id, expected: ChunkState.recording.rawValue, actual: other ?? "<unknown>")
            }
        }
    }

    // MARK: - VAD + health writes

    public func appendVADEvents(_ events: [VADEventRecord]) async throws {
        try requirePrepared()
        guard !events.isEmpty else { return }
        try db.write { db in
            for event in events {
                var row = VADEventRow(event)
                try row.insert(db)
            }
        }
    }

    public func appendHealth(_ event: HealthEvent) async throws {
        try requirePrepared()
        try db.write { db in try insertHealth(db, event: event) }
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
        return try db.read { db in
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
    /// from the inventory). Per-action failures are surfaced durably: the affected row is
    /// terminally marked `failed` (file preserved) and an `.error` health row is persisted.
    /// If that durable surfacing itself cannot be persisted (database unavailable),
    /// reconcile finishes the remaining actions and then throws an aggregate error — the
    /// failure never disappears behind a successful return. Re-running after the database is
    /// restored re-attempts every action and converges.
    public func reconcile(storage: StorageLayout, at: ClockReading) async throws -> ReconciliationReport {
        try requirePrepared()
        let inventory = try await buildInventory(storage: storage)
        let plan = ReconciliationPlanner.plan(inventory: inventory)
        var unsurfaced: [String] = []
        for action in plan.actions {
            do {
                try apply(action: action, inventory: inventory, storage: storage, at: at)
            } catch {
                do {
                    try surfaceReconciliationFailure(action: action, error: error, at: at)
                } catch {
                    unsurfaced.append("\(action.kind.rawValue) \(action.relativeAudioPath): \(error)")
                }
            }
        }
        if !unsurfaced.isEmpty {
            throw PrivyStoreError.unsurfacedReconciliationFailures(unsurfaced)
        }
        return plan
    }

    /// Durably surfaces a per-action failure: terminalizes the affected row to `failed`
    /// (preserving its file) and persists an `.error` health row, in one transaction. Throws
    /// if the database is unavailable so the caller can record an unsurfaced failure.
    private func surfaceReconciliationFailure(
        action: ReconciliationAction,
        error: Error,
        at: ClockReading
    ) throws {
        try db.write { db in
            if let chunkID = action.chunkID {
                try db.execute(
                    sql: "UPDATE chunks SET state = ? WHERE id = ? AND state IN (?, ?)",
                    arguments: [ChunkState.failed.rawValue, chunkID,
                                ChunkState.recording.rawValue, ChunkState.ready.rawValue]
                )
                // changesCount is intentionally not asserted here: this is best-effort
                // terminalization; a row already terminal (failed/other) is left as-is and
                // the health row still records what happened.
            }
            try insertHealth(db, event: HealthEvent(
                atUTC: at.wallUTC,
                kind: .error,
                severity: .error,
                detail: healthDetail(
                    message: "reconciliation action failed (\(action.kind.rawValue) \(action.relativeAudioPath)): \(error)"
                )
            ))
        }
    }

    // MARK: - Inventory

    /// Reads every chunk row and measures every audio file under `storage.audioDirectory`.
    /// Only files attached to a `recording`/`ready` row are probed (the only ones that can
    /// become `ready`); orphans and terminal-row files are not probed or hashed. Probing is
    /// awaited off the actor via the `AudioProbing` seam. Throws on enumeration or per-file
    /// metadata errors rather than silently omitting files.
    private func buildInventory(storage: StorageLayout) async throws -> ReconciliationInventory {
        let rows: [ReconciliationChunkRow] = try db.read { db -> [ReconciliationChunkRow] in
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
            let size = try fileSize(at: fileURL)
            let shouldProbe = probePaths.contains(relativePath)
            var probe: AudioProbeResult
            var checksum: String? = nil
            if shouldProbe {
                probe = await audioProbe.probe(durationOf: fileURL)
                if case .decodable = probe {
                    // A hash failure turns a "decodable" probe into a failed measurement so
                    // the planner preserves the file rather than finalizing it with a nil hash.
                    do {
                        checksum = try sha256(of: fileURL)
                    } catch {
                        probe = .failed(reason: "checksum measurement failed: \(error)")
                    }
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
    /// re-measures size + checksum from the actual file, and writes them with a guarded,
    /// changes-count-checked update. Any measurement failure (file gone, unreadable, hash
    /// error, inventory drift) preserves the file and transitions the row to `failed`
    /// instead of committing guessed metadata.
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
        let partialURLValue = partialURL(for: finalURL)
        if sourcePartial {
            try renamePartialToFinalIfNeeded(partialURL: partialURLValue, finalURL: finalURL)
        }
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            try markFailedAndLog(
                chunkID: chunkID, kind: .error, severity: .error, at: at,
                message: "reconciliation finalize found no file for chunk \(chunkID): \(action.detail)"
            )
            return
        }
        // Re-measure size + checksum authoritatively from the file at apply time.
        let measuredSize: Int64
        let measuredChecksum: String
        do {
            measuredSize = try fileSize(at: finalURL)
            measuredChecksum = try sha256(of: finalURL)
        } catch {
            try markFailedAndLog(
                chunkID: chunkID, kind: .error, severity: .error, at: at,
                message: "chunk \(chunkID) measurement failed; preserved as failed: \(error)"
            )
            return
        }
        // Duration comes from the freshly-built inventory probe; guard against drift.
        guard let duration = inventoryDuration(for: action.relativeAudioPath, partial: sourcePartial, in: inventory) else {
            try markFailedAndLog(
                chunkID: chunkID, kind: .error, severity: .error, at: at,
                message: "chunk \(chunkID) has no decoded duration in inventory; preserved as failed"
            )
            return
        }
        let inventoryFile = inventoryFile(for: action.relativeAudioPath, partial: sourcePartial, in: inventory)
        if let inventoryFile, inventoryFile.sizeBytes != measuredSize {
            try markFailedAndLog(
                chunkID: chunkID, kind: .error, severity: .error, at: at,
                message: "chunk \(chunkID) inventory drift (size \(inventoryFile.sizeBytes)→\(measuredSize)); preserved as failed"
            )
            return
        }
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE chunks
                    SET duration_s = ?, size_bytes = ?, checksum = ?, state = ?
                    WHERE id = ? AND state IN (?, ?)
                    """,
                arguments: [
                    duration, measuredSize, measuredChecksum,
                    ChunkState.ready.rawValue,
                    chunkID,
                    ChunkState.recording.rawValue, ChunkState.ready.rawValue,
                ]
            )
            let note: String
            let severity: HealthSeverity
            if db.changesCount == 1 {
                note = "reconciled chunk \(chunkID) to ready: \(action.detail)"
                severity = .info
            } else {
                let actual = try String.fetchOne(
                    db, sql: "SELECT state FROM chunks WHERE id = ?", arguments: [chunkID]
                ) ?? "<missing>"
                note = "finalize skipped for chunk \(chunkID); row now in state \(actual)"
                severity = .warning
            }
            try insertHealth(db, event: HealthEvent(
                atUTC: at.wallUTC, kind: .recovery, severity: severity,
                detail: healthDetail(message: note)
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
        try renamePartialToFinalIfNeeded(partialURL: partialURLValue, finalURL: finalURL)
        try markFailedAndLog(
            chunkID: chunkID, kind: .recovery, severity: .warning, at: at,
            message: "preserved unreadable chunk \(chunkID) as failed: \(action.detail)"
        )
    }

    private func applyFailedMissingFile(action: ReconciliationAction, at: ClockReading) throws {
        guard let chunkID = action.chunkID else {
            throw PrivyStoreError.inconsistentRow("failedMissingFile action missing chunkID: \(action.detail)")
        }
        try markFailedAndLog(
            chunkID: chunkID, kind: .error, severity: .error, at: at,
            message: "chunk \(chunkID) has no audio file: \(action.detail)"
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
        var fileURL = originalURL
        var relativePath = action.relativePathForFile
        if action.relativePathForFile.hasSuffix(PartialSuffix) {
            let finalRel = String(action.relativePathForFile.dropLast(PartialSuffix.count))
            let finalURL = try resolveAudioURL(relativePath: finalRel, in: storage.audioDirectory)
            try renamePartialToFinalIfNeeded(partialURL: originalURL, finalURL: finalURL)
            fileURL = finalURL
            relativePath = finalRel
        }

        let size = try fileSize(at: fileURL)
        let parsedStart = parseLeadingUTC(filename: fileURL.lastPathComponent)
        let startedAtUTC = parsedStart ?? at.wallUTC
        let usedFallback = (parsedStart == nil)

        try db.write { db in
            if try ChunkRow.filter(Column("audio_path") == relativePath).fetchOne(db) != nil {
                return
            }
            var row = ChunkRow(
                id: nil,
                kind: ChunkKind.shadow.rawValue,
                startedAtUtc: PrivyDateCoding.string(from: startedAtUTC),
                startedMono: 0,
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
                atUTC: at.wallUTC, kind: .recovery, severity: .warning,
                detail: healthDetail(message: "imported orphan audio as failed chunk \(newID): \(relativePath)\(usedFallback ? " (start time unknown, used reconcile time)" : "")")
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
              try fileSize(at: partialURL) > 0 else { return false }
        try fm.moveItem(at: partialURL, to: finalURL)
        return true
    }

    /// Guarded transition to `failed` plus a health row, in one transaction. The update is
    /// changes-count-checked; a zero-row result (row already terminal) still logs the health
    /// row so the event is never lost.
    private func markFailedAndLog(
        chunkID: Int64,
        kind: HealthKind,
        severity: HealthSeverity,
        at: ClockReading,
        message: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE chunks SET state = ? WHERE id = ? AND state IN (?, ?)",
                arguments: [ChunkState.failed.rawValue, chunkID,
                            ChunkState.recording.rawValue, ChunkState.ready.rawValue]
            )
            try insertHealth(db, event: HealthEvent(
                atUTC: at.wallUTC, kind: kind, severity: severity,
                detail: healthDetail(message: message)
            ))
        }
    }

    /// Builds a `HealthDetail` with the fields reconciliation populates. `nonisolated` so it
    /// can be called from inside GRDB write closures alongside `insertHealth`.
    nonisolated private func healthDetail(message: String) -> HealthDetail {
        HealthDetail(
            message: message, clockEpoch: nil, monotonicSeconds: nil,
            gapStartedUTC: nil, gapEndedUTC: nil, durationSeconds: nil,
            deviceUID: nil, droppedFrames: nil, durationIsEstimated: false
        )
    }

    /// The decoded duration carried for a file in the inventory (nil if absent/not decodable).
    private func inventoryDuration(
        for relativePath: String,
        partial: Bool,
        in inventory: ReconciliationInventory
    ) -> Double? {
        let lookup = partial ? ReconciliationPlanner.partialPath(for: relativePath) : relativePath
        let file = inventory.files.first { $0.relativePath == lookup }
        if case .decodable(let d) = file?.probe { return d }
        return nil
    }

    /// The inventory entry for a file (nil if absent).
    private func inventoryFile(
        for relativePath: String,
        partial: Bool,
        in inventory: ReconciliationInventory
    ) -> ReconciliationFile? {
        let lookup = partial ? ReconciliationPlanner.partialPath(for: relativePath) : relativePath
        return inventory.files.first { $0.relativePath == lookup }
    }

    // MARK: - Filesystem measurement (throwing; never defaults)

    /// Enumerates regular files under `directory` (recursively). Does not skip hidden files,
    /// installs an enumerator error handler, and propagates enumeration + metadata errors
    /// instead of silently omitting files. The directory itself need not exist yet.
    private func enumerateAudioFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let errors = ErrorCollector()
        let canonicalRoot = directory.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],  // no .skipsHiddenFiles: a hidden audio file must still be accounted for
            errorHandler: { _, error in
                errors.append(error)
                return true
            }
        ) else {
            throw PrivyStoreError.measurementFailed("could not create directory enumerator for \(directory.path)")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            // Containment-check EVERY enumerated entry (symlinks resolved) before anything
            // else, so a symlink pointing outside the audio root is rejected, never silently
            // dropped or followed out. This catches both file symlinks and symlinked
            // directories that the enumerator surfaces as entries.
            let resolved = url.resolvingSymlinksInPath().path
            if resolved != rootPath, !resolved.hasPrefix(rootPrefix) {
                throw PrivyStoreError.unsafeRelativePath(
                    "enumerated path escapes audio directory: \(url.path) -> \(resolved)"
                )
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        if let first = errors.first() {
            throw PrivyStoreError.measurementFailed("audio enumeration failed: \(first)")
        }
        return urls
    }

    /// File size from the filesystem; throws on a stat failure rather than returning 0.
    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw PrivyStoreError.measurementFailed("no size for \(url.path)")
        }
        return Int64(size)
    }

    /// SHA-256 of a file, hex-encoded. Streams in chunks and throws on any open/read error;
    /// never returns a partial-hash default. Reads to EOF so the whole file is hashed.
    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 64 * 1024
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Path safety (symlink-aware containment)

    /// Validates that `relativePath` is a simple relative path: not absolute, no `..`
    /// segment, no null bytes.
    private func validateRelativePath(_ relativePath: String) throws {
        try validateRelativePathSyntax(relativePath)
    }

    private func validateRelativePathSyntax(_ relativePath: String) throws {
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw PrivyStoreError.unsafeRelativePath("empty relative path")
        }
        guard !cleaned.contains("\0") else {
            throw PrivyStoreError.unsafeRelativePath("null byte in path: \(cleaned)")
        }
        if cleaned.hasPrefix("/") {
            throw PrivyStoreError.unsafeRelativePath("absolute path rejected: \(cleaned)")
        }
        let components = cleaned.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("..") {
            throw PrivyStoreError.unsafeRelativePath("parent traversal rejected: \(cleaned)")
        }
    }

    /// Resolves `relativePath` under `audioDirectory` and guarantees the resolved URL is
    /// still inside it AFTER symlink resolution. Both the audio root and the candidate are
    /// canonicalized with `resolvingSymlinksInPath()` so a symlinked component pointing
    /// outside the storage root is rejected, not followed out.
    private func resolveAudioURL(relativePath: String, in audioDirectory: URL) throws -> URL {
        try validateRelativePathSyntax(relativePath)
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalRoot = audioDirectory.resolvingSymlinksInPath()
        let resolved = audioDirectory.appendingPathComponent(cleaned).resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let resolvedPath = resolved.path
        if resolvedPath != rootPath, !resolvedPath.hasPrefix(rootPrefix) {
            throw PrivyStoreError.unsafeRelativePath("escaped audio directory (symlink/traversal): \(cleaned)")
        }
        return resolved
    }

    /// The `.partial` companion URL of a final `.ogg` URL (derived, never persisted).
    private func partialURL(for finalURL: URL) -> URL {
        URL(fileURLWithPath: finalURL.path + PartialSuffix)
    }

    /// Computes the path of `fileURL` relative to `directory` (symlinks resolved), throwing
    /// if the file resolves outside the canonical audio root.
    private func relativePath(of fileURL: URL, in directory: URL) throws -> String {
        let canonicalRoot = directory.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let abs = fileURL.resolvingSymlinksInPath().path
        guard abs == rootPath || abs.hasPrefix(rootPrefix) else {
            throw PrivyStoreError.unsafeRelativePath("file outside audio directory: \(abs)")
        }
        return String(abs.dropFirst(rootPrefix.count))
    }

    // MARK: - Filename parsing (best-effort, for orphan import)

    private func parseLeadingUTC(filename: String) -> Date? {
        var stem = filename
        if stem.hasSuffix(PartialDotOggSuffix) {
            stem = String(stem.dropLast(PartialDotOggSuffix.count))
        } else if stem.hasSuffix(DotOggSuffix) {
            stem = String(stem.dropLast(DotOggSuffix.count))
        }
        let parts = stem.split(separator: "_", omittingEmptySubsequences: true)
        var candidate = ""
        for part in parts {
            candidate = candidate.isEmpty ? String(part) : (candidate + "_" + String(part))
            if let date = PrivyDateCoding.date(from: candidate) { return date }
        }
        return nil
    }

    // MARK: - Static helpers

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
}

// MARK: - DB-access seam

/// Internal read/write seam over GRDB so tests can inject failure modes. Declared with
/// plain (non-`@Sendable`) closures and no `T: Sendable` constraint so it binds to GRDB's
/// synchronous `write`/`read` overloads (the async `@Sendable` overloads are not selected).
protocol PrivyDBAccess: Sendable {
    func write<T>(_ updates: (Database) throws -> T) throws -> T
    func read<T>(_ value: (Database) throws -> T) throws -> T
}

/// Production `PrivyDBAccess` wrapping a GRDB `DatabasePool`.
struct GRDBDBAccess: PrivyDBAccess {
    let pool: DatabasePool
    func write<T>(_ updates: (Database) throws -> T) throws -> T { try pool.write(updates) }
    func read<T>(_ value: (Database) throws -> T) throws -> T { try pool.read(value) }
}

/// A lock-protected on/off switch for injected write failures, usable from tests without a
/// GRDB dependency. `@unchecked Sendable` is justified: all access is serialized via `lock`.
internal final class PrivyWriteFailureTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func startFailing() { lock.lock(); failing = true; lock.unlock() }
    func stopFailing() { lock.lock(); failing = false; lock.unlock() }
    var isFailing: Bool { lock.lock(); defer { lock.unlock() }; return failing }
}

/// Wraps another `PrivyDBAccess` so writes throw when an attached trigger is armed; reads
/// always pass through. Used only to make mid-reconcile DB-unavailability deterministic
/// in tests.
final class GatedDBAccess: PrivyDBAccess {
    let underlying: any PrivyDBAccess
    let trigger: PrivyWriteFailureTrigger
    init(_ underlying: any PrivyDBAccess, trigger: PrivyWriteFailureTrigger) {
        self.underlying = underlying
        self.trigger = trigger
    }
    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        if trigger.isFailing {
            throw PrivyStoreError.measurementFailed("injected database write failure")
        }
        return try underlying.write(updates)
    }
    func read<T>(_ value: (Database) throws -> T) throws -> T { try underlying.read(value) }
}

// MARK: - File-extension constants + helpers

private let PartialSuffix = ".partial"
private let DotOggSuffix = ".ogg"
private let PartialDotOggSuffix = ".ogg.partial"

private extension ReconciliationAction {
    /// The on-disk file for an orphan is named by `relativeAudioPath` directly (its
    /// `.partial` form, if any).
    var relativePathForFile: String { relativeAudioPath }
}

private extension Optional {
    func require() throws -> Wrapped {
        guard let self else { throw PrivyStoreError.inconsistentRow("required value was nil") }
        return self
    }
}

/// Lock-protected collector for `FileManager.DirectoryEnumerator` errors, which are delivered
/// to an escaping/@Sendable handler. `@unchecked Sendable` is justified: all access is
/// serialized through `lock`.
private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    func append(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        storage.append(error)
    }
    func first() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return storage.first
    }
}
