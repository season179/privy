import Foundation

// Cross-worker store contract. W1 owns the declaration; W2 implements `PrivyStoring`
// against it. See docs/m1/plan.md ("Store").

/// On-disk locations for Privy data. `rootDirectory` is the app-support root; the
/// database and audio directory live beneath it. Failed/suspect files remain preserved
/// in place (M1 has no quarantine directory).
public struct StorageLayout: Sendable, Equatable {
    public let rootDirectory: URL
    public let databaseURL: URL
    public let audioDirectory: URL
}

/// The kind of reconciliation action planned for a recovered row/file pair. W2's
/// `ReconciliationPlanner` is pure: DB/file inventory in, ordered actions out.
public enum ReconciliationActionKind: String, Sendable, Codable {
    case finalizedPartial, finalizedRecordingRow, failedMissingFile, importedOrphan, preservedUnreadable
}

public struct ReconciliationAction: Sendable, Equatable {
    public let kind: ReconciliationActionKind
    public let chunkID: Int64?
    public let relativeAudioPath: String
    public let detail: String
}

public struct ReconciliationReport: Sendable, Equatable {
    public let actions: [ReconciliationAction]
    public let readyCount: Int
    public let failedCount: Int
    public let preservedFileCount: Int
}

/// Chunk lifecycle states. M1 only writes `recording`, `ready`, and `failed`; later
/// milestones accept the remaining values without a schema change.
public enum ChunkState: String, Sendable, Codable {
    case recording, ready, transcribing, transcribed, uploaded, deleted, failed
}

public enum ChunkKind: String, Sendable, Codable { case shadow, utterance }
public enum VADEventKind: String, Sendable, Codable { case score, speechStart, speechEnd }

/// Input for creating a new chunk row. The final `.ogg` path is persisted; the `.partial`
/// suffix is derived and never stored.
public struct NewChunk: Sendable {
    public let kind: ChunkKind
    public let startedAtUTC: Date
    public let startedMono: Double
    public let relativeAudioPath: String
}

public struct ChunkRecord: Sendable, Equatable {
    public let id: Int64
    public let kind: ChunkKind
    public let startedAtUTC: Date
    public let startedMono: Double
    public let durationSeconds: Double
    public let relativeAudioPath: String
    public let sizeBytes: Int64
    public let checksumSHA256: String?
    public let state: ChunkState
}

public struct VADEventRecord: Sendable, Equatable {
    public let chunkID: Int64
    public let monotonicSeconds: Double
    public let kind: VADEventKind
    /// Required for `score`; optional on `speechStart`/`speechEnd` boundaries.
    public let score: Float?
}

public struct MenuSummary: Sendable, Equatable {
    public let currentChunk: ChunkRecord?
    public let bytesRecordedToday: Int64
    public let recentHealth: [HealthEvent]
}

/// The SQLite-backed store. `PrivyStore` (W2) is an actor wrapping a GRDB
/// `DatabasePool` in WAL mode. No audio-thread code calls the Store.
public protocol PrivyStoring: Sendable {
    func prepareDatabase() async throws
    func createChunk(_ chunk: NewChunk) async throws -> ChunkRecord
    func checkpointChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64) async throws
    func finalizeChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64,
                       checksumSHA256: String) async throws -> ChunkRecord
    func failChunk(id: Int64, reason: String) async throws
    func appendVADEvents(_ events: [VADEventRecord]) async throws
    func appendHealth(_ event: HealthEvent) async throws
    func menuSummary(dayContaining: Date, healthLimit: Int) async throws -> MenuSummary
    func reconcile(storage: StorageLayout, at: ClockReading) async throws -> ReconciliationReport
}
