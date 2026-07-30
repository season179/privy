# M1 implementation plan: native shadow capture

**Status:** implementation-ready
**Scope:** PLAN.md rev 2, M1 only. This plan does not reopen the locked product or technology decisions.

## Outcome and non-goals

M1 ships one signed Swift 6 menu bar app that continuously records microphone audio into rotating Ogg Opus shadow files, runs FluidAudio Silero VAD in parallel for observation only, persists chunk/VAD/health state in SQLite, survives expected macOS lifecycle changes, and never displays a healthy recording state when capture is dead.

Not in M1: VAD-gated capture, transcription, FTS search UI, session grouping behavior, cost metering, R2, diarization, system audio, or distribution outside the owner's Mac. The M1 migration creates the full PLAN.md §5 schema so later milestones do not need a destructive bootstrap migration, but M1 only exposes APIs for chunks, VAD events, health, reconciliation, and menu summaries.

## Runtime architecture

```text
AVAudioEngine realtime tap
  │  explicit @Sendable closure; copy only; never await/allocate/log/encode/convert
  ▼
preallocated SPSC raw-audio ring (bounded, nonblocking producer)
  │  dedicated non-main consumer
  ▼
AVAudioConverter → 16 kHz mono Float32 AudioBlock16k
  │
  ▼
ShadowCapturePipeline
  ├── lossless-priority lane → ShadowChunkWriter actor → OggOpusWriter → .partial → .ogg
  │                                              └──── chunk lifecycle → PrivyStore actor
  └── best-effort isolated lane → VADService actor → 4096-sample/256 ms windows
                                                 └──── batched observations → PrivyStore actor

Sleep/wake + CoreAudio device monitors ── MonitorEvent ──► pipeline restart/state machine
Capture/VAD/writer/monitor failures ───── HealthEvent ──► Store + AppModel snapshot stream
SwiftUI menu label/dropdown ◄──────────── PipelineSnapshot (observed truth, not intent)
```

Capture starts even if the VAD model is downloading or unavailable. VAD failure must reduce only VAD coverage; it must never stop or back-pressure recording.

## Package.swift changes applied by the orchestrator before workers start

Replace the package declaration's products/dependencies/targets with the following shape; preserve the existing system-library target paths and the `OpusShim`, `OpusIO`, and `OpusSpike` target definitions.

```swift
products: [
    .executable(name: "Privy", targets: ["Privy"]),
    .library(name: "PrivyCore", targets: ["PrivyCore"]),
    .executable(name: "OpusSpike", targets: ["OpusSpike"]),
],
dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
],
targets: [
    .systemLibrary(name: "COpus", path: "Libraries/COpus", pkgConfig: "opus", providers: [.brew(["opus"])]),
    .systemLibrary(name: "COgg", path: "Libraries/COgg", pkgConfig: "ogg", providers: [.brew(["libogg"])]),
    .target(name: "OpusShim", dependencies: ["COpus"]),
    .target(name: "OpusIO", dependencies: ["COpus", "COgg", "OpusShim"]),
    .target(
        name: "PrivyCore",
        dependencies: [
            "OpusIO",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Atomics", package: "swift-atomics"),
        ],
        path: "Sources/PrivyCore"
    ),
    .executableTarget(name: "Privy", dependencies: ["PrivyCore"], path: "Sources/Privy"),
    .testTarget(
        name: "PrivyCoreTests",
        dependencies: ["PrivyCore", "OpusIO"],
        path: "Tests/PrivyTests"
    ),
    .executableTarget(name: "OpusSpike", dependencies: ["OpusIO"], path: "Sources/OpusSpike"),
]
```

The executable must no longer import GRDB, FluidAudio, or OpusIO directly. The old `PrivyTests` target declaration is replaced, not duplicated; `PrivyCoreTests` intentionally keeps `path: "Tests/PrivyTests"` so the existing scaffold directory does not need a package-and-filesystem rename. The early library seam is intentional: the owner explicitly requires testable app logic and workers need one importable contract module while the executable remains a thin UI shell. `swift-atomics` is used only by the realtime SPSC ring and counters; it gives explicit acquire/release memory ordering without a blocking lock or deprecated OSAtomic APIs at the audio boundary. Workers do not edit `Package.swift`.

## Final module and file layout

```text
Sources/
├── OpusIO/
│   └── OggOpusWriter.swift                 # W4: retain spike result; add durable flush support if needed
├── PrivyCore/
│   ├── Contracts/
│   │   ├── ClockContracts.swift            # W1
│   │   ├── AudioContracts.swift            # W1
│   │   ├── StoreContracts.swift            # W1
│   │   ├── HealthContracts.swift           # W1
│   │   └── PipelineContracts.swift         # W1
│   ├── Foundation/
│   │   └── AppPaths.swift                  # W1
│   ├── Clock/
│   │   ├── SystemClock.swift               # W1
│   │   └── ClockDiscontinuityDetector.swift # W1
│   ├── Monitoring/
│   │   ├── MonitorEventStream.swift        # W1
│   │   ├── SleepWakeMonitor.swift          # W1
│   │   └── AudioDeviceMonitor.swift        # W1
│   ├── Store/
│   │   ├── DatabaseRecords.swift           # W2
│   │   ├── DatabaseMigrations.swift        # W2
│   │   ├── ReconciliationPlanner.swift     # W2
│   │   └── PrivyStore.swift                # W2
│   ├── Capture/
│   │   ├── RealtimeAudioRing.swift         # W3
│   │   ├── AudioConverter16k.swift          # W3
│   │   └── CaptureEngine.swift             # W3
│   └── Recording/
│       ├── ShadowChunkWriter.swift          # W4
│       ├── VADService.swift                 # W4
│       ├── GapWatchdog.swift                # W4
│       └── ShadowCapturePipeline.swift      # W4
└── Privy/
    ├── PrivyApp.swift                       # W5
    ├── AppCoordinator.swift                 # W5
    ├── AppModel.swift                       # W5
    ├── MenuBarLabel.swift                   # W5
    ├── MenuView.swift                       # W5
    └── LoginItem.swift                      # W5

Tests/PrivyTests/
├── ClockAndMonitorTests.swift               # W1
├── StoreTests.swift                         # W2
├── ReconciliationTests.swift                # W2
├── RealtimeAudioRingTests.swift             # W3
├── AudioConverterTests.swift                # W3
├── ShadowChunkWriterTests.swift             # W4
├── VADServiceTests.swift                    # W4
├── FluidAudioVADSmokeTests.swift            # W4
└── ShadowCapturePipelineTests.swift         # W4

scripts/
├── build-app.sh                             # W5 may adjust bundling only; signing behavior remains locked
└── verify-m1.sh                             # W5
```

`Sources/Privy/CaptureSpike.swift`, `Sources/Privy/SpikeLog.swift`, and `Tests/PrivyTests/PrivyTests.swift` are spike scaffolding; W5 removes them after equivalent production paths exist. `Sources/OpusSpike` remains as a development diagnostic and is not linked into `Privy.app`.

## Shared contracts

These declarations are the cross-worker API. W1 owns their source files; W2–W4 implement against them without widening or renaming them. A required change to a shared declaration returns to the orchestrator rather than being made in another worker's files.

### Time

```swift
public struct ClockReading: Sendable, Equatable {
    public let wallUTC: Date
    public let monotonicSeconds: Double   // seconds from this clock instance's ContinuousClock origin
    public let clockEpoch: UUID          // changes only when the app process creates a new SystemClock
}

public protocol PrivyClock: Sendable {
    func now() -> ClockReading
    func elapsedSeconds(from: ClockReading, to: ClockReading) -> Double
}
```

`SystemClock` wraps `ContinuousClock`; durations and chunk offsets use monotonic values. `Date` is only the UTC anchor used for display/absolute timestamps. Values from different `clockEpoch`s must never be subtracted; cross-process reconciliation uses UTC plus an explicit startup/recovery health event. `ClockDiscontinuityDetector` compares wall delta with monotonic delta within one epoch and emits `.clockDiscontinuity` when the difference exceeds 1 second. Tests inject a lock-protected `TestClock` conformer from the test target.

### Audio source and block

```swift
public let privySampleRate = 16_000

public enum StopReason: String, Sendable, Codable {
    case manualPause, systemSleep, deviceChange, restart, shutdown, fatalError
}

public enum RestartReason: String, Sendable, Codable {
    case systemWake, deviceChange, engineConfigurationChange, heartbeatTimeout, manualRetry
}

public struct AudioBlock16k: Sendable, Equatable {
    public let captureEpoch: UUID
    public let sequence: UInt64              // increments for every source callback, including dropped callbacks
    public let streamSampleStart: Int64      // normalized 16 kHz timeline; converted source gaps remain visible
    public let firstSampleTime: ClockReading
    public let samples: [Float]              // mono, finite Float32; normally exactly 1600 samples/100 ms
}

public enum CaptureEvent: Sendable, Equatable {
    case engineStarted(ClockReading, deviceUID: String?)
    case engineStopped(ClockReading, reason: StopReason)
    case configurationChanged(ClockReading)
    case inputUnavailable(ClockReading, detail: String)
    case queueOverrun(ClockReading, droppedSourceFrames: Int, durationSeconds: Double)
    case conversionFailed(ClockReading, detail: String)
}

public struct CaptureStreams: Sendable {
    public let audio: AsyncStream<AudioBlock16k>
    public let events: AsyncStream<CaptureEvent>
}

public protocol AudioCapturing: Sendable {
    var streams: CaptureStreams { get }
    func start() async throws
    func stop(reason: StopReason) async
    func restart(reason: RestartReason) async throws
}
```

The realtime tap is an explicitly typed `@Sendable` closure created by a `nonisolated` factory and captures only the preallocated ring producer plus atomic counters. It must not capture `self`, `@MainActor` state, an actor-isolated closure, `AsyncStream.Continuation`, the Store, or the logger. The tap copies native PCM and timing metadata into the ring and returns. The conversion consumer alone converts to 16 kHz mono, packages normal output as 1600-sample/100 ms blocks, and allocates/yields `AudioBlock16k.samples`; zero-allocation is required only in the realtime producer, not in downstream tasks.

`CaptureStreams.audio` is created with `.bufferingOldest(80)`, an additional bounded 8-second queue. The conversion consumer inspects every `continuation.yield(block)` result. On `.dropped(let block)`, it emits/coalesces `.queueOverrun` using that dropped block's normalized sample range and duration; on `.terminated`, it stops conversion. No converted audio is buffered without a fixed bound and drop telemetry.

The ring is single-producer/single-consumer, preallocated for at least 8 seconds at the active device format, and uses `ManagedAtomic` indices/counters. It never waits. On full capacity it rejects the newest callback as one unit, increments sequence/sample positions anyway, and atomically accumulates the exact dropped source-frame count. The consumer converts that count to duration and emits `.queueOverrun`; the next accepted block retains the timeline gap. `RealtimeAudioRing` is explicitly permitted to be `@unchecked Sendable`; its inline safety proof must state single producer (tap), single consumer (drain task), acquire/release publication, and no resize or storage replacement after `installTap`.

### Store

```swift
public struct StorageLayout: Sendable, Equatable {
    public let rootDirectory: URL
    public let databaseURL: URL
    public let audioDirectory: URL
}

public enum ReconciliationActionKind: String, Sendable, Codable {
    case finalizedPartial, finalizedRecordingRow, failedMissingFile, importedOrphan, preservedUnreadable
}

public struct ReconciliationAction: Sendable, Equatable {
    public let kind: ReconciliationActionKind
    public let chunkID: Int64?
    public let relativeAudioPath: String
    public let detail: String
}

public struct ReconciliationReport: Sendable, Equatable {
    public let actions: [ReconciliationAction]
    public let readyCount: Int
    public let failedCount: Int
    public let preservedFileCount: Int
}

public enum ChunkState: String, Sendable, Codable {
    case recording, ready, transcribing, transcribed, uploaded, deleted, failed
}

public enum ChunkKind: String, Sendable, Codable { case shadow, utterance }
public enum VADEventKind: String, Sendable, Codable { case score, speechStart, speechEnd }

public struct NewChunk: Sendable {
    public let kind: ChunkKind
    public let startedAtUTC: Date
    public let startedMono: Double
    public let relativeAudioPath: String     // final .ogg path; .partial is derived, never persisted
}

public struct ChunkRecord: Sendable, Equatable {
    public let id: Int64
    public let kind: ChunkKind
    public let startedAtUTC: Date
    public let startedMono: Double
    public let durationSeconds: Double
    public let relativeAudioPath: String
    public let sizeBytes: Int64
    public let checksumSHA256: String?
    public let state: ChunkState
}

public struct VADEventRecord: Sendable, Equatable {
    public let chunkID: Int64
    public let monotonicSeconds: Double
    public let kind: VADEventKind
    public let score: Float?                 // required for score; optional on boundaries
}

public struct MenuSummary: Sendable, Equatable {
    public let currentChunk: ChunkRecord?
    public let bytesRecordedToday: Int64
    public let recentHealth: [HealthEvent]
}

public protocol PrivyStoring: Sendable {
    func prepareDatabase() async throws
    func createChunk(_ chunk: NewChunk) async throws -> ChunkRecord
    func checkpointChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64) async throws
    func finalizeChunk(id: Int64, durationSeconds: Double, sizeBytes: Int64,
                       checksumSHA256: String) async throws -> ChunkRecord
    func failChunk(id: Int64, reason: String) async throws
    func appendVADEvents(_ events: [VADEventRecord]) async throws
    func appendHealth(_ event: HealthEvent) async throws
    func menuSummary(dayContaining: Date, healthLimit: Int) async throws -> MenuSummary
    func reconcile(storage: StorageLayout, at: ClockReading) async throws -> ReconciliationReport
}
```

`PrivyStore` is an actor wrapping a GRDB `DatabasePool` in WAL mode and a versioned `DatabaseMigrator`. All date strings are stable ISO-8601 UTC with fractional seconds; enum raw values are the exact SQL values. The initial migration creates all PLAN.md §5 tables and FTS5, plus indexes on chunk state/start, VAD chunk/time, and health time. M1 does not expose transcript/cost/session mutation methods.

`checkpointChunk` runs at most every 5 seconds. `appendVADEvents` batches at least four 256 ms score rows per transaction. No audio-thread code calls the Store.

### Writer and VAD

```swift
public enum WriterTransition: Sendable, Equatable {
    case opened(ChunkRecord)
    case checkpointed(chunkID: Int64, durationSeconds: Double)
    case finalized(ChunkRecord)
}

public protocol ShadowChunkWriting: Sendable {
    func append(_ block: AudioBlock16k) async throws -> [WriterTransition]
    func close(reason: StopReason, at: ClockReading) async throws -> [WriterTransition]
    func activeChunk() async -> ChunkRecord?
}

public enum VADRuntimeStatus: Sendable, Equatable {
    case notStarted, preparingModel, ready, failed(String)
}

public struct VADObservation: Sendable, Equatable {
    public let streamSampleIndex: Int64       // end of the exact 4096-sample analysis window
    public let monotonicSeconds: Double
    public let probability: Float
    public let boundary: VADEventKind?        // speechStart/speechEnd only
}

public protocol VADAnalyzing: Sendable {
    func prepare() async
    func process(_ block: AudioBlock16k) async throws -> [VADObservation]
    func reset(afterGapAt: ClockReading) async
    func status() async -> VADRuntimeStatus
}
```

`ShadowChunkWriter` is an actor and is the only owner of an `OggOpusWriter`. Rotation is exactly 57,600,000 samples (one hour at 16 kHz); a block crossing the boundary is split so no sample is lost or duplicated. File order is: create DB row in `recording` → open `<name>.ogg.partial` → append/force Ogg pages → normal close and durable flush → atomic rename to `<name>.ogg` → SHA-256/size → DB state `ready`. Names contain UTC start plus UUID so orphan files remain attributable after a crash.

`close(reason:)` has one mandatory terminal-state mapping:

| `StopReason` | Required result before another chunk may open |
|---|---|
| `.manualPause`, `.systemSleep`, `.deviceChange`, `.restart`, `.shutdown` | Finish normally, rename, measure/checksum, and transition `recording → ready`. |
| `.fatalError` | Stop accepting blocks and preserve the partial/final file; run same-process writer recovery. If `ffprobe` proves it decodable, measure the real file and transition to `ready`; otherwise call `failChunk` and leave the file preserved. |

The same-process writer-recovery rule is blocking: after any append/flush/rename/checksum/Store failure, the pipeline must terminally transition the abandoned row to `ready` or `failed` before opening a replacement chunk. If the Store is unavailable and no terminal transition can be persisted, capture remains `.error` and no replacement writer opens. Startup reconciliation remains the fallback for process death during this recovery.

The VAD adapter owns `VadManager`, `VadStreamState`, and `VadSegmentationConfig`. It accumulates incoming samples and calls `processStreamingChunk` with exactly 4096 samples (256 ms at 16 kHz), not the obsolete 30 ms assumption. This preserves one timestamped score per analysis window. It carries FluidAudio state across hour rotations; after an audio gap/drop/device restart it resets state and emits a health event instead of joining discontinuous audio. FluidAudio event sample indices are mapped to `AudioBlock16k.streamSampleStart`; the event attaches to the chunk whose interval contains that sample, including at rotation boundaries.

### Monitor, health, and pipeline state

```swift
public enum MonitorEvent: Sendable, Equatable {
    case willSleep(ClockReading)
    case didWake(ClockReading)
    case defaultInputChanged(ClockReading, deviceUID: String?)
    case deviceListChanged(ClockReading)
}

public protocol SystemMonitoring: Sendable {
    var events: AsyncStream<MonitorEvent> { get }
    func start() async throws
    func stop() async
}

public enum HealthKind: String, Sendable, Codable {
    case startup, recordingStarted, recordingStopped, sleep, wake, deviceChange
    case engineRestart, queueOverrun, gap, vadPreparing, vadReady, vadGap, vadError
    case writerError, clockDiscontinuity, recovery, error
}

public enum HealthSeverity: String, Sendable, Codable { case info, warning, error }

public struct HealthDetail: Sendable, Codable, Equatable {
    public let message: String
    public let clockEpoch: UUID?
    public let monotonicSeconds: Double?
    public let gapStartedUTC: Date?
    public let gapEndedUTC: Date?
    public let durationSeconds: Double?
    public let deviceUID: String?
    public let droppedFrames: Int64?
    public let durationIsEstimated: Bool
}

public struct HealthEnvelope: Sendable, Codable, Equatable {
    public let severity: HealthSeverity
    public let detail: HealthDetail
}

public struct HealthEvent: Sendable, Equatable {
    public let atUTC: Date
    public let kind: HealthKind
    public let severity: HealthSeverity
    public let detail: HealthDetail
}
```

The locked `health.detail` column stores one `HealthEnvelope` JSON object with the exact shape `{"severity":"info|warning|error","detail":{...HealthDetail fields...}}`. `appendHealth` constructs the envelope from `HealthEvent`; every health read, including `menuSummary`, decodes the envelope and restores both top-level fields. Unknown/malformed envelopes fail decoding visibly rather than silently defaulting severity.

```swift

public enum CaptureReality: Sendable, Equatable {
    case starting, recording, paused(untilUTC: Date?), recovering(String), error(String), stopped
}

public struct PipelineSnapshot: Sendable, Equatable {
    public let capture: CaptureReality
    public let vad: VADRuntimeStatus
    public let currentChunk: ChunkRecord?
    public let bytesRecordedToday: Int64
    public let recentHealth: [HealthEvent]
    public let lastAudioAtUTC: Date?
}

public protocol ShadowCaptureControlling: Sendable {
    var snapshots: AsyncStream<PipelineSnapshot> { get }
    func start() async
    func handle(_ event: MonitorEvent) async
    func pause(untilUTC: Date?) async
    func resume() async
    func shutdown() async
}
```

Monitor implementations emit `MonitorEvent` only. `ShadowCapturePipeline` maps each monitor/capture/VAD/writer event to a persisted `HealthEvent`, performs the corresponding state transition, and then publishes a snapshot. Callback closures registered with NSWorkspace, CoreAudio, and AVAudioEngine are explicitly `@Sendable`, nonisolated, and capture only a Sendable event emitter.

The capture state is observed reality. `.recording` requires a running engine, an open chunk, and an audio heartbeat less than 2 seconds old. GapWatchdog is armed only after entering `.recording` with a fresh heartbeat. It is synchronously disarmed and all pending deadlines are cancelled before every intentional engine stop: manual pause, `willSleep`, device-change rebuild, explicit restart, and shutdown. While armed, 2 seconds without frames triggers `.recovering` plus exactly one restart attempt; 5 seconds becomes `.error` and persists `.gap`.

On `didWake`, the pipeline stays `.recovering` and starts a 10-second wake grace window with GapWatchdog disarmed. Sleep downtime is represented by exactly one `.sleep`, one `.wake`, and one measured `.gap` health sequence. The first post-wake audio heartbeat ends grace and arms the watchdog; if no heartbeat arrives by 10 seconds, wake recovery emits one separate error/gap and remains non-recording. The menu icon is a pure rendering of `PipelineSnapshot.capture`, never of a requested or cached state.

## Crash and lifecycle invariants

1. **Startup:** create paths → migrate DB → reconcile filesystem/rows → start monitors → start shadow pipeline → publish `.recording` only after the first converted block has reached an open writer.
2. **Sleep:** on `willSleep`, disarm GapWatchdog first, publish `.recovering("system sleep")`, persist `.sleep`, close the current chunk best-effort, and stop the engine. Ogg remains valid even if sleep wins the race. On `didWake`, persist `.wake`, enter the defined 10-second grace window, re-enumerate input, rebuild converter/ring/engine, open a new chunk, and persist exactly one measured sleep gap; only fresh audio re-arms the watchdog.
3. **Device change:** debounce the CoreAudio/device-list/configuration burst for 500 ms, transition out of `.recording`, close the current chunk, rebuild against the selected/default device format, restart, and log one structured `.deviceChange` plus `.engineRestart`. AirPods connect/disconnect is expected, not fatal.
4. **Manual pause:** disarm GapWatchdog before closing the current file and stopping capture. A `ContinuousClock` timer resumes a timed pause; wake also re-evaluates an expired wall deadline. Until-resumed has no timer. Paused time is intentional and represented by `recordingStopped`, not treated as an unexplained fault.
5. **Kill/relaunch:** no shutdown hook is assumed. Reconciliation handles every crash window without deleting audio:
   - `recording` row + `.partial`: preserve and atomically rename when non-empty; set `size_bytes` from the filesystem and `duration_s` from `ffprobe` decoded duration, then checksum and mark `ready`. If probing fails or the file is undecodable, preserve it and mark `failed`; never publish checkpoint-stale metadata as ready.
   - `recording` row + final `.ogg`: likewise remeasure filesystem size and decoded duration, checksum, then mark `ready`; probing failure preserves the file as `failed`.
   - `recording`/`ready` row + no file: mark `failed` and log `.error`.
   - orphan final or partial file: create a matching `failed` row from the timestamp/UUID filename and log `.recovery`; never discard or overwrite it.
   - empty/unreadable files remain preserved and `failed` for inspection.
6. **Normal rotation and same-process recovery:** exactly one row is `recording`; old chunk is `ready` before the new chunk becomes the snapshot's current chunk. A DB or writer failure immediately leaves `.recording`, invokes the mandatory terminal-state recovery table, and opens no replacement until the old row is `ready` or `failed`.
7. **Gap accounting:** source sequence/sample discontinuities, queue drops, engine downtime, sleep, and process recovery all produce structured health rows. Same-process durations use monotonic time; cross-process downtime is explicitly estimated from UTC and marked as such. No monitor or callback writes SQLite directly.

## Worker execution plan

All file ownership below is exclusive. A worker must not edit another worker's files, `Package.swift`, generated lockfiles, or unlisted support files. W1 lands first. W2, W3, and W4 then branch from W1 and run in parallel. W5 is the integration lane and begins after W2–W4 are merged.

### W1 — Contracts, clock, and system monitors (prerequisite)

**Files owned**

- `Sources/PrivyCore/Contracts/{ClockContracts,AudioContracts,StoreContracts,HealthContracts,PipelineContracts}.swift`
- `Sources/PrivyCore/Foundation/AppPaths.swift`
- `Sources/PrivyCore/Clock/{SystemClock,ClockDiscontinuityDetector}.swift`
- `Sources/PrivyCore/Monitoring/{MonitorEventStream,SleepWakeMonitor,AudioDeviceMonitor}.swift`
- `Tests/PrivyTests/ClockAndMonitorTests.swift`

**Scope**

Materialize the shared declarations above; define `StorageLayout` rooted at `~/Library/Application Support/Privy` with `privy.sqlite` and `Audio/`; implement `SystemClock`; implement Sendable event emitters and NSWorkspace/CoreAudio monitors. M1 deliberately has no quarantine directory: failed/suspect files remain preserved in place with failed rows. Monitoring detects only and emits events. It does not restart capture or write health rows.

**Hard constraints**

- Public cross-module values are `Sendable`; `@unchecked Sendable` is permitted only for the synchronized event-emitter wrapper and W3's `RealtimeAudioRing`, whose documented SPSC/atomic/no-resize invariant is its safety proof.
- Notification/property-listener callbacks are explicit `@Sendable`, constructed in nonisolated code, and capture no main-actor closure.
- Wall time is never used for duration math within a clock epoch.
- Device notifications are debounced/coalesced but not silently discarded.

**Acceptance criteria**

- Contract types compile under Swift 6 strict concurrency and are sufficient for fakes in later workers.
- Fake-clock tests cover normal advance, sleep-like advance, wall-clock jump, and cross-epoch subtraction refusal.
- Monitor tests inject callbacks without AppKit UI and prove event ordering/coalescing.

**Verification**

```bash
swift build --target PrivyCore
swift test --filter ClockAndMonitorTests
```

### W2 — GRDB store, migration, and reconciliation

**Files owned**

- `Sources/PrivyCore/Store/{DatabaseRecords,DatabaseMigrations,ReconciliationPlanner,PrivyStore}.swift`
- `Tests/PrivyTests/{StoreTests,ReconciliationTests}.swift`

**Scope**

Implement `PrivyStoring` with `DatabasePool`, WAL, foreign keys, stable migrations, typed GRDB records, batched VAD inserts, exact `HealthEnvelope` JSON persistence, menu summary queries, and deterministic startup reconciliation. Keep `ReconciliationPlanner` pure: DB/file inventory in, ordered actions/report out; `PrivyStore` applies the plan idempotently. Recovery uses filesystem attributes plus `ffprobe` decoded duration rather than checkpoint metadata before a preserved file may become `ready`.

**Hard constraints**

- Schema matches PLAN.md §5; future-state enum values are accepted even though M1 only writes `recording`, `ready`, and `failed`.
- State changes use guarded SQL updates (`WHERE state = expected`) so duplicate finalize/reconcile calls cannot regress state.
- No recovered audio is deleted. Relative paths cannot escape `StorageLayout.audioDirectory`.
- `prepareDatabase` and `reconcile` are safe to run repeatedly after interruption.
- If `ffprobe` is unavailable, fails, or reports an undecodable recovered file, preserve it and mark its row `failed`; never guess ready duration/size from the stale checkpoint.
- Tests use temporary directories/databases; no test touches the live app-support directory.

**Acceptance criteria**

- A fresh DB has every §5 table, FTS5 table, index, and migration record.
- CRUD tests cover chunk create/checkpoint/finalize/fail, VAD batches, health, and day/menu summary boundaries; a required health round-trip persists each severity through the `HealthEnvelope` and verifies `menuSummary` restores it unchanged.
- Reconciliation tests cover all five crash cases above, real filesystem size/decoded duration replacing stale checkpoints, probe failure → preserved `failed`, repeated reconciliation, path traversal, duplicate UUID filenames, missing files, and DB/file-operation failure midway.
- After reconciliation every preserved audio file has a row and no row remains `recording` unless a live writer explicitly owns it.

**Verification**

```bash
swift build --target PrivyCore
swift test --filter StoreTests
swift test --filter ReconciliationTests
```

### W3 — Realtime capture, bounded ring, and conversion

**Files owned**

- `Sources/PrivyCore/Capture/{RealtimeAudioRing,AudioConverter16k,CaptureEngine}.swift`
- `Tests/PrivyTests/{RealtimeAudioRingTests,AudioConverterTests}.swift`

**Scope**

Implement the preallocated lock-free SPSC ring, the dedicated drain/conversion loop, one stateful `AVAudioConverter` path to 16 kHz mono Float32 packaged as 100 ms blocks, the bounded `.bufferingOldest(80)` conversion-to-pipeline stream, AVAudioEngine lifecycle, input-device selection/default fallback, and engine-configuration event emission. Ring metadata preserves callback sequence, source sample position, source format, and host timestamp so conversion latency does not become capture time.

**Hard constraints**

- The tap closure follows the audio contract literally: explicit `@Sendable`, nonisolated creation, no `self`, actor, allocation, lock, wait, task creation, conversion, logging, SQLite, or file I/O.
- Ring storage is allocated before `installTap`; producer uses acquire/release atomics and bounded copies only.
- Ring overflow drops the newest whole callback and accounts exact dropped frames/duration; no partial block and no overwrite of unread storage. Converted-stream overflow is detected by inspecting every `yield` result and coalesced into `.queueOverrun` with the dropped normalized block range.
- Restart creates a new `captureEpoch`, drains/discards old-format slots explicitly, and never feeds mixed formats into one converter.
- `stop`/`restart` are idempotent under notification bursts.

**Acceptance criteria**

- Deterministic ring tests cover empty/full/wraparound, sequence gaps, overflow counters, maximum callback size, and producer faster than consumer.
- Thread-sanitized stress runs show no race while producing and consuming millions of samples.
- Converter tests cover 48 kHz stereo, 44.1 kHz mono, non-integer resampling boundaries, finite output, channel mixing, 1600-sample packaging, continuity across blocks, and reset after format change; a bounded-stream test fills all 80 slots and proves each rejected block produces exact overrun telemetry.
- Capture start with no input reports `inputUnavailable` instead of claiming success.

**Verification**

```bash
swift build --target PrivyCore
swift test --filter RealtimeAudioRingTests
swift test --filter AudioConverterTests
swift test --sanitize=thread --filter RealtimeAudioRingTests
```

### W4 — Ogg chunk writer, FluidAudio VAD, watchdog, and shadow pipeline

**Files owned**

- `Sources/OpusIO/OggOpusWriter.swift`
- `Sources/PrivyCore/Recording/{ShadowChunkWriter,VADService,GapWatchdog,ShadowCapturePipeline}.swift`
- `Tests/PrivyTests/{ShadowChunkWriterTests,VADServiceTests,FluidAudioVADSmokeTests,ShadowCapturePipelineTests}.swift`

**Scope**

Implement the Store-backed rotating writer, 256 ms FluidAudio adapter, independent bounded VAD lane, heartbeat/gap watchdog, pipeline state machine, pause/resume, health mapping, and snapshots. Keep writer progress ahead of VAD: pipeline writes each block first, then nonblocking-yields a copy to the VAD lane. A full VAD lane resets VAD continuity and logs `vadGap`; it never delays the writer.

Inside `VADService.swift`, declare an internal `VADModelProcessing: Sendable` seam with an associated Sendable stream-state type and exactly two operations: `makeStreamState()` and `processStreamingChunk(_:state:config:) -> updated state + probability + optional boundary`. `VADService` is generic over this seam. A concrete actor adapter wraps `VadManager`; unit tests inject a deterministic fake and only `FluidAudioVADSmokeTests` constructs the real model/download path.

**Hard constraints**

- `OggOpusWriter` remains single-owner/thread-unsafe and lives only inside the writer actor; normal finish durably synchronizes before close/rename, while crash-truncated behavior remains valid. For exact one-hour rotation, W4 adds an EOS-less durable close that flushes existing pages, leaves granule position unchanged, and injects no packet; the spike already proved EOS-less/truncated Ogg decodes. Nonaligned closes may pad at most one 20 ms Opus frame while persisted duration remains the real input-sample duration.
- One-hour rotation splits a crossing block exactly; sample conservation is asserted in tests.
- `VadManager` initialization/download runs off the main actor. Capture continues during `.preparingModel` and after `.failed`; logic unit tests use `VADModelProcessing`, never network/model loading.
- VAD calls receive exact 4096-sample windows; leftover samples carry forward. FluidAudio's returned state is passed unchanged to the next window. All event/sample-to-chunk mapping uses source sample/monotonic positions, not task completion time.
- GapWatchdog follows the contract's arm/disarm rules exactly: intentional stop paths disarm before stopping, successful wake gets a 10-second grace window, and only a fresh heartbeat re-arms it. A stalled/dead capture outside grace cannot publish `.recording` beyond the 2/5-second thresholds.

**Acceptance criteria**

- Writer tests prove temp/final ordering, hourly split without loss/duplication, checksum/size/state updates, every close-reason terminal mapping, same-process writer recovery before replacement, idempotent close, write/rename/DB failures, and decodability of clean and deliberately unfinalized output. The EOS-less rotation file must play through the rotation point, and `ffprobe` duration must match persisted duration within one 20 ms frame.
- Fake-backed VAD tests prove arbitrary input block sizes become exact 4096-sample model calls, carry state, timestamp scores, map boundaries across chunk rotation, and reset after gaps.
- The opt-in real-model smoke test handles both cached and first-download paths and verifies offline reuse after caching.
- Pipeline tests with delayed/failing VAD prove audio writing continues; fake-clock tests cover device restart, overrun, heartbeat loss, and truthful snapshots. Two named tests are mandatory: pausing for one fake-clock hour produces zero `.gap`, `.error`, or watchdog restart events; waking after a long sleep and receiving audio within grace produces exactly one `.sleep`, one `.wake`, one measured sleep `.gap`, and no watchdog fault.

**Verification**

```bash
swift build --target PrivyCore
swift test --filter ShadowChunkWriterTests
swift test --filter VADServiceTests
swift test --filter ShadowCapturePipelineTests
PRIVY_VAD_SMOKE=1 swift test --filter FluidAudioVADSmokeTests
```

### W5 — Integration: thin app shell, menu UI, signing bundle, and run audit

**Files owned**

- all files under `Sources/Privy/`
- `scripts/build-app.sh`
- `scripts/verify-m1.sh`
- `Support/Info.plist` only if a production permission/bundle key is missing

**Scope**

Replace the spike startup with `AppCoordinator`, the sole composition root. It constructs paths/clock/store/writer/VAD/capture/pipeline/monitors, performs startup reconciliation, consumes monitor events, and exposes snapshots through a `@MainActor @Observable AppModel`. Keep `PrivyApp` and views dependency-free except for `PrivyCore`. Preserve stable Apple Development signing and `SMAppService.mainApp`.

The `MenuBarExtra` label and menu implement recording/paused/recovering/error icons; exact status text; current chunk elapsed time; today's disk bytes; last three health events; Pause 15 min / 1 h / until resumed; Resume; launch-at-login toggle; reveal audio/log location; and Quit. `Quit` awaits orderly pipeline shutdown before terminating. VAD preparation appears as secondary text such as “Recording — preparing speech model,” never as capture failure.

`scripts/verify-m1.sh` is read-only. Given DB/audio paths and a time window, it checks migration presence, stuck `recording` rows, orphan `.partial`/`.ogg` files, missing row files, zero-byte files, `ffprobe` decodability, chunk ordering, and **inter-chunk** gaps over 5 seconds without an overlapping structured health event. It also reports persisted `.queueOverrun` counts/durations but does not claim to independently detect unlogged holes inside an Ogg file. It exits nonzero with actionable rows/files; it never repairs or deletes. `--self-test` creates and removes a temporary SQLite/audio fixture using `sqlite3` and `ffmpeg`, exercises one passing case plus each failing invariant, and never reads live app data.

**Hard constraints**

- `AppModel` is main-actor-only; no closure created from it crosses into capture, CoreAudio, monitor, writer, or VAD callbacks.
- Menu state is derived only from the newest `PipelineSnapshot`; failure/recovery replaces the recording icon immediately.
- Startup continues recording when VAD model preparation fails, but not when Store or writer initialization fails.
- Existing bundle ID, stable signing identity discovery, `LSUIElement`, microphone usage text, and login-item behavior remain intact.

**Acceptance criteria**

- App launches as a menu-only signed app, records immediately after reconciliation, and shows all required menu controls/data.
- Menu transitions observed during pause, sleep/wake, input loss, restart, and injected writer error agree with persisted health and pipeline reality.
- Full test suite passes; release app builds/signs; audit script passes its fixture self-tests before the 48-hour run.
- Spike-only sources are removed without removing the standalone Opus spike target.

**Verification**

```bash
swift build --product Privy
swift test
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 dist/Privy.app
plutil -lint dist/Privy.app/Contents/Info.plist
./scripts/verify-m1.sh --self-test
```

## Dependencies and merge order

| Lane | Task | Genuine dependency | Merge-only dependency |
|---|---|---|---|
| 0 | Orchestrator applies `Package.swift` changes | current `main` | none |
| A | W1 contracts/clock/monitors | Lane 0 | none |
| B1 | W2 Store | W1 contract declarations | W3 and W4 are not needed; tests use fixtures |
| B2 | W3 capture | W1 contract declarations | W2 and W4 are not needed; tests consume streams directly |
| B3 | W4 writer/VAD/pipeline | W1 contract declarations | W2 and W3 implementations are not needed; tests use protocol fakes |
| C | W5 integration | merged W2 + W3 + W4 production implementations | none |

Launch W2, W3, and W4 concurrently from the W1 commit. They have zero file overlap and must not cherry-pick each other. Merge W2–W4, resolve only module-level compile mismatches in an orchestrator-owned integration commit, then launch W5. A mismatch caused by failure to follow the published contract is fixed in the owning worker's files; the orchestrator does not casually widen the shared API.

## End-to-end integration sequence

`AppCoordinator` performs this exact order:

1. Build `StorageLayout` and `SystemClock`; create directories.
2. Construct `PrivyStore`, migrate, and reconcile before any new writer opens.
3. Construct `ShadowChunkWriter`, `VADService`, `CaptureEngine`, and `ShadowCapturePipeline` with protocol-typed dependencies.
4. Bind the pipeline snapshot stream to `AppModel` on `MainActor`.
5. Start sleep/wake and device monitors; one coordinator task forwards their events to the pipeline.
6. Start capture immediately. In parallel, prepare FluidAudio VAD and expose `.preparingModel` until ready/failure.
7. Publish `.recording` only after the writer has accepted real audio and the heartbeat is current.
8. On termination request, stop monitors, close pipeline/writer, flush Store, then terminate. Crash correctness remains independent of this path.

There is one composition root and one owner for each long-lived task. `AppCoordinator` retains task handles, cancels them on shutdown, and prevents duplicate starts. Views contain no hardware, GRDB, FluidAudio, or file-system logic.

## M1 verification and 48-hour acceptance run

### Preflight

```bash
swift package resolve
swift build --product Privy
swift test
./scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 dist/Privy.app
open dist/Privy.app
```

Confirm microphone authorization is still authorized, enable launch at login, speak for two minutes, and verify the menu reports recording, an increasing current-chunk duration, increasing disk bytes, and VAD ready/preparing/error truthfully.

### Required fault schedule during one continuous 48-hour run

1. **Baseline:** leave the app recording for at least one hour and cross a normal rotation.
2. **Lid close:** sleep for at least two minutes, wake, and confirm the menu leaves recording during recovery and returns only after fresh audio.
3. **AirPods:** connect/select AirPods, then disconnect back to the default input. Confirm one coalesced device-change/restart sequence for each transition.
4. **Hard crash:** run `kill -9 "$(pgrep -x Privy)"`, wait at least 10 seconds, then `open dist/Privy.app`. Confirm startup reconciliation and a new recording chunk.
5. **Manual controls:** exercise Pause 15 min, Resume early, Pause 1 h then sleep/wake, and until-resumed.
6. **Input failure:** make the selected input unavailable long enough to cross the 5-second threshold; the menu must show recovering/error, never recording.
7. **Login launch:** after at least 24 hours, log out/in once and confirm the registered app resumes capture without a new TCC prompt.

At hour 48, use Quit and wait for `pgrep -x Privy` to return no process so the active chunk closes normally. Then run:

```bash
./scripts/verify-m1.sh \
  --db "$HOME/Library/Application Support/Privy/privy.sqlite" \
  --audio "$HOME/Library/Application Support/Privy/Audio" \
  --since-hours 48
```

M1 passes only when all of the following are true:

- Every non-empty audio file is represented by exactly one chunk row; no row remains `recording`; no ready row lacks a file; crash-preserved files are decodable or explicitly `failed` and preserved.
- Normal files average approximately 10 MB/hour at 24 kbps and rotate at one hour without sample loss/duplication.
- The audit finds no **inter-chunk** gap over 5 seconds lacking a corresponding sleep, pause, device-change, restart, recovery, or error health event. Within-chunk integrity is instead enforced by W3 sequence/sample accounting tests and surfaced persisted `.queueOverrun` telemetry; the script reports that telemetry but cannot independently infer an unlogged in-file hole.
- VAD score density is approximately one row per 256 ms of VAD-covered audio, excluding explicit `vadGap` intervals; speech boundary events have valid chunk-relative mappings.
- Health history proves lid-close, AirPods transitions, `kill -9`, input failure, and recovery. The menu was manually observed to leave recording immediately for each induced fault and return only after a real audio heartbeat.
- Launch-at-login still starts the signed app with microphone access and capture after logout/login.

A failed audit does not repair production data. Fix the defect, preserve the run artifacts, and restart the 48-hour acceptance clock for lifecycle/capture correctness changes.

## Top five risks and mitigations

1. **Swift 6 dynamic isolation can SIGTRAP on an audio or CoreAudio callback.** A closure lexically created under `@MainActor` may retain that isolation even when invoked on a realtime thread. **Mitigation:** callback factories are `nonisolated`; every crossing closure is explicitly `@Sendable`; capture only preallocated Sendable storage/atomics; never capture `self` or UI/store actors; thread-sanitized queue tests plus signed-app sleep/device fault testing are release gates.

2. **FluidAudio's real cadence is 256 ms, not the PLAN's obsolete 30 ms frame assumption.** In 0.15.5, `processStreamingChunk` accepts arbitrary sizes but its lower layer pads short input and silently truncates input beyond 4096 samples; an 8192-sample call can therefore lose half the VAD coverage while returning one plausible score. Boundary timestamps can also drift at hour rotation. **Mitigation:** the adapter, not FluidAudio, accumulates and submits exactly 4096 samples per call, preserves stream state, maps returned sample indices to the normalized 16 kHz timeline, attaches events by containing chunk, batches four or more DB rows, and asserts expected score density. M1 observes only; it never gates audio on these events.

3. **First-run VAD model download may be slow, offline, or appear to freeze the app.** Waiting for `VadManager` before capture would lose the first audio and misrepresent app health. **Mitigation:** start Store/writer/capture first, initialize VAD asynchronously, show “Recording — preparing speech model,” persist `vadPreparing`/`vadReady`/`vadError`, provide retry via app restart for M1, and verify both first-download and cached-offline smoke paths. Missing VAD coverage is an explicit `vadGap`, not a capture failure.

4. **Sleep/wake and AirPods can create notification storms, stale formats, or a dead engine that still reports running.** This is the likeliest source of silent gaps and lying menu state. **Mitigation:** coalesce device events for 500 ms, rebuild ring/converter/engine as one restart, use monotonic gap accounting, enforce 2-second recovery and 5-second error watchdog thresholds, and derive UI solely from post-heartbeat pipeline snapshots. The 48-hour fault schedule is mandatory.

5. **Backpressure, disk failure, or `kill -9` can split filesystem and SQLite truth.** VAD/model work must not stall encoding, and no transaction can atomically cover SQLite plus an Ogg rename. **Mitigation:** writer-first and isolated best-effort VAD lanes, bounded nonblocking capture queue with exact drop telemetry, one-second Ogg page flushes, five-second DB checkpoints, `.partial` + durable close + atomic rename + checksum, guarded state transitions, and idempotent preserve-first startup reconciliation. Any writer/Store failure immediately removes the recording icon.

## Definition of done

M1 is done only after W1–W5 are merged with no ownership violations, the full debug/release build and test commands pass, the signed bundle retains TCC/login-item behavior, and the 48-hour acceptance run satisfies every PLAN.md M1 criterion. Passing unit tests alone is not M1 completion.
