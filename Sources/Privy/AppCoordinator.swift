import Foundation
import PrivyCore

/// Sole executable-side composition root and owner of integration task handles.
actor AppCoordinator {
    private enum Lifecycle {
        case idle, starting, running, shuttingDown, stopped
    }

    private struct StartupInterrupted: Error {}

    private let model: AppModel
    private var lifecycle: Lifecycle = .idle
    private var shutdownRequested = false

    private var store: (any PrivyStoring)?
    private var controller: (any ShadowCaptureControlling)?
    private var sleepMonitor: (any SystemMonitoring)?
    private var deviceMonitor: (any SystemMonitoring)?

    private var startupTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var monitorForwardingTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func start() async {
        guard lifecycle == .idle else { return }
        lifecycle = .starting
        shutdownRequested = false

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }

    private func performStart() async {
        do {
            let layout = try AppPaths.ensureDirectoriesExist(AppPaths.productionLayout())
            await model.setStorageLayout(layout)
            try requireStartup()

            let clock = SystemClock()
            let store = try PrivyStore(databaseURL: layout.databaseURL)
            self.store = store
            try await store.prepareDatabase()
            try requireStartup()
            _ = try await store.reconcile(storage: layout, at: clock.now())
            try requireStartup()

            let controller = PrivyRuntimeFactory.makeShadowCaptureController(
                store: store,
                storage: layout,
                clock: clock
            )
            self.controller = controller

            let sleepMonitor = SleepWakeMonitor(clock: clock)
            let deviceMonitor = AudioDeviceMonitor(clock: clock)
            self.sleepMonitor = sleepMonitor
            self.deviceMonitor = deviceMonitor

            bindSnapshots(from: controller)
            try await sleepMonitor.start()
            try requireStartup()
            try await deviceMonitor.start()
            try requireStartup()

            forwardMonitorEvents(
                sleepEvents: sleepMonitor.events,
                deviceEvents: deviceMonitor.events,
                to: controller
            )

            await controller.start()
            try requireStartup()
            lifecycle = .running
        } catch is StartupInterrupted {
            await tearDownRuntime()
        } catch {
            let message = Self.actionableStartupMessage(for: error)
            await tearDownRuntime()
            await model.reportBootstrapError(message)
        }
    }

    private func requireStartup() throws {
        guard lifecycle == .starting, !shutdownRequested else {
            throw StartupInterrupted()
        }
    }

    private func bindSnapshots(from controller: any ShadowCaptureControlling) {
        let snapshots = controller.snapshots
        let model = self.model
        snapshotTask = Task {
            for await snapshot in snapshots {
                guard !Task.isCancelled else { break }
                await model.apply(snapshot)
            }
        }
    }

    private func forwardMonitorEvents(
        sleepEvents: AsyncStream<MonitorEvent>,
        deviceEvents: AsyncStream<MonitorEvent>,
        to controller: any ShadowCaptureControlling
    ) {
        monitorForwardingTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in sleepEvents {
                        guard !Task.isCancelled else { break }
                        await controller.handle(event)
                    }
                }
                group.addTask {
                    for await event in deviceEvents {
                        guard !Task.isCancelled else { break }
                        await controller.handle(event)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    func pause(for duration: Duration?) async {
        guard lifecycle == .running, let controller else { return }
        let deadline: Date?
        if let duration {
            let components = duration.components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            deadline = Date().addingTimeInterval(seconds)
        } else {
            deadline = nil
        }
        await controller.pause(untilUTC: deadline)
    }

    func resume() async {
        guard lifecycle == .running, let controller else { return }
        await controller.resume()
    }

    func shutdown() async {
        switch lifecycle {
        case .idle:
            lifecycle = .stopped
            await model.beginShutdown()
            return
        case .starting:
            shutdownRequested = true
            await model.beginShutdown()
            let task = startupTask
            await task?.value
            return
        case .running:
            await model.beginShutdown()
            await tearDownRuntime()
        case .shuttingDown:
            return
        case .stopped:
            return
        }
    }

    /// Stops event ingress before asking the pipeline to close its writer. This prevents
    /// a monitor event from initiating CaptureEngine's debounced restart after pipeline
    /// shutdown has begun.
    private func tearDownRuntime() async {
        guard lifecycle != .shuttingDown, lifecycle != .stopped else { return }
        lifecycle = .shuttingDown
        shutdownRequested = true

        let forwarding = monitorForwardingTask
        monitorForwardingTask = nil
        forwarding?.cancel()

        await sleepMonitor?.stop()
        await deviceMonitor?.stop()
        await forwarding?.value

        if let controller {
            await controller.shutdown()
        }

        let snapshots = snapshotTask
        snapshotTask = nil
        snapshots?.cancel()
        await snapshots?.value

        sleepMonitor = nil
        deviceMonitor = nil
        self.controller = nil
        store = nil
        lifecycle = .stopped
    }

    nonisolated private static func actionableStartupMessage(for error: Error) -> String {
        "Startup failed before capture began: \(error.localizedDescription). "
            + "Check free disk space and access to Library/Application Support/Privy, then relaunch Privy."
    }
}
