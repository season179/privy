import Foundation

// `ReconciliationPlanner` is PURE: it reasons over a `ReconciliationInventory` (DB rows +
// measured files) and emits an ordered `[ReconciliationAction]` plus a projected
// `ReconciliationReport`. It never touches the filesystem, never shells out to `ffprobe`,
// and never opens the database — all measurement happens in `PrivyStore` while building
// the inventory, and all application happens in `PrivyStore` while applying the plan.
//
// Crash cases handled (docs/m1/plan.md "Crash and lifecycle invariants" §5):
//   1. recording row + `.partial`      → finalizedPartial (non-empty + decodable) else preservedUnreadable
//   2. recording row + final `.ogg`    → finalizedRecordingRow (remeasure) else preservedUnreadable
//   3. recording/ready row + no file   → failedMissingFile
//   4. orphan final/partial file       → importedOrphan (always becomes a `failed` row; never deleted)
//   5. empty/unreadable file           → preservedUnreadable (preserved + failed)
// Reconciliation never deletes audio and never lets a relative path escape the audio dir
// (the store enforces path safety at apply time).

// MARK: - Inventory

/// The measured state of one audio file in `StorageLayout.audioDirectory`, relative to
/// that directory. `checksumSHA256` is populated only for `.decodable` files (the only
/// ones that can become `ready`), so reconcile does not hash files it will preserve.
struct ReconciliationFile: Sendable, Equatable {
    let relativePath: String
    let sizeBytes: Int64
    let probe: AudioProbeResult
    let checksumSHA256: String?
}

/// Outcome of probing one file. Every non-decodable situation collapses to `.failed`
/// (empty file, ffprobe unavailable, probe error, undecodable stream): the plan treats
/// them identically as "preserve and mark failed", per the hard constraint.
enum AudioProbeResult: Sendable, Equatable {
    case decodable(durationSeconds: Double)
    case failed(reason: String)
}

/// A chunk row reduced to the fields reconciliation reasons over.
struct ReconciliationChunkRow: Sendable, Equatable {
    let id: Int64
    let kind: String
    let startedAtUtc: String
    let startedMono: Double
    let relativeAudioPath: String
    let sizeBytes: Int64
    let durationSeconds: Double
    let checksumSHA256: String?
    let state: String
}

/// Everything the planner needs: every chunk row and every measured audio file.
struct ReconciliationInventory: Sendable, Equatable {
    let rows: [ReconciliationChunkRow]
    let files: [ReconciliationFile]
}

// MARK: - Planner

enum ReconciliationPlanner {

    /// Produces an ordered plan and a projected report for the given inventory.
    ///
    /// Ordering: rows are processed in ascending `id` (recover older chunks first); each
    /// row contributes at most one action; orphan files (claimed by no row) follow in
    /// ascending `relativePath`. The store applies actions in this order.
    static func plan(inventory: ReconciliationInventory) -> ReconciliationReport {
        var actions: [ReconciliationAction] = []
        var readyCount = 0
        var failedCount = 0
        var preservedFileCount = 0

        let fileByPath = Dictionary(
            inventory.files.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // First pass: claim every file referenced by any row (regardless of state) so a
        // file owned by a `failed`/`transcribing`/future row is never mistaken for an
        // orphan. Duplicate audio_paths degrade gracefully: both rows see the file.
        var claimedFiles = Set<String>()
        for row in inventory.rows {
            claimedFiles.insert(row.relativeAudioPath)
            claimedFiles.insert(partialPath(for: row.relativeAudioPath))
        }

        let sortedRows = inventory.rows.sorted { $0.id < $1.id }
        for row in sortedRows {
            guard let action = action(
                forRow: row,
                fileByPath: fileByPath
            ) else {
                continue
            }
            actions.append(action)
            switch action.kind {
            case .finalizedPartial, .finalizedRecordingRow:
                readyCount += 1
            case .preservedUnreadable:
                failedCount += 1
                preservedFileCount += 1
            case .failedMissingFile:
                failedCount += 1
            case .importedOrphan:
                failedCount += 1
                preservedFileCount += 1
            }
        }

        // Orphans: files on disk claimed by no row. They always become `failed` rows so
        // the audio is attributable and never discarded.
        let sortedOrphans = inventory.files
            .filter { !claimedFiles.contains($0.relativePath) }
            .sorted { $0.relativePath < $1.relativePath }
        for file in sortedOrphans {
            actions.append(ReconciliationAction(
                kind: .importedOrphan,
                chunkID: nil,
                relativeAudioPath: file.relativePath,
                detail: orphanDetail(for: file)
            ))
            failedCount += 1
            preservedFileCount += 1
        }

        return ReconciliationReport(
            actions: actions,
            readyCount: readyCount,
            failedCount: failedCount,
            preservedFileCount: preservedFileCount
        )
    }

    // MARK: - Per-row decision

    /// Decides the action for one row. Returns nil when the row needs no action (e.g. a
    /// `ready` row whose measured checksum already matches — fully reconciled and
    /// idempotent on re-run; or any terminal/other state with no recovery to perform).
    private static func action(
        forRow row: ReconciliationChunkRow,
        fileByPath: [String: ReconciliationFile]
    ) -> ReconciliationAction? {
        let state = row.state
        let finalPath = row.relativeAudioPath
        let partialPathValue = partialPath(for: finalPath)

        // Only `recording` and `ready` rows need recovery/remeasure. Other states
        // (failed/transcribing/transcribed/uploaded/deleted) are terminal or owned by a
        // later milestone's worker; reconciliation leaves them untouched.
        let needsRecovery = (state == ChunkState.recording.rawValue || state == ChunkState.ready.rawValue)
        guard needsRecovery else { return nil }

        if let finalFile = fileByPath[finalPath] {
            return actionForExistingFile(row: row, path: finalPath, file: finalFile, kind: .finalizedRecordingRow)
        }
        if let partialFile = fileByPath[partialPathValue] {
            return actionForExistingFile(row: row, path: finalPath, file: partialFile, kind: .finalizedPartial)
        }
        // recording/ready row but neither final nor partial exists on disk.
        return ReconciliationAction(
            kind: .failedMissingFile,
            chunkID: row.id,
            relativeAudioPath: finalPath,
            detail: "chunk \(row.id) state=\(state) has no audio file on disk"
        )
    }

    /// Maps a present file to a finalize (→ ready) or preserve (→ failed) action, or nil
    /// when the row is already fully reconciled (idempotent skip). The `kind`
    /// distinguishes a final-file remeasure (`finalizedRecordingRow`) from a partial that
    /// must be renamed first (`finalizedPartial`).
    private static func actionForExistingFile(
        row: ReconciliationChunkRow,
        path: String,
        file: ReconciliationFile,
        kind: ReconciliationActionKind
    ) -> ReconciliationAction? {
        switch file.probe {
        case .decodable(let duration):
            // Idempotency: a `ready` row whose stored checksum already matches the measured
            // file is fully reconciled — emit no action so re-running reconcile does nothing
            // and does not rewrite the row. `recording` rows always transition.
            if row.state == ChunkState.ready.rawValue,
               let stored = row.checksumSHA256,
               stored == file.checksumSHA256 {
                return nil
            }
            return ReconciliationAction(
                kind: kind,
                chunkID: row.id,
                relativeAudioPath: path,
                detail: finalizeDetail(row: row, file: file, duration: duration, kind: kind)
            )
        case .failed(let reason):
            // Idempotency: a `failed` row is already terminal.
            if row.state == ChunkState.failed.rawValue { return nil }
            // Non-empty partials are still renamed to the final path before being marked
            // failed (the store performs the rename); empty files are left in place. Either
            // way the row becomes `failed` and the file is preserved.
            let nonEmpty = file.sizeBytes > 0
            return ReconciliationAction(
                kind: .preservedUnreadable,
                chunkID: row.id,
                relativeAudioPath: path,
                detail: preservedDetail(row: row, file: file, reason: reason, nonEmpty: nonEmpty, kind: kind)
            )
        }
    }

    // MARK: - Path helpers

    /// The `.partial` companion of a final `.ogg` path. Derived, never persisted.
    static func partialPath(for finalPath: String) -> String {
        finalPath + ".partial"
    }

    // MARK: - Detail strings (informational; the store reads measured values from inventory)

    private static func finalizeDetail(
        row: ReconciliationChunkRow,
        file: ReconciliationFile,
        duration: Double,
        kind: ReconciliationActionKind
    ) -> String {
        let op = (kind == .finalizedPartial) ? "renamed .partial and finalized" : "remeasured final file"
        return "chunk \(row.id) \(op); size=\(file.sizeBytes)B duration=\(duration)s sha256=\(file.checksumSHA256 ?? "?")"
    }

    private static func preservedDetail(
        row: ReconciliationChunkRow,
        file: ReconciliationFile,
        reason: String,
        nonEmpty: Bool,
        kind: ReconciliationActionKind
    ) -> String {
        let rename = (kind == .finalizedPartial && nonEmpty) ? " (non-empty partial renamed before failure)" : ""
        return "chunk \(row.id) preserved as failed; size=\(file.sizeBytes)B reason=\(reason)\(rename)"
    }

    private static func orphanDetail(for file: ReconciliationFile) -> String {
        switch file.probe {
        case .decodable(let duration):
            return "orphan file; size=\(file.sizeBytes)B duration=\(duration)s; imported as failed (never deleted)"
        case .failed(let reason):
            return "orphan file; size=\(file.sizeBytes)B reason=\(reason); imported as failed (never deleted)"
        }
    }
}
