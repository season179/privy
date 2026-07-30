import Foundation

// Cross-worker clock contract. W1 owns the declaration; W2–W4 implement against it
// without widening or renaming. See docs/m1/plan.md ("Time").

/// A single point-in-time reading from a `PrivyClock`.
///
/// Durations and chunk offsets are derived from `monotonicSeconds`; `wallUTC` is only the
/// UTC anchor used for display and absolute timestamps. Values carrying different
/// `clockEpoch` values must never be subtracted: cross-process reconciliation uses UTC
/// plus an explicit startup/recovery health event instead.
public struct ClockReading: Sendable, Equatable {
    /// UTC wall-clock anchor at the moment of the reading.
    public let wallUTC: Date

    /// Seconds from this clock instance's `ContinuousClock` origin. Used for all
    /// intra-epoch duration math.
    public let monotonicSeconds: Double

    /// Changes only when the app process creates a new `SystemClock`. Readings from
    /// different epochs cannot be meaningfully subtracted.
    public let clockEpoch: UUID

    public init(wallUTC: Date, monotonicSeconds: Double, clockEpoch: UUID) {
        self.wallUTC = wallUTC
        self.monotonicSeconds = monotonicSeconds
        self.clockEpoch = clockEpoch
    }
}

/// A clock that produces `ClockReading` values and computes intra-epoch durations.
///
/// `Sendable` so conformers (production `SystemClock`, test fakes) can be captured safely
/// by `@Sendable` monitor callbacks.
public protocol PrivyClock: Sendable {
    func now() -> ClockReading
    /// Returns `to.monotonicSeconds - from.monotonicSeconds` when both readings share an
    /// epoch. The result is undefined-to-refused for readings from different epochs;
    /// conformers return a safe zero rather than performing the subtraction.
    func elapsedSeconds(from: ClockReading, to: ClockReading) -> Double
}
