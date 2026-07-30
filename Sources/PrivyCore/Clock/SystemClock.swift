import Foundation

// The production `PrivyClock`. Wraps `ContinuousClock` (which advances across system
// sleep) for monotonic durations and chunk offsets; `Date` is only the UTC anchor.
// See docs/m1/plan.md ("Time").

/// A `PrivyClock` backed by `ContinuousClock` with a per-process `clockEpoch`.
///
/// Genuine `Sendable`: a value type whose stored properties (`UUID`,
/// `ContinuousClock.Instant`) are all `Sendable` and immutable. No `@unchecked Sendable`
/// is required or used here — that blessing is reserved for the synchronized
/// `MonitorEventStream` wrapper and W3's `RealtimeAudioRing`.
public struct SystemClock: PrivyClock {
    /// Unique per `SystemClock` instance. Tags every `ClockReading` this clock produces so
    /// cross-epoch subtraction can be refused.
    public let epoch: UUID

    /// The `ContinuousClock` instant captured at init; `now()` measures elapsed time
    /// from it. `ContinuousClock` advances across system sleep.
    private let origin: ContinuousClock.Instant

    public init(epoch: UUID = UUID()) {
        self.epoch = epoch
        self.origin = ContinuousClock().now
    }

    public func now() -> ClockReading {
        // `Duration` exposes (seconds, attoseconds) components rather than a Double, so
        // combine them into fractional seconds for the monotonic timeline.
        let elapsed = (ContinuousClock().now - origin).components
        let monotonicSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
        return ClockReading(
            wallUTC: Date(),
            monotonicSeconds: monotonicSeconds,
            clockEpoch: epoch
        )
    }

    public func elapsedSeconds(from: ClockReading, to: ClockReading) -> Double {
        // Wall time is never used for duration math within a clock epoch. Readings from
        // different epochs are refused (return zero) rather than subtracted.
        guard from.clockEpoch == to.clockEpoch else { return .zero }
        return to.monotonicSeconds - from.monotonicSeconds
    }
}
