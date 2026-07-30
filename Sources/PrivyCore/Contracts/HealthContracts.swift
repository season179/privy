import Foundation

// Cross-worker monitor + health contract. W1 owns the declaration (including the monitor
// abstraction) and the monitor implementations; W4's pipeline consumes `MonitorEvent`
// and persists `HealthEvent`s. See docs/m1/plan.md ("Monitor, health, and pipeline
// state").

// MARK: - Monitor events

/// A system-level event observed outside the capture engine. Monitor implementations
/// detect and emit these only; they never restart capture or write health rows.
public enum MonitorEvent: Sendable, Equatable {
    case willSleep(ClockReading)
    case didWake(ClockReading)
    case defaultInputChanged(ClockReading, deviceUID: String?)
    case deviceListChanged(ClockReading)
}

/// A system monitor: sleep/wake and CoreAudio device activity. `events` is consumed by
/// the pipeline; `start`/`stop` are lifecycle hooks.
public protocol SystemMonitoring: Sendable {
    var events: AsyncStream<MonitorEvent> { get }
    func start() async throws
    func stop() async
}

// MARK: - Health

/// The kind of structured health row persisted in the `health` table. Each maps to a
/// real lifecycle/fault mode the pipeline must represent truthfully.
public enum HealthKind: String, Sendable, Codable {
    case startup, recordingStarted, recordingStopped, sleep, wake, deviceChange
    case engineRestart, queueOverrun, gap, vadPreparing, vadReady, vadGap, vadError
    case writerError, clockDiscontinuity, recovery, error
}

public enum HealthSeverity: String, Sendable, Codable { case info, warning, error }

/// Structured detail payload persisted as the body of one `health.detail` JSON value.
/// Fields are optional on purpose: most events populate only a subset.
public struct HealthDetail: Sendable, Codable, Equatable {
    public let message: String
    public let clockEpoch: UUID?
    public let monotonicSeconds: Double?
    public let gapStartedUTC: Date?
    public let gapEndedUTC: Date?
    public let durationSeconds: Double?
    public let deviceUID: String?
    public let droppedFrames: Int64?
    /// `true` when `durationSeconds` was estimated from UTC (cross-process recovery)
    /// rather than measured from monotonic time within one epoch.
    public let durationIsEstimated: Bool

    public init(
        message: String,
        clockEpoch: UUID? = nil,
        monotonicSeconds: Double? = nil,
        gapStartedUTC: Date? = nil,
        gapEndedUTC: Date? = nil,
        durationSeconds: Double? = nil,
        deviceUID: String? = nil,
        droppedFrames: Int64? = nil,
        durationIsEstimated: Bool = false
    ) {
        self.message = message
        self.clockEpoch = clockEpoch
        self.monotonicSeconds = monotonicSeconds
        self.gapStartedUTC = gapStartedUTC
        self.gapEndedUTC = gapEndedUTC
        self.durationSeconds = durationSeconds
        self.deviceUID = deviceUID
        self.droppedFrames = droppedFrames
        self.durationIsEstimated = durationIsEstimated
    }
}

/// The exact JSON object persisted in the `health.detail` column:
/// `{"severity":"info|warning|error","detail":{...HealthDetail fields...}}`.
/// `appendHealth` constructs it from a `HealthEvent`; every health read decodes it and
/// restores both top-level fields. Unknown/malformed envelopes fail decoding visibly.
public struct HealthEnvelope: Sendable, Codable, Equatable {
    public let severity: HealthSeverity
    public let detail: HealthDetail

    public init(severity: HealthSeverity, detail: HealthDetail) {
        self.severity = severity
        self.detail = detail
    }
}

/// An in-memory health event. The `kind`/`atUTC` columns plus the `detail` JSON envelope
/// fully reconstruct this on read.
public struct HealthEvent: Sendable, Equatable {
    public let atUTC: Date
    public let kind: HealthKind
    public let severity: HealthSeverity
    public let detail: HealthDetail

    public init(atUTC: Date, kind: HealthKind, severity: HealthSeverity, detail: HealthDetail) {
        self.atUTC = atUTC
        self.kind = kind
        self.severity = severity
        self.detail = detail
    }
}
