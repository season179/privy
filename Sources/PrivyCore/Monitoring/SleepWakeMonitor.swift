import Foundation
import AppKit

// Sleep/wake monitor: observes `NSWorkspace` and emits `.willSleep`/`.didWake`
// `MonitorEvent`s. Detection only — never restarts capture or writes health rows.
//
// The notification callbacks are explicitly `@Sendable`, created inside a non-`@MainActor`
// (this actor's own) factory, and capture only the `Sendable` `MonitorEventStream`. They
// never capture `self` or any main-actor state: this is the SIGTRAP mitigation called out
// as Risk #1 in docs/m1/plan.md.

/// `SystemMonitoring` conformer backed by `NSWorkspace` sleep/wake notifications.
public actor SleepWakeMonitor: SystemMonitoring {
    private let emitter: MonitorEventStream
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public nonisolated var events: AsyncStream<MonitorEvent> { emitter.stream }

    public init(clock: any PrivyClock) {
        // `emitter` owns the clock so callbacks only need to capture the emitter.
        self.emitter = MonitorEventStream(clock: clock)
    }

    public func start() async throws {
        guard !started else { return }
        started = true

        // `NSWorkspace.shared` is `@MainActor`; reach it briefly on the main actor to
        // grab the notification center. The observer callbacks themselves are `@Sendable`
        // and carry no main-actor isolation.
        let center = await MainActor.run { NSWorkspace.shared.notificationCenter }

        // Capture only the `@unchecked Sendable` emitter. An explicit `@Sendable` function
        // type severs any lexical isolation from this actor method.
        let sleepHandler: @Sendable (Notification) -> Void = { [emitter] _ in
            emitter.emitWillSleep()
        }
        let wakeHandler: @Sendable (Notification) -> Void = { [emitter] _ in
            emitter.emitDidWake()
        }

        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil,
            using: sleepHandler
        )
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil,
            using: wakeHandler
        )
        observers = [sleep, wake]
    }

    public func stop() async {
        let snapshot = observers
        observers.removeAll()
        started = false

        if !snapshot.isEmpty {
            let center = await MainActor.run { NSWorkspace.shared.notificationCenter }
            for observer in snapshot {
                center.removeObserver(observer)
            }
        }
        // Terminate the stream so consumers' `for await` loops exit cleanly.
        emitter.finish()
    }
}
