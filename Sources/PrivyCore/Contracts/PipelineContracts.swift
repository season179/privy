import Foundation

// Cross-worker writer, VAD, and pipeline-state contract. W1 owns the declarations; W4
// implements `ShadowChunkWriting`, `VADAnalyzing`, and `ShadowCaptureControlling`.
// See docs/m1/plan.md ("Writer and VAD" and "Monitor, health, and pipeline state").

// MARK: - Writer

/// State transitions returned by the rotating shadow-chunk writer. The pipeline applies
/// them to the Store and snapshots.
public enum WriterTransition: Sendable, Equatable {
    case opened(ChunkRecord)
    case checkpointed(chunkID: Int64, durationSeconds: Double)
    case finalized(ChunkRecord)
}

/// The Store-backed rotating Opus writer. `ShadowChunkWriter` (W4) is an actor and the
/// sole owner of an `OggOpusWriter`.
public protocol ShadowChunkWriting: Sendable {
    func append(_ block: AudioBlock16k) async throws -> [WriterTransition]
    func close(reason: StopReason, at: ClockReading) async throws -> [WriterTransition]
    func activeChunk() async -> ChunkRecord?
}

// MARK: - VAD

/// Runtime status of the VAD adapter. `failed` reduces only VAD coverage; it must never
/// stop or back-pressure recording.
public enum VADRuntimeStatus: Sendable, Equatable {
    case notStarted, preparingModel, ready, failed(String)
}

/// One observation from a 4096-sample (256 ms) FluidAudio analysis window. The adapter
/// preserves one timestamped score per window.
public struct VADObservation: Sendable, Equatable {
    /// End of the exact 4096-sample analysis window on the normalized 16 kHz timeline.
    public let streamSampleIndex: Int64
    public let monotonicSeconds: Double
    public let probability: Float
    /// `speechStart`/`speechEnd` only; `nil` for a pure score observation.
    public let boundary: VADEventKind?

    public init(streamSampleIndex: Int64, monotonicSeconds: Double, probability: Float, boundary: VADEventKind?) {
        self.streamSampleIndex = streamSampleIndex
        self.monotonicSeconds = monotonicSeconds
        self.probability = probability
        self.boundary = boundary
    }
}

/// The VAD adapter interface. `VADService` (W4) is generic over an internal
/// `VADModelProcessing` seam; tests inject a deterministic fake.
public protocol VADAnalyzing: Sendable {
    func prepare() async
    func process(_ block: AudioBlock16k) async throws -> [VADObservation]
    func reset(afterGapAt: ClockReading) async
    func status() async -> VADRuntimeStatus
}

// MARK: - Pipeline state

/// Observed capture reality — never intent. `.recording` requires a running engine, an
/// open chunk, and a fresh audio heartbeat; any missing precondition drops the state to
/// `recovering`/`error`/`paused`/`stopped` immediately.
public enum CaptureReality: Sendable, Equatable {
    case starting, recording, paused(untilUTC: Date?), recovering(String), error(String), stopped
}

/// The single observed-truth snapshot consumed by the menu UI. Derived solely from
/// post-heartbeat reality, never from a requested or cached state.
public struct PipelineSnapshot: Sendable, Equatable {
    public let capture: CaptureReality
    public let vad: VADRuntimeStatus
    public let currentChunk: ChunkRecord?
    public let bytesRecordedToday: Int64
    public let recentHealth: [HealthEvent]
    public let lastAudioAtUTC: Date?

    public init(
        capture: CaptureReality,
        vad: VADRuntimeStatus,
        currentChunk: ChunkRecord?,
        bytesRecordedToday: Int64,
        recentHealth: [HealthEvent],
        lastAudioAtUTC: Date?
    ) {
        self.capture = capture
        self.vad = vad
        self.currentChunk = currentChunk
        self.bytesRecordedToday = bytesRecordedToday
        self.recentHealth = recentHealth
        self.lastAudioAtUTC = lastAudioAtUTC
    }
}

/// The shadow capture pipeline state machine. Maps monitor/capture/VAD/writer events to
/// persisted `HealthEvent`s, performs state transitions, and publishes snapshots.
public protocol ShadowCaptureControlling: Sendable {
    var snapshots: AsyncStream<PipelineSnapshot> { get }
    func start() async
    func handle(_ event: MonitorEvent) async
    func pause(untilUTC: Date?) async
    func resume() async
    func shutdown() async
}
