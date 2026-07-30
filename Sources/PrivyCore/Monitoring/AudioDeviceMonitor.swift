import Foundation
import CoreAudio

// Audio device monitor: observes CoreAudio default-input-device and device-list property
// changes and emits coalesced `.defaultInputChanged`/`.deviceListChanged` `MonitorEvent`s.
// Detection only — never restarts capture or writes health rows.
//
// CoreAudio property listeners are `@convention(c)` callbacks that cannot capture Swift
// state and must not allocate on the realtime-ish audio thread. They therefore write raw
// signals into the `@unchecked Sendable` `MonitorEventStream` (`rawEmitter`) and return.
// A dedicated consumer task debounces the burst (500 ms trailing window) into the
// published stream, enriching the default-input signal with the current device UID.
//
// `@unchecked Sendable` appears only on `MonitorEventStream` (the blessed wrapper). The
// debouncer is an ordinary `actor`; the monitor itself is an ordinary `actor`.

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
        // Stable emission order within a coalesced burst: default-input first, then list.
        if pendingDefaultInput {
            emitter.emitDefaultInputChanged(deviceUID: latestDeviceUID)
        }
        if pendingDeviceList {
            emitter.emitDeviceListChanged()
        }
        pendingDefaultInput = false
        pendingDeviceList = false
        latestDeviceUID = nil
    }
}

/// `SystemMonitoring` conformer backed by CoreAudio property listeners, with a 500 ms
/// debounce to collapse device-change bursts into one coalesced sequence.
public actor AudioDeviceMonitor: SystemMonitoring {
    /// Production trailing-debounce window. CoreAudio emits device-change bursts in a few
    /// milliseconds; this collapses the whole burst into one coalesced sequence.
    public static let defaultDebounceWindow: Duration = .milliseconds(500)

    private let rawEmitter: MonitorEventStream
    private let publishedEmitter: MonitorEventStream
    private let debounceWindow: Duration
    private let debouncer: DeviceChangeDebouncer

    private var forwarder: Task<Void, Never>?
    private var started = false

    /// CoreAudio property addresses registered with `AudioObjectAddPropertyListener`.
    /// Kept as stored properties so removal uses the same addresses.
    private var registeredAddresses: [AudioObjectPropertyAddress] = []

    public nonisolated var events: AsyncStream<MonitorEvent> { publishedEmitter.stream }

    public init(clock: any PrivyClock, debounceWindow: Duration = AudioDeviceMonitor.defaultDebounceWindow) {
        self.rawEmitter = MonitorEventStream(clock: clock)
        self.publishedEmitter = MonitorEventStream(clock: clock)
        self.debounceWindow = debounceWindow
        self.debouncer = DeviceChangeDebouncer(emitter: publishedEmitter, window: debounceWindow)
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        startForwarder()
        try installCoreAudioListeners()
    }

    public func stop() async {
        forwarder?.cancel()
        forwarder = nil
        removeCoreAudioListeners()
        // Flush any in-flight burst so a coalesced event is never lost on shutdown.
        await debouncer.flushNow()
        started = false
        rawEmitter.finish()
        publishedEmitter.finish()
    }

    // MARK: - Test seams (no CoreAudio / AppKit)
    // Inject synthetic signals directly into the debouncer to prove ordering and
    // coalescing without any hardware or UI.

    internal func injectDeviceListChanged() async {
        await debouncer.signalDeviceListChanged()
    }

    internal func injectDefaultInputChanged(deviceUID: String?) async {
        await debouncer.signalDefaultInputChanged(deviceUID: deviceUID)
    }

    // MARK: - Forwarder: raw signals -> debouncer

    private func startForwarder() {
        let debouncer = self.debouncer
        let raw = rawEmitter.stream
        forwarder = Task {
            for await event in raw {
                switch event {
                case .defaultInputChanged:
                    // The raw signal from the `@convention(c)` proc carries no UID; enrich
                    // it here (on the consumer task, where allocation/CoreAudio queries are
                    // allowed) before coalescing.
                    let uid = AudioDeviceMonitor.currentDefaultInputDeviceUID()
                    await debouncer.signalDefaultInputChanged(deviceUID: uid)
                case .deviceListChanged:
                    await debouncer.signalDeviceListChanged()
                default:
                    continue
                }
            }
        }
    }

    // MARK: - CoreAudio listeners

    private func installCoreAudioListeners() throws {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let opaque = Unmanaged<MonitorEventStream>.passUnretained(rawEmitter).toOpaque()

        let devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesStatus = devicesAddress.withUnsafeStructAccess { ptr in
            AudioObjectAddPropertyListener(systemObject, ptr, AudioDeviceMonitor.deviceListListenerProc, opaque)
        }
        let defaultInputStatus = defaultInputAddress.withUnsafeStructAccess { ptr in
            AudioObjectAddPropertyListener(systemObject, ptr, AudioDeviceMonitor.defaultInputListenerProc, opaque)
        }

        // Surface registration failure rather than running silently undetected. Tests do
        // not exercise this path; the app coordinator handles a thrown `start()`.
        if devicesStatus != noErr {
            throw NSError(domain: "Privy.AudioDeviceMonitor", code: Int(devicesStatus),
                          userInfo: [NSLocalizedDescriptionKey: "AudioObjectAddPropertyListener(devices) failed"])
        }
        if defaultInputStatus != noErr {
            throw NSError(domain: "Privy.AudioDeviceMonitor", code: Int(defaultInputStatus),
                          userInfo: [NSLocalizedDescriptionKey: "AudioObjectAddPropertyListener(defaultInput) failed"])
        }
        registeredAddresses = [devicesAddress, defaultInputAddress]
    }

    private func removeCoreAudioListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let opaque = Unmanaged<MonitorEventStream>.passUnretained(rawEmitter).toOpaque()
        for address in registeredAddresses {
            address.withUnsafeStructAccess { ptr in
                _ = AudioObjectRemovePropertyListener(
                    systemObject,
                    ptr,
                    address.mSelector == kAudioHardwarePropertyDevices
                        ? AudioDeviceMonitor.deviceListListenerProc
                        : AudioDeviceMonitor.defaultInputListenerProc,
                    opaque
                )
            }
        }
        registeredAddresses.removeAll()
    }

    // MARK: - CoreAudio helpers (nonisolated, allocation-free where the proc runs)

    /// The proc is `@convention(c)`: it cannot capture state, so it reaches the emitter
    /// via the `clientData` pointer registered alongside it and emits one raw signal.
    private static let deviceListListenerProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let emitter = Unmanaged<MonitorEventStream>.fromOpaque(clientData).takeUnretainedValue()
        emitter.emitDeviceListChanged()
        return noErr
    }

    private static let defaultInputListenerProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        let emitter = Unmanaged<MonitorEventStream>.fromOpaque(clientData).takeUnretainedValue()
        // Emit a UID-less raw signal; the forwarder enriches it off the callback path.
        emitter.emit(.defaultInputChanged(emitter.nowReading(), deviceUID: nil))
        return noErr
    }

    /// Best-effort read of the current default input device's UID. Returns `nil` on any
    /// failure (including no input device); the pipeline rebuilds regardless of UID.
    private static func currentDefaultInputDeviceUID() -> String? {
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

        // CoreAudio writes a CFStringRef into a pointer-sized buffer. Use a proper
        // optional `CFString?` (nil == "no UID") so a missing UID is reported as `nil`,
        // and size the buffer from the same optional type.
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
        // `uid` is nil when CoreAudio wrote a NULL ref (device has no UID); the String
        // conversion retains the CFString content for the return.
        return uid as String?
    }
}

// MARK: - AudioObjectPropertyAddress pointer access

private extension AudioObjectPropertyAddress {
    /// Lends a stable pointer to the struct for the duration of a CoreAudio call.
    func withUnsafeStructAccess<R>(_ body: (UnsafePointer<AudioObjectPropertyAddress>) -> R) -> R {
        var copy = self
        return withUnsafePointer(to: &copy) { body($0) }
    }
}
