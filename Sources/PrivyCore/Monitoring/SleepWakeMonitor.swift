import Foundation
import AppKit

// Sleep/wake monitor: emits `.willSleep`/`.didWake` `MonitorEvent`s. Detection only —
// never restarts capture or writes health rows.
//
// The NSWorkspace handlers are produced by a `private static` (nonisolated) factory, are
// explicitly `@Sendable`, and capture only the `Sendable` `MonitorEventStream`. They never
// capture `self` or main-actor state: this is the SIGTRAP mitigation called out as Risk #1
// in docs/m1/plan.md. The notification source is abstracted behind `SleepWakeRegistrar` so
// tests drive the real monitor lifecycle (registration, order/timestamps, removal,
// idempotence, post-stop silence) without AppKit UI.

/// Injectable source of sleep/wake notifications. Production wraps
/// `NSWorkspace.shared.notificationCenter`; tests supply a fake that captures the handlers
/// and posts synthetic notifications.
internal protocol SleepWakeRegistrar: Sendable {
    /// Registers the sleep/wake handlers. The registrar owns the underlying observer tokens
    /// until `unregister()` removes them.
    func register(
        sleep: @Sendable @escaping (Notification) -> Void,
        wake: @Sendable @escaping (Notification) -> Void
    ) async

    /// Removes the handlers registered by the most recent successful `register` call.
    func unregister() async
}

/// Production registrar backed by `NSWorkspace.shared.notificationCenter`. An actor so the
/// observer tokens (non-`Sendable` `NSObjectProtocol`) live behind isolation without any
/// `@unchecked Sendable`.
internal actor WorkspaceSleepWakeRegistrar: SleepWakeRegistrar {
    private var tokens: [NSObjectProtocol] = []

    func register(
        sleep: @Sendable @escaping (Notification) -> Void,
        wake: @Sendable @escaping (Notification) -> Void
    ) async {
        // `NSWorkspace.shared` is `@MainActor`; reach it briefly there, then addObserver
        // (NotificationCenter methods are nonisolated).
        let center = await MainActor.run { NSWorkspace.shared.notificationCenter }
        tokens = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil,
                using: sleep
            ),
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil,
                using: wake
            )
        ]
    }

    func unregister() async {
        let toRemove = tokens
        tokens.removeAll()
        guard !toRemove.isEmpty else { return }
        let center = await MainActor.run { NSWorkspace.shared.notificationCenter }
        for token in toRemove {
            center.removeObserver(token)
        }
    }
}

/// `SystemMonitoring` conformer backed by `NSWorkspace` sleep/wake notifications.
public actor SleepWakeMonitor: SystemMonitoring {
    private let emitter: MonitorEventStream
    private let registrar: SleepWakeRegistrar
    private var started = false

    public nonisolated var events: AsyncStream<MonitorEvent> { emitter.stream }

    public init(clock: any PrivyClock) {
        self.emitter = MonitorEventStream(clock: clock)
        self.registrar = WorkspaceSleepWakeRegistrar()
    }

    /// Testable initializer that injects a registrar (e.g. a fake that captures handlers).
    internal init(clock: any PrivyClock, registrar: SleepWakeRegistrar) {
        self.emitter = MonitorEventStream(clock: clock)
        self.registrar = registrar
    }

    /// Nonisolated static factory: produces `@Sendable` handlers that capture only the
    /// `Sendable` emitter. Because the factory is static (not isolated to any instance or
    /// to `@MainActor`), the closures it returns carry no lexical actor isolation into the
    /// arbitrary thread NSWorkspace delivers them on.
    private static func makeHandlers(
        emitter: MonitorEventStream
    ) -> (sleep: @Sendable (Notification) -> Void, wake: @Sendable (Notification) -> Void) {
        let sleep: @Sendable (Notification) -> Void = { _ in emitter.emitWillSleep() }
        let wake: @Sendable (Notification) -> Void = { _ in emitter.emitDidWake() }
        return (sleep, wake)
    }

    public func start() async throws {
        guard !started else { return }
        let handlers = Self.makeHandlers(emitter: emitter)
        await registrar.register(sleep: handlers.sleep, wake: handlers.wake)
        started = true
    }

    public func stop() async {
        let wasStarted = started
        started = false
        if wasStarted {
            await registrar.unregister()
        }
        // Terminate the stream so consumers' `for await` loops exit cleanly even if stop
        // is called without a prior start.
        emitter.finish()
    }
}
