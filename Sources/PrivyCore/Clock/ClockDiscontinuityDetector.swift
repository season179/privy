import Foundation

// Detects wall-clock discontinuities (NTP corrections, DST jumps, manual changes) by
// comparing the wall delta against the monotonic delta within one clock epoch. Emits a
// `.clockDiscontinuity` signal (consumed by W4's pipeline to build a `HealthEvent`)
// when the drift exceeds 1 second. See docs/m1/plan.md ("Time").

/// Pure, `Sendable` discontinuity detector.
///
/// Stateless across calls: the caller (pipeline) supplies the two consecutive
/// `ClockReading` values it wants compared. This avoids any mutable/locked state here,
/// keeping the detector off the `@unchecked Sendable` list.
public struct ClockDiscontinuityDetector: Sendable {
    /// Drift (wall − monotonic, in seconds) beyond which a discontinuity is signalled.
    public static let defaultThreshold: Double = 1.0

    public let threshold: Double

    public init(threshold: Double = ClockDiscontinuityDetector.defaultThreshold) {
        self.threshold = threshold
    }

    /// Returns the signed wall-minus-monotonic drift (seconds) when a discontinuity is
    /// detected between two same-epoch readings; `nil` otherwise.
    ///
    /// - Positive drift ⇒ the wall clock jumped forward (e.g. NTP catch-up, manual bump).
    /// - Negative drift ⇒ the wall clock jumped backward (e.g. DST rollback).
    /// - Cross-epoch pairs return `nil`: an epoch change is not a clock discontinuity and
    ///   is represented by a separate startup/recovery health event.
    public func drift(from: ClockReading, to: ClockReading) -> Double? {
        guard from.clockEpoch == to.clockEpoch else { return nil }
        let wallDelta = to.wallUTC.timeIntervalSince(from.wallUTC)
        let monoDelta = to.monotonicSeconds - from.monotonicSeconds
        let drift = wallDelta - monoDelta
        return abs(drift) > threshold ? drift : nil
    }
}
