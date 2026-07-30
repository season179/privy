import Foundation
import CoreAudio

// Audio device monitor: observes CoreAudio default-input-device and device-list property
// changes and emits coalesced `.defaultInputChanged`/`.deviceListChanged` `MonitorEvent`s.
// Detection only — never restarts capture or writes health rows.
//
// CoreAudio property listeners are `@convention(c)` callbacks that cannot capture Swift
// state and must not allocate on the realtime-ish audio thread. They write raw signals
// into the `@unchecked Sendable` `MonitorEventStream` (`rawEmitter`) and return. A
// dedicated consumer task enriches the default-input signal with the current device UID
// (via the injectable adapter) and feeds a trailing-edge `DeviceChangeDebouncer` actor
// (500 ms default) that publishes the coalesced stream. Exactly one event is published per
// debounce window, preferring `.defaultInputChanged(latestUID)` when present.
//
// `@unchecked Sendable` appears only on `MonitorEventStream`. The adapter, debouncer, and
// monitor are ordinary `Sendable` value/actor types.

/// Injectable seam over the small subset of CoreAudio the monitor needs. Production calls
/// the real CoreAudio APIs; tests inject a fake that captures the `@convention(c)` procs
/// and drives them through the raw path, and can fail `addPropertyListener` to exercise
/// registration rollback.
internal protocol AudioHardwareAdapter: Sendable {
    @discardableResult
    func addPropertyListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        listener: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?
    ) -> OSStatus

    @discardableResult
    func removePropertyListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        listener: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?
    ) -> OSStatus

    /// Best-effort read of the current default input device's UID; nil on any failure.
    func currentDefaultInputDeviceUID() -> String?
}

/// Production adapter that calls the real CoreAudio property-listener APIs. Stateless, so
/// trivially `Sendable`.
internal struct CoreAudioHardwareAdapter: AudioHardwareAdapter {
    func addPropertyListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        listener: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        var address = property
        // CoreAudio copies the address internally, so a temporary pointer is sufficient.
        return withUnsafePointer(to: &address) {
            AudioObjectAddPropertyListener(object, $0, listener, clientData)
        }
    }

    func removePropertyListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        listener: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        var address = property
        return withUnsafePointer(to: &address) {
            AudioObjectRemovePropertyListener(object, $0, listener, clientData)
        }
    }

    func currentDefaultInputDeviceUID() -> String? {
        CoreAudioHardwareAdapter.readDefaultInputDeviceUID()
    }

    /// Best-effort read of the current default input device's UID. Returns `nil` on any
    /// failure (including no input device); the pipeline rebuilds regardless of UID.
    private static func readDefaultInputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard defaultInputAddress.withUnsafeStructAccess({ ptr in
            AudioObjectGetPropertyData(systemObject, ptr, 0, nil, &deviceIDSize, &deviceID)
        }) == noErr else {
            return nil
        }

        // CoreAudio writes a CFStringRef into a pointer-sized buffer. Use a proper optional
        // `CFString?` (nil == "no UID") so a missing UID is reported as nil, and size the
        // buffer from the same optional type.
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard uidAddress.withUnsafeStructAccess({ propPtr in
            withUnsafeMutablePointer(to: &uid) { outPtr in
                AudioObjectGetPropertyData(deviceID, propPtr, 0, nil, &uidSize, outPtr)
            }
        }) == noErr else {
            return nil
        }
        return uid as String?
    }
}

/// Trailing-edge debounce for device-change signals. `Sendable` via actor isolation — no
/// `@unchecked` is used here.
internal actor DeviceChangeDebouncer {
    private let emitter: MonitorEventStream
    private let window: Duration

    private var pendingTask: Task<Void, Never>?
    private var pendingDefaultInput = false
    private var pendingDeviceList = false
    private var latestDeviceUID: String?

    init(emitter: MonitorEventStream, window: Duration) {
        self.emitter = emitter
        self.window = window
    }

    func signalDefaultInputChanged(deviceUID: String?) {
        pendingDefaultInput = true
        latestDeviceUID = deviceUID
        scheduleFlush()
    }

    func signalDeviceListChanged() {
        pendingDeviceList = true
        scheduleFlush()
    }

    /// Cancels the pending quiet-window timer and emits any coalesced event immediately.
    /// Used by `stop()` and tests so shutdown is deterministic without waiting the window.
    func flushNow() {
        pendingTask?.cancel()
        pendingTask = nil
        emitPending()
    }

    private func scheduleFlush() {
        // Each new signal resets the quiet window: a burst collapses to exactly one
        // trailing emission. Cancelling the previous task is safe because the cancelled
        // task re-enters the actor and observes `Task.isCancelled` before emitting.
        pendingTask?.cancel()
        let window = self.window
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.emitPendingFromTask()
        }
    }

    private func emitPendingFromTask() {
        // Re-entered from the debounce task; actor isolation protects `pending*` state.
        emitPending()
    }

    private func emitPending() {
        guard pendingDefaultInput || pendingDeviceList else { return }
        // Exactly one event per window: an AirPods transition raises both properties, but
        // the consumer (W4 pipeline) treats any device-change event as one restart
        // sequence. Prefer `.defaultInputChanged(latestUID)` (it carries the most actionable
        // detail); otherwise emit `.deviceListChanged`.
        if pendingDefaultInput {
            emitter.emitDefaultInputChanged(deviceUID: latestDeviceUID)
        } else {
            emitter.emitDeviceListChanged()
        }
        pendingDefaultInput = false
        pendingDeviceList = false
        latestDeviceUID = nil
    }
}

/// `SystemMonitoring` conformer backed by CoreAudio property listeners, with a 500 ms
/// trailing debounce that collapses a device-change burst into one coalesced event.
public actor AudioDeviceMonitor: SystemMonitoring {
    /// Production trailing-debounce window. CoreAudio emits device-change bursts in a few
    /// milliseconds; this collapses the whole burst into one coalesced event.
    public static let defaultDebounceWindow: Duration = .milliseconds(500)

    private let rawEmitter: MonitorEventStream
    private let publishedEmitter: MonitorEventStream
    private let debounceWindow: Duration
    private let debouncer: DeviceChangeDebouncer
    private let adapter: AudioHardwareAdapter

    private var forwarder: Task<Void, Never>?
    private var started = false

    /// Each successfully installed listener, recorded immediately so `stop()` can remove
    /// exactly what was added and so partial-failure rollback knows what to tear down.
    private var registeredListeners: [RegisteredListener] = []

    private struct RegisteredListener: Sendable {
        let object: AudioObjectID
        let property: AudioObjectPropertyAddress
        let proc: AudioObjectPropertyListenerProc
    }

    public nonisolated var events: AsyncStream<MonitorEvent> { publishedEmitter.stream }

    public init(clock: any PrivyClock, debounceWindow: Duration = AudioDeviceMonitor.defaultDebounceWindow) {
        self.init(clock: clock, debounceWindow: debounceWindow, adapter: CoreAudioHardwareAdapter())
    }

    /// Testable initializer that injects a CoreAudio adapter (e.g. a fake that captures the
    /// `@convention(c)` procs and drives them, and can fail `addPropertyListener`).
    internal init(
        clock: any PrivyClock,
        debounceWindow: Duration = AudioDeviceMonitor.defaultDebounceWindow,
        adapter: AudioHardwareAdapter
    ) {
        self.rawEmitter = MonitorEventStream(clock: clock)
        self.publishedEmitter = MonitorEventStream(clock: clock)
        self.debounceWindow = debounceWindow
        self.debouncer = DeviceChangeDebouncer(emitter: publishedEmitter, window: debounceWindow)
        self.adapter = adapter
    }

    public func start() async throws {
        guard !started else { return }
        startForwarder()

        // Register listeners sequentially, recording each success immediately. If any step
        // fails, roll back every listener installed so far and cancel the forwarder so no
        // untracked `passUnretained` callback outlives the failed start.
        let opaque = Unmanaged<MonitorEventStream>.passUnretained(rawEmitter).toOpaque()
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var installed: [RegisteredListener] = []

        do {
            try registerListener(
                object: systemObject,
                property: AudioDeviceMonitor.devicesProperty,
                proc: AudioDeviceMonitor.deviceListListenerProc,
                clientData: opaque,
                into: &installed,
                name: "devices"
            )
            try registerListener(
                object: systemObject,
                property: AudioDeviceMonitor.defaultInputProperty,
                proc: AudioDeviceMonitor.defaultInputListenerProc,
                clientData: opaque,
                into: &installed,
                name: "defaultInput"
            )
        } catch {
            for entry in installed {
                _ = adapter.removePropertyListener(
                    object: entry.object,
                    property: entry.property,
                    listener: entry.proc,
                    clientData: opaque
                )
            }
            forwarder?.cancel()
            forwarder = nil
            throw error
        }

        // Commit only after the whole installation succeeded.
        registeredListeners = installed
        started = true
    }

    public func stop() async {
        let listeners = registeredListeners
        registeredListeners.removeAll()
        let wasStarted = started
        started = false

        forwarder?.cancel()
        forwarder = nil

        if wasStarted {
            let opaque = Unmanaged<MonitorEventStream>.passUnretained(rawEmitter).toOpaque()
            for entry in listeners {
                _ = adapter.removePropertyListener(
                    object: entry.object,
                    property: entry.property,
                    listener: entry.proc,
                    clientData: opaque
                )
            }
        }
        // Flush any in-flight burst so a coalesced event is never lost on shutdown.
        await debouncer.flushNow()
        rawEmitter.finish()
        publishedEmitter.finish()
    }

    // MARK: - Test seams (no CoreAudio / AppKit)
    // Inject synthetic signals directly into the debouncer. These are retained for focused
    // debouncer unit tests; lifecycle tests use `start()` plus the injected adapter's
    // captured procs to exercise the full raw path.

    internal func injectDeviceListChanged() async {
        await debouncer.signalDeviceListChanged()
    }

    internal func injectDefaultInputChanged(deviceUID: String?) async {
        await debouncer.signalDefaultInputChanged(deviceUID: deviceUID)
    }

    // MARK: - Registration helper

    private func registerListener(
        object: AudioObjectID,
        property: AudioObjectPropertyAddress,
        proc: AudioObjectPropertyListenerProc,
        clientData: UnsafeMutableRawPointer?,
        into installed: inout [RegisteredListener],
        name: String
    ) throws {
        let status = adapter.addPropertyListener(
            object: object,
            property: property,
            listener: proc,
            clientData: clientData
        )
        guard status == noErr else {
            throw NSError(
                domain: "Privy.AudioDeviceMonitor",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "AudioObjectAddPropertyListener(\(name)) failed (status \(status))"]
            )
        }
        // Record immediately so a later step's failure rolls this one back too.
        installed.append(RegisteredListener(object: object, property: property, proc: proc))
    }

    // MARK: - Forwarder: raw signals -> debouncer (with UID enrichment)

    private func startForwarder() {
        let debouncer = self.debouncer
        let adapter = self.adapter
        let raw = rawEmitter.stream
        forwarder = Task {
            for await event in raw {
                switch event {
                case .defaultInputChanged:
                    // The raw signal from the `@convention(c)` proc carries no UID; enrich
                    // it here (on the consumer task, where allocation/CoreAudio queries are
                    // allowed) before coalescing.
                    let uid = adapter.currentDefaultInputDeviceUID()
                    await debouncer.signalDefaultInputChanged(deviceUID: uid)
                case .deviceListChanged:
                    await debouncer.signalDeviceListChanged()
                default:
                    continue
                }
            }
        }
    }

    // MARK: - CoreAudio property addresses (shared with tests via the adapter)

    internal static let devicesProperty = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    internal static let defaultInputProperty = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - CoreAudio listener procs (@convention(c): no capture)

    /// The proc is `@convention(c)`: it cannot capture state, so it reaches the emitter
    /// via the `clientData` pointer registered alongside it and emits one raw signal.
    internal static let deviceListListenerProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let emitter = Unmanaged<MonitorEventStream>.fromOpaque(clientData).takeUnretainedValue()
        emitter.emitDeviceListChanged()
        return noErr
    }

    internal static let defaultInputListenerProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let emitter = Unmanaged<MonitorEventStream>.fromOpaque(clientData).takeUnretainedValue()
        // Emit a UID-less raw signal; the forwarder enriches it off the callback path.
        emitter.emit(.defaultInputChanged(emitter.nowReading(), deviceUID: nil))
        return noErr
    }
}

private extension AudioObjectPropertyAddress {
    /// Lends a stable pointer to the struct for the duration of a CoreAudio call.
    func withUnsafeStructAccess<R>(_ body: (UnsafePointer<AudioObjectPropertyAddress>) -> R) -> R {
        var copy = self
        return withUnsafePointer(to: &copy) { body($0) }
    }
}
