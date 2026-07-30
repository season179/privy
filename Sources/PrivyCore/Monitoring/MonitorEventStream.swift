import Foundation
import os.lock

// Thread-safe, bounded emitter for `MonitorEvent` values. This is the one `@unchecked
// Sendable` wrapper blessed by docs/m1/plan.md for W1. NSWorkspace and CoreAudio deliver
// notifications on arbitrary queues/threads; `AsyncStream.Continuation` is not `Sendable`,
// so this wrapper serializes every yield/finish through an `os_unfair_lock` and gives
// monitor callbacks a single `@Sendable` value they can capture without crossing actor
// isolation or blocking the realtime path.

/// Synchronized bridge between non-`Sendable` notification callbacks and the pipeline's
/// `AsyncStream<MonitorEvent>` consumer.
///
/// Safety proof for `@unchecked Sendable`:
/// - `continuation` is read/written only while holding `unfairLock`.
/// - `unfairLock` is an `os_unfair_lock_s` stored in this heap-allocated instance; its
///   address is stable for the instance lifetime and every access is bracketed by
///   `os_unfair_lock_lock`/`os_unfair_lock_unlock`. The instance is never copied.
/// - `stream` and `clock` are immutable `let`s published at init; both are `Sendable`.
public final class MonitorEventStream: @unchecked Sendable {
    /// The bounded stream consumed by the pipeline. Newest events displace oldest when the
    /// consumer lags, so a stalled pipeline never blocks a notification callback.
    public let stream: AsyncStream<MonitorEvent>

    private let clock: any PrivyClock
    private var continuation: AsyncStream<MonitorEvent>.Continuation?
    private var unfairLock = os_unfair_lock_s()

    public init(
        clock: any PrivyClock,
        bufferingPolicy: AsyncStream<MonitorEvent>.Continuation.BufferingPolicy = .bufferingNewest(256)
    ) {
        self.clock = clock
        var captured: AsyncStream<MonitorEvent>.Continuation!
        self.stream = AsyncStream(
            MonitorEvent.self,
            bufferingPolicy: bufferingPolicy
        ) { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    // MARK: - Low-level emit

    /// Emits a fully-formed event. Safe to call from any thread.
    public func emit(_ event: MonitorEvent) {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        continuation?.yield(event)
    }

    /// A fresh `ClockReading` from the stream's clock. Safe to call from any thread.
    public func nowReading() -> ClockReading {
        clock.now()
    }

    // MARK: - Timestamped convenience emissions
    // For use by `@Sendable` monitor callbacks that capture only this emitter: they need
    // not also capture the clock in order to stamp a `ClockReading`.

    public func emitWillSleep() { emit(.willSleep(clock.now())) }
    public func emitDidWake() { emit(.didWake(clock.now())) }
    public func emitDefaultInputChanged(deviceUID: String?) {
        emit(.defaultInputChanged(clock.now(), deviceUID: deviceUID))
    }
    public func emitDeviceListChanged() { emit(.deviceListChanged(clock.now())) }

    // MARK: - Teardown

    /// Stops accepting events and terminates the stream for consumers. Idempotent.
    public func finish() {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        continuation?.finish()
        continuation = nil
    }
}
