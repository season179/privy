import Testing
import Foundation
@testable import PrivyCore

// W1 acceptance tests: contracts support fakes, the clock behaves under normal/sleep/jump
// and cross-epoch conditions, and monitors emit/coalesce events without AppKit UI or
// CoreAudio hardware. See docs/m1/plan.md ("W1 — Acceptance criteria").

// MARK: - Test doubles

/// Lock-protected fake clock injected from the test target (per the plan's discipline).
/// A class so the same instance can be shared across the test thread and the monitor
/// task; `@unchecked Sendable` is the test-side lock wrapper (production clocks are
/// genuine Sendable values).
final class TestClock: PrivyClock, @unchecked Sendable {
    private let epoch: UUID
    private let lock = NSLock()
    private var wall: Date
    private var mono: Double

    init(
        epoch: UUID = UUID(),
        wall: Date = Date(timeIntervalSince1970: 1_700_000_000),
        mono: Double = 0
    ) {
        self.epoch = epoch
        self.wall = wall
        self.mono = mono
    }

    func now() -> ClockReading {
        lock.lock(); defer { lock.unlock() }
        return ClockReading(wallUTC: wall, monotonicSeconds: mono, clockEpoch: epoch)
    }

    /// Normal time passage: both wall and monotonic advance together.
    @discardableResult
    func advance(seconds: Double) -> Self {
        lock.lock(); defer { lock.unlock() }
        wall = wall.addingTimeInterval(seconds)
        mono += seconds
        return self
    }

    /// Sleep-like passage: identical to `advance`, because `ContinuousClock` keeps
    /// counting across system sleep. Used to model a lid-close interval.
    @discardableResult
    func advanceLikeSleep(seconds: Double) -> Self { advance(seconds: seconds) }

    /// Wall clock jumps (NTP correction, DST, manual change) while monotonic time is
    /// unaffected. Models req 3 (clocks).
    @discardableResult
    func jumpWall(by seconds: Double) -> Self {
        lock.lock(); defer { lock.unlock() }
        wall = wall.addingTimeInterval(seconds)
        return self
    }

    func elapsedSeconds(from: ClockReading, to: ClockReading) -> Double {
        guard from.clockEpoch == to.clockEpoch else { return .zero }
        return to.monotonicSeconds - from.monotonicSeconds
    }
}

/// Thread-safe collector for `MonitorEvent` values drained from an `AsyncStream`.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MonitorEvent] = []

    func append(_ event: MonitorEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    func snapshot() -> [MonitorEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private extension [MonitorEvent] {
    var deviceListCount: Int { filter { if case .deviceListChanged = $0 { return true }; return false }.count }
    var defaultInputUIDs: [String?] { compactMap { event -> String? in
        if case .defaultInputChanged(_, let uid) = event { return uid }
        return nil
    } }
}

// MARK: - SystemClock + PrivyClock

@Suite struct ClockAndMonitorTests {

    @Test func systemClockProducesIncreasingMonotonicReadingsInOneEpoch() {
        let clock = SystemClock()
        let a = clock.now()
        // A small real-time nudge so the two readings are not necessarily identical.
        Thread.sleep(forTimeInterval: 0.001)
        let b = clock.now()
        #expect(a.clockEpoch == b.clockEpoch)
        #expect(b.monotonicSeconds >= a.monotonicSeconds)
        #expect(clock.elapsedSeconds(from: a, to: b) >= 0)
    }

    @Test func systemClockWallAndMonotonicBothAdvance() {
        let clock = SystemClock()
        let a = clock.now()
        Thread.sleep(forTimeInterval: 0.02)
        let b = clock.now()
        // Wall delta and monotonic delta should agree within the discontinuity threshold.
        let wallDelta = b.wallUTC.timeIntervalSince(a.wallUTC)
        let monoDelta = clock.elapsedSeconds(from: a, to: b)
        #expect(monoDelta > 0)
        #expect(abs(wallDelta - monoDelta) < 1.0)
    }

    // MARK: Fake-clock coverage (normal / sleep-like / wall jump / cross-epoch refusal)

    @Test func fakeClockNormalAdvance() {
        let clock = TestClock()
        let a = clock.now()
        clock.advance(seconds: 5)
        let b = clock.now()
        #expect(clock.elapsedSeconds(from: a, to: b) == 5)
        #expect(b.wallUTC.timeIntervalSince(a.wallUTC) == 5)
    }

    @Test func fakeClockSleepLikeAdvanceCountsAsDuration() {
        // ContinuousClock advances across sleep: a 2-minute sleep contributes 120s to
        // the monotonic timeline, so it is represented as elapsed time (not a gap to be
        // discovered by the watchdog — the engine is independently stopped during sleep).
        let clock = TestClock()
        let before = clock.now()
        clock.advanceLikeSleep(seconds: 120)
        let after = clock.now()
        #expect(clock.elapsedSeconds(from: before, to: after) == 120)
        #expect(after.wallUTC.timeIntervalSince(before.wallUTC) == 120)
    }

    @Test func fakeClockWallJumpDoesNotAffectMonotonicDuration() {
        // NTP/DST/manual wall jump must not corrupt durations: derive from monotonic only.
        let clock = TestClock()
        let a = clock.now()
        clock.advance(seconds: 3)
        clock.jumpWall(by: 3600) // wall jumps an hour
        let b = clock.now()
        #expect(clock.elapsedSeconds(from: a, to: b) == 3)
        // The wall delta reflects the jump; the monotonic delta does not.
        #expect(b.wallUTC.timeIntervalSince(a.wallUTC) == 3 + 3600)
        #expect(b.monotonicSeconds - a.monotonicSeconds == 3)
    }

    @Test func crossEpochSubtractionIsRefused() {
        let clockA = TestClock(epoch: UUID())
        let clockB = TestClock(epoch: UUID())
        let a = clockA.now()
        clockB.advance(seconds: 10)
        let b = clockB.now()
        // Different epochs: refused (zero), never the naive 10.
        #expect(clockA.elapsedSeconds(from: a, to: b) == 0)
        #expect(a.clockEpoch != b.clockEpoch)
    }

    @Test func sameReadingEpochSubtractsNormally() {
        let clock = TestClock()
        let a = clock.now()
        clock.advance(seconds: 7)
        let b = clock.now()
        // Same epoch as each other (and as the producing clock) subtracts fine.
        #expect(clock.elapsedSeconds(from: a, to: b) == 7)
    }

    // MARK: ClockDiscontinuityDetector

    @Test func discontinuityDetectsForwardWallJump() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000),
                                monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1360),
                              monotonicSeconds: 10, clockEpoch: epoch)
        // wall delta 360 − mono delta 10 = +350s drift → discontinuity.
        let drift = detector.drift(from: from, to: to)
        #expect(drift != nil)
        #expect((drift ?? 0) > 1)
    }

    @Test func discontinuityDetectsBackwardWallJump() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 2000),
                                monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1540), // DST rollback
                              monotonicSeconds: 60, clockEpoch: epoch)
        let drift = detector.drift(from: from, to: to)
        #expect(drift != nil)
        #expect((drift ?? 0) < 0) // negative drift for a backward jump
    }

    @Test func discontinuityWithinThresholdIsNil() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000),
                                monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1010.4),
                              monotonicSeconds: 10, clockEpoch: epoch)
        // drift 0.4s < 1s threshold → not a discontinuity.
        #expect(detector.drift(from: from, to: to) == nil)
    }

    @Test func discontinuityThresholdIsConfigurable() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector(threshold: 0.1)
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000),
                                monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1010.4),
                              monotonicSeconds: 10, clockEpoch: epoch)
        // Same 0.4s drift now exceeds the tighter threshold.
        #expect(detector.drift(from: from, to: to) != nil)
    }

    @Test func discontinuityCrossEpochReturnsNil() {
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000),
                                monotonicSeconds: 0, clockEpoch: UUID())
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 9000),
                              monotonicSeconds: 0, clockEpoch: UUID())
        // An epoch change is represented by a separate startup/recovery health event,
        // not by a clock discontinuity.
        #expect(detector.drift(from: from, to: to) == nil)
    }

    // MARK: MonitorEventStream ordering + teardown

    @Test func monitorEventStreamPreservesEmissionOrder() async {
        let clock = TestClock()
        let stream = MonitorEventStream(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in stream.stream { collector.append(event) } }

        stream.emitWillSleep()
        clock.advance(seconds: 1)
        stream.emitDidWake()
        clock.advance(seconds: 1)
        stream.emitDeviceListChanged()

        // Let the consumer task drain before terminating the stream.
        try? await Task.sleep(for: .milliseconds(50))
        stream.finish()
        _ = await task.value

        let events = collector.snapshot()
        #expect(events.count == 3)
        if events.count > 0 { switch events[0] { case .willSleep: break; default: Issue.record("expected willSleep first") } }
        if events.count > 1 { switch events[1] { case .didWake: break; default: Issue.record("expected didWake second") } }
        if events.count > 2 { switch events[2] { case .deviceListChanged: break; default: Issue.record("expected deviceListChanged third") } }
    }

    @Test func monitorEventStreamFinishTerminatesConsumer() async {
        let clock = TestClock()
        let stream = MonitorEventStream(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in stream.stream { collector.append(event) } }

        stream.emitDeviceListChanged()
        stream.finish()
        _ = await task.value // exits because the stream terminated

        #expect(collector.snapshot().count == 1)
    }

    @Test func monitorEventStreamFinishIsIdempotent() {
        let clock = TestClock()
        let stream = MonitorEventStream(clock: clock)
        stream.finish()
        stream.finish() // must not crash
        // Emitting after finish is a no-op.
        stream.emitDeviceListChanged()
    }

    // MARK: AudioDeviceMonitor coalescing + ordering (no CoreAudio/AppKit)

    @Test func audioDeviceMonitorDefaultDebounceIs500ms() {
        #expect(AudioDeviceMonitor.defaultDebounceWindow == .milliseconds(500))
    }

    @Test func audioDeviceMonitorCoalescesSingleKindBurstViaFlush() async {
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        for _ in 0..<6 { await monitor.injectDeviceListChanged() }
        await monitor.stop() // flushNow emits the one coalesced event, then finishes
        _ = await task.value

        let events = collector.snapshot()
        #expect(events.count == 1)
        #expect(events.deviceListCount == 1)
    }

    @Test func audioDeviceMonitorCoalescesMixedBurstInOrder() async {
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        await monitor.injectDefaultInputChanged(deviceUID: "devA")
        await monitor.injectDeviceListChanged()
        await monitor.injectDeviceListChanged()
        await monitor.injectDefaultInputChanged(deviceUID: "devB")
        await monitor.stop()
        _ = await task.value

        let events = collector.snapshot()
        // One defaultInputChanged (latest UID wins) + one deviceListChanged, in that order.
        #expect(events.count == 2)
        #expect(events.defaultInputUIDs == ["devB"])
        #expect(events.deviceListCount == 1)
        guard case .defaultInputChanged = events.first else {
            Issue.record("expected defaultInputChanged to be emitted first"); return
        }
        guard case .deviceListChanged = events.last else {
            Issue.record("expected deviceListChanged to be emitted second"); return
        }
    }

    @Test func audioDeviceMonitorTrailingDebounceFiresOnceAfterWindow() async {
        // Proves the timer-driven trailing debounce (not just flushNow) collapses a burst.
        // Uses a small window so the test is fast; the production default is asserted above.
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock, debounceWindow: .milliseconds(60))
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        for _ in 0..<5 { await monitor.injectDeviceListChanged() }
        // Wait well past the 60ms window so the trailing flush has fired.
        try? await Task.sleep(for: .milliseconds(300))

        let deviceListCount = collector.snapshot().deviceListCount
        #expect(deviceListCount == 1)

        await monitor.stop()
        _ = await task.value
    }

    @Test func audioDeviceMonitorSeparateBurstsEmitSeparately() async {
        // Two bursts separated by more than the window produce two coalesced events.
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock, debounceWindow: .milliseconds(60))
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        await monitor.injectDeviceListChanged()
        try? await Task.sleep(for: .milliseconds(200)) // burst 1 flushes
        await monitor.injectDeviceListChanged()
        await monitor.injectDeviceListChanged()
        try? await Task.sleep(for: .milliseconds(200)) // burst 2 flushes

        #expect(collector.snapshot().deviceListCount == 2)

        await monitor.stop()
        _ = await task.value
    }
}
