import Foundation

// Cross-worker audio-source and audio-block contract. W1 owns the declaration; W3
// (capture) and W4 (writer/VAD/pipeline) implement against it. See docs/m1/plan.md
// ("Audio source and block").

/// Native 16 kHz mono timeline. Converted source gaps remain visible in
/// `AudioBlock16k.streamSampleStart`; this constant is the canonical sample rate for
/// VAD windows (4096 samples / 256 ms) and one-hour rotation (57,600,000 samples).
public let privySampleRate = 16_000

/// Why the capture engine was stopped. Drives the writer's mandatory terminal-state
/// mapping (see the close-reason table in docs/m1/plan.md).
public enum StopReason: String, Sendable, Codable {
    case manualPause, systemSleep, deviceChange, restart, shutdown, fatalError
}

/// Why the capture engine is (re)starting after a fault or lifecycle event.
public enum RestartReason: String, Sendable, Codable {
    case systemWake, deviceChange, engineConfigurationChange, heartbeatTimeout, manualRetry
}

/// A converted 16 kHz mono Float32 audio block destined for the writer and VAD lanes.
public struct AudioBlock16k: Sendable, Equatable {
    /// Groups all blocks from one engine run; changes on restart.
    public let captureEpoch: UUID

    /// Increments for every source callback, including dropped callbacks, so timeline
    /// gaps are always visible to consumers.
    public let sequence: UInt64

    /// Normalized 16 kHz timeline position of `samples.first`; converted source gaps
    /// remain visible across drops and restarts.
    public let streamSampleStart: Int64

    /// Clock reading at the first sample of this block.
    public let firstSampleTime: ClockReading

    /// Mono, finite Float32 samples; normally exactly 1600 samples (100 ms).
    public let samples: [Float]
}

/// Discrete capture lifecycle events surfaced alongside the audio stream. `queueOverrun`
/// carries the exact dropped source-frame count and duration so telemetry is precise.
public enum CaptureEvent: Sendable, Equatable {
    case engineStarted(ClockReading, deviceUID: String?)
    case engineStopped(ClockReading, reason: StopReason)
    case configurationChanged(ClockReading)
    case inputUnavailable(ClockReading, detail: String)
    case queueOverrun(ClockReading, droppedSourceFrames: Int, durationSeconds: Double)
    case conversionFailed(ClockReading, detail: String)
}

/// The pair of bounded streams produced by an `AudioCapturing` source.
public struct CaptureStreams: Sendable {
    /// Converted 16 kHz blocks. Created with `.bufferingOldest(80)` (an additional
    /// bounded 8-second queue) so a stalled consumer cannot allocate unbounded memory.
    public let audio: AsyncStream<AudioBlock16k>

    /// Capture lifecycle events.
    public let events: AsyncStream<CaptureEvent>
}

/// A continuously recording audio source. Implementations own `AVAudioEngine`.
public protocol AudioCapturing: Sendable {
    var streams: CaptureStreams { get }
    func start() async throws
    func stop(reason: StopReason) async
    func restart(reason: RestartReason) async throws
}
