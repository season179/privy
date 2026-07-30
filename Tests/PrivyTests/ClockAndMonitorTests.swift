import Testing
import Foundation
import AppKit
import CoreAudio
@testable import PrivyCore

// W1 acceptance tests: contracts support fakes, the clock behaves under normal/sleep/jump
// and cross-epoch conditions, and monitors emit/coalesce events. The monitor tests drive
// the REAL lifecycle (start, raw callback path, UID enrichment, stop removal, post-stop
// silence, registration-failure rollback) through injected notification/CoreAudio adapters,
// with no AppKit UI or CoreAudio hardware. See docs/m1/plan.md ("W1 — Acceptance criteria").

// MARK: - Test doubles

/// Lock-protected fake clock injected from the test target (per the plan's discipline).
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
    /// counting across system sleep.
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
}

// MARK: - Fake registrars / adapters for monitor lifecycle tests

/// Captures sleep/wake handlers and posts synthetic notifications, so `SleepWakeMonitor`
/// lifecycle (registration, order/timestamps, removal, idempotence, post-stop silence) is
/// testable without AppKit UI.
actor FakeSleepWakeRegistrar: SleepWakeRegistrar {
    private var sleep: (@Sendable (Notification) -> Void)?
    private var wake: (@Sendable (Notification) -> Void)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register(
        sleep: @Sendable @escaping (Notification) -> Void,
        wake: @Sendable @escaping (Notification) -> Void
    ) async {
        registerCount += 1
        self.sleep = sleep
        self.wake = wake
    }

    func unregister() async {
        unregisterCount += 1
        self.sleep = nil
        self.wake = nil
    }

    func postSleep() async { sleep?(Notification(name: NSWorkspace.willSleepNotification)) }
    func postWake() async { wake?(Notification(name: NSWorkspace.didWakeNotification)) }
}

/// Captures CoreAudio property-listener registrations so tests can drive the real raw
/// callback path (the `@convention(c)` procs) through the monitor, query/resolve a fake
/// device UID, and simulate `addPropertyListener` failures to exercise rollback.
final class FakeAudioHardwareAdapter: AudioHardwareAdapter, @unchecked Sendable {
    private struct Captured {
        let object: AudioObjectID
        let property: AudioObjectPropertyAddress
        let proc: AudioObjectPropertyListenerProc
        let clientData: UnsafeMutableRawPointer?
    }

    private let lock = NSLock()
    private var captured: [Captured] = []
    private var failOnAdd: Set<Int> = []
    private var addIndex = 0
    private var removeCount = 0
    private var uid: String?

    func setFailOnAdd(at index: Int) {
        lock.lock(); defer { lock.unlock() }
        failOnAdd.insert(index)
    }
    func setDefaultInputUID(_ uid: String?) {
        lock.lock(); defer { lock.unlock() }
        self.uid = uid
    }
    var removeCountSnapshot: Int { lock.lock(); defer { lock.unlock() }; return removeCount }
    var capturedCount: Int { lock.lock(); defer { lock.unlock() }; return captured.count }

    func addPropertyListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        listener: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if failOnAdd.contains(addIndex) {
            addIndex += 1
            return -1
        }
        captured.append(Captured(object: object, property: property, proc: listener, clientData: clientData))
        addIndex += 1
        return noErr
    }

    func removePropertyListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        listener: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        removeCount += 1
        // Identify the listener by object + property selector (the proc is a function
        // pointer and not needed to disambiguate the two registrations).
        captured.removeAll { $0.object == object && $0.property.mSelector == property.mSelector }
        return noErr
    }

    func currentDefaultInputDeviceUID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return uid
    }

    // MARK: raw callback simulation (invokes the captured @convention(c) proc)

    func simulateDeviceListChanged() {
        invoke(selector: kAudioHardwarePropertyDevices)
    }
    func simulateDefaultInputChanged() {
        invoke(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func invoke(selector: AudioObjectPropertySelector) {
        lock.lock()
        let entry = captured.first { $0.property.mSelector == selector }
        lock.unlock()
        guard let entry else { return }
        var address = entry.property
        withUnsafePointer(to: &address) { ptr in
            _ = entry.proc(entry.object, 1, ptr, entry.clientData)
        }
    }
}

// MARK: - SystemClock + PrivyClock

@Suite struct ClockAndMonitorTests {

    @Test func systemClockProducesIncreasingMonotonicReadingsInOneEpoch() {
        let clock = SystemClock()
        let a = clock.now()
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
        let clock = TestClock()
        let before = clock.now()
        clock.advanceLikeSleep(seconds: 120)
        let after = clock.now()
        #expect(clock.elapsedSeconds(from: before, to: after) == 120)
        #expect(after.wallUTC.timeIntervalSince(before.wallUTC) == 120)
    }

    @Test func fakeClockWallJumpDoesNotAffectMonotonicDuration() {
        let clock = TestClock()
        let a = clock.now()
        clock.advance(seconds: 3)
        clock.jumpWall(by: 3600)
        let b = clock.now()
        #expect(clock.elapsedSeconds(from: a, to: b) == 3)
        #expect(b.wallUTC.timeIntervalSince(a.wallUTC) == 3 + 3600)
        #expect(b.monotonicSeconds - a.monotonicSeconds == 3)
    }

    @Test func crossEpochSubtractionIsRefused() {
        let clockA = TestClock(epoch: UUID())
        let clockB = TestClock(epoch: UUID())
        let a = clockA.now()
        clockB.advance(seconds: 10)
        let b = clockB.now()
        #expect(clockA.elapsedSeconds(from: a, to: b) == 0)
        #expect(a.clockEpoch != b.clockEpoch)
    }

    @Test func sameReadingEpochSubtractsNormally() {
        let clock = TestClock()
        let a = clock.now()
        clock.advance(seconds: 7)
        let b = clock.now()
        #expect(clock.elapsedSeconds(from: a, to: b) == 7)
    }

    // MARK: ClockDiscontinuityDetector

    @Test func discontinuityDetectsForwardWallJump() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000), monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1360), monotonicSeconds: 10, clockEpoch: epoch)
        let drift = detector.drift(from: from, to: to)
        #expect(drift != nil)
        #expect((drift ?? 0) > 1)
    }

    @Test func discontinuityDetectsBackwardWallJump() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 2000), monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1540), monotonicSeconds: 60, clockEpoch: epoch)
        let drift = detector.drift(from: from, to: to)
        #expect(drift != nil)
        #expect((drift ?? 0) < 0)
    }

    @Test func discontinuityWithinThresholdIsNil() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000), monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1010.4), monotonicSeconds: 10, clockEpoch: epoch)
        #expect(detector.drift(from: from, to: to) == nil)
    }

    @Test func discontinuityThresholdIsConfigurable() {
        let epoch = UUID()
        let detector = ClockDiscontinuityDetector(threshold: 0.1)
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000), monotonicSeconds: 0, clockEpoch: epoch)
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 1010.4), monotonicSeconds: 10, clockEpoch: epoch)
        #expect(detector.drift(from: from, to: to) != nil)
    }

    @Test func discontinuityCrossEpochReturnsNil() {
        let detector = ClockDiscontinuityDetector()
        let from = ClockReading(wallUTC: Date(timeIntervalSince1970: 1000), monotonicSeconds: 0, clockEpoch: UUID())
        let to = ClockReading(wallUTC: Date(timeIntervalSince1970: 9000), monotonicSeconds: 0, clockEpoch: UUID())
        #expect(detector.drift(from: from, to: to) == nil)
    }

    // MARK: MonitorEventStream ordering, teardown, and no-silent-discard

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

        try? await Task.sleep(for: .milliseconds(30))
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
        _ = await task.value

        #expect(collector.snapshot().count == 1)
    }

    @Test func monitorEventStreamFinishIsIdempotent() {
        let clock = TestClock()
        let stream = MonitorEventStream(clock: clock)
        stream.finish()
        stream.finish()
        stream.emitDeviceListChanged()
    }

    @Test func monitorEventStreamIsUnboundedAndLossless() async {
        // W1's no-silent-discard constraint: the default unbounded policy must never evict
        // a sleep/wake/device event, however many pile up before the consumer drains them.
        let clock = TestClock()
        let stream = MonitorEventStream(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in stream.stream { collector.append(event) } }

        let n = 1000
        for _ in 0..<n { stream.emitDeviceListChanged() }
        try? await Task.sleep(for: .milliseconds(100))
        stream.finish()
        _ = await task.value

        #expect(collector.snapshot().count == n)
    }

    // MARK: SleepWakeMonitor lifecycle (no AppKit UI)

    @Test func sleepWakeMonitorRegistersEmitsInOrderAndRemoves() async throws {
        let clock = TestClock()
        let registrar = FakeSleepWakeRegistrar()
        let monitor = SleepWakeMonitor(clock: clock, registrar: registrar)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        try await monitor.start()
        #expect(await registrar.registerCount == 1)
        // Idempotent start: a second start must not re-register.
        try await monitor.start()
        #expect(await registrar.registerCount == 1)

        clock.advance(seconds: 5)
        await registrar.postSleep()
        clock.advance(seconds: 3)
        await registrar.postWake()

        try? await Task.sleep(for: .milliseconds(30))
        await monitor.stop()
        #expect(await registrar.unregisterCount == 1)
        _ = await task.value

        let events = collector.snapshot()
        #expect(events.count == 2)
        guard case .willSleep(let r1) = events[0] else { Issue.record("expected willSleep first"); return }
        guard case .didWake(let r2) = events[1] else { Issue.record("expected didWake second"); return }
        #expect(r2.monotonicSeconds > r1.monotonicSeconds)
    }

    @Test func sleepWakeMonitorIsSilentAfterStop() async throws {
        let clock = TestClock()
        let registrar = FakeSleepWakeRegistrar()
        let monitor = SleepWakeMonitor(clock: clock, registrar: registrar)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        try await monitor.start()
        await monitor.stop()
        // Handlers are unregistered; posting must produce no event.
        await registrar.postSleep()
        await registrar.postWake()
        try? await Task.sleep(for: .milliseconds(30))
        _ = await task.value

        #expect(collector.snapshot().isEmpty)
    }

    // MARK: AudioDeviceMonitor coalescing + ordering

    @Test func audioDeviceMonitorDefaultDebounceIs500ms() {
        #expect(AudioDeviceMonitor.defaultDebounceWindow == .milliseconds(500))
    }

    @Test func audioDeviceMonitorEmitsOneEventPerWindowPreferringDefaultInput() async {
        // Orchestrator decision: exactly one event per window. When both default-input and
        // device-list changed, prefer .defaultInputChanged(latestUID); otherwise
        // .deviceListChanged.
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        await monitor.injectDefaultInputChanged(deviceUID: "devA")
        await monitor.injectDeviceListChanged()
        await monitor.injectDeviceListChanged()
        await monitor.injectDefaultInputChanged(deviceUID: "devB")
        await monitor.stop() // flushNow emits exactly one coalesced event
        _ = await task.value

        let events = collector.snapshot()
        #expect(events.count == 1)
        guard case .defaultInputChanged(_, let uid) = events[0] else {
            Issue.record("expected a single defaultInputChanged carrying the latest UID"); return
        }
        #expect(uid == "devB")
    }

    @Test func audioDeviceMonitorEmitsDeviceListWhenNoDefaultInputSignal() async {
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        for _ in 0..<6 { await monitor.injectDeviceListChanged() }
        await monitor.stop()
        _ = await task.value

        let events = collector.snapshot()
        #expect(events.count == 1)
        #expect(events.deviceListCount == 1)
    }

    @Test func audioDeviceMonitorTrailingDebounceFiresOnceAfterWindow() async {
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock, debounceWindow: .milliseconds(60))
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        for _ in 0..<5 { await monitor.injectDeviceListChanged() }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(collector.snapshot().deviceListCount == 1)

        await monitor.stop()
        _ = await task.value
    }

    @Test func audioDeviceMonitorSeparateBurstsEmitSeparately() async {
        let clock = TestClock()
        let monitor = AudioDeviceMonitor(clock: clock, debounceWindow: .milliseconds(60))
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        await monitor.injectDeviceListChanged()
        try? await Task.sleep(for: .milliseconds(200))
        await monitor.injectDeviceListChanged()
        await monitor.injectDeviceListChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(collector.snapshot().deviceListCount == 2)

        await monitor.stop()
        _ = await task.value
    }

    // MARK: AudioDeviceMonitor real lifecycle (injected CoreAudio adapter)

    @Test func audioDeviceMonitorLifecycleDeliversRawDeviceListSignal() async throws {
        let clock = TestClock()
        let adapter = FakeAudioHardwareAdapter()
        let monitor = AudioDeviceMonitor(clock: clock, debounceWindow: .milliseconds(60), adapter: adapter)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        try await monitor.start()
        #expect(adapter.capturedCount == 2) // devices + defaultInput registered

        // Drive the captured @convention(c) proc through the raw path: proc -> rawEmitter
        // -> forwarder -> debouncer -> publishedEmitter.
        adapter.simulateDeviceListChanged()
        adapter.simulateDeviceListChanged()
        try? await Task.sleep(for: .milliseconds(250)) // forward + 60ms debounce + emit

        #expect(collector.snapshot().deviceListCount == 1)

        await monitor.stop()
        #expect(adapter.removeCountSnapshot == 2)
        _ = await task.value
    }

    @Test func audioDeviceMonitorEnrichesDefaultInputWithUID() async throws {
        let clock = TestClock()
        let adapter = FakeAudioHardwareAdapter()
        adapter.setDefaultInputUID("BuiltInMic-42")
        let monitor = AudioDeviceMonitor(clock: clock, debounceWindow: .milliseconds(60), adapter: adapter)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        try await monitor.start()
        adapter.simulateDefaultInputChanged()
        try? await Task.sleep(for: .milliseconds(250))

        let events = collector.snapshot()
        #expect(events.count == 1)
        guard case .defaultInputChanged(_, let uid) = events[0] else {
            Issue.record("expected defaultInputChanged"); return
        }
        #expect(uid == "BuiltInMic-42")

        await monitor.stop()
        _ = await task.value
    }

    @Test func audioDeviceMonitorIsSilentAfterStop() async throws {
        let clock = TestClock()
        let adapter = FakeAudioHardwareAdapter()
        let monitor = AudioDeviceMonitor(clock: clock, adapter: adapter)
        let collector = EventCollector()
        let task = Task { for await event in monitor.events { collector.append(event) } }

        try await monitor.start()
        adapter.simulateDeviceListChanged()
        await monitor.stop()

        let before = collector.snapshot().count
        // No listener remains (captured procs removed) and the published stream is
        // finished, so simulating after stop must produce no new event.
        adapter.simulateDeviceListChanged()
        adapter.simulateDefaultInputChanged()
        try? await Task.sleep(for: .milliseconds(30))
        _ = await task.value

        #expect(collector.snapshot().count == before)
    }

    @Test func audioDeviceMonitorRollsBackOnFirstListenerFailure() async throws {
        let clock = TestClock()
        let adapter = FakeAudioHardwareAdapter()
        adapter.setFailOnAdd(at: 0) // the devices listener fails
        let monitor = AudioDeviceMonitor(clock: clock, adapter: adapter)

        do {
            try await monitor.start()
            Issue.record("start should have thrown when the first listener fails")
        } catch {
            // expected
        }
        #expect(adapter.capturedCount == 0)     // nothing installed
        #expect(adapter.removeCountSnapshot == 0) // nothing to roll back
    }

    @Test func audioDeviceMonitorRollsBackOnSecondListenerFailure() async throws {
        let clock = TestClock()
        let adapter = FakeAudioHardwareAdapter()
        adapter.setFailOnAdd(at: 1) // devices installs; defaultInput fails
        let monitor = AudioDeviceMonitor(clock: clock, adapter: adapter)

        do {
            try await monitor.start()
            Issue.record("start should have thrown when the second listener fails")
        } catch {
            // expected
        }
        // The successfully-installed devices listener must have been removed on rollback.
        #expect(adapter.capturedCount == 0)
        #expect(adapter.removeCountSnapshot == 1)
    }
}
