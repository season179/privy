VERDICT: REJECT

Findings (adversarial review of `git diff main..HEAD`, head 83a6653, 5 files). I built
`PrivyCore` (clean, Swift 6, no concurrency warnings) and ran the two named suites. The
ring and converter logic is largely sound (verification matrix at the end), but one
hard-constraint/acceptance violation is reproducible and lands as a blocker, plus one
production-fatal risk and two telemetry gaps.

1. **BLOCKER** — `Sources/PrivyCore/Capture/CaptureEngine.swift:276-285`
   `restart()` does not coalesce a notification burst; the acceptance test
   `concurrentRestartBurstCoalescesToOneAttempt` is flaky and fails intermittently.
   I ran it 5× in isolation: 4 pass, 1 fail with
   `Expectation failed: (unavailableCount → 2) == 1` (two full stop+start cycles ran).
   The implementation uses a single `await Task.yield()` to coalesce:
   ```swift
   public func restart(reason: RestartReason) async throws {
       guard !restarting else { return }
       restarting = true
       defer { restarting = false }
       await Task.yield()
       let stopReason: StopReason = reason == .deviceChange ? .deviceChange : .restart
       await stop(reason: stopReason)
       try await start()
   }
   ```
   A single yield only drains tasks *already blocked on the actor* at the suspension
   point. Tasks scheduled later by `withTaskGroup` (or, in production, by a 500 ms
   CoreAudio/NSWorkspace notification storm) enter after `defer` has reset
   `restarting = false`, see `!restarting`, and execute a second stop+start cycle —
   exactly the `unavailableCount == 2` the test caught. This violates:
   - hard constraint "stop/restart are idempotent under notification bursts";
   - top-five risk #4 mitigation "coalesce the CoreAudio/device-list/configuration
     burst for 500 ms";
   - the explicitly required acceptance test.
   Fix: replace the yield with a real debounce. Track a `nextRestartDeadline:
   ContinuousClock.Instant` (or `ManagedAtomic`-backed) set 500 ms in the future; a
   caller whose arrival is before the deadline sets the deadline forward and returns;
   a single scheduled task performs exactly one stop+start when the deadline elapses.
   Alternatively, drive restart from a coalescing flag that is only cleared after the
   burst window, not after `Task.yield()`. The test must then pass 100× in a loop, not
   ~80% of the time.

2. **MAJOR** — `Sources/PrivyCore/Capture/CaptureEngine.swift:173,207` and
   `Sources/PrivyCore/Capture/RealtimeAudioRing.swift:116-117`
   `maximumCallbackFrames` is hardcoded to 4_096 and used as a *hard reject bound* in
   the realtime path:
   ```swift
   guard frameCount > 0,
         frameCount <= maximumCallbackFrames, ...
   ```
   `AVAudioNode.installTap(onBus:bufferSize:format:block:)` documents `bufferSize` as a
   *hint* — "the engine might provide buffers of a different size." If the active device
   renders a buffer larger than 4_096 (e.g. 8_192, which real devices and virtual loops
   do deliver), every single callback fails the guard, is dropped whole, and produces a
   `.queueOverrun` — i.e. capture "starts" but records silence and floods overrun
   telemetry. The 48-hour run on arbitrary hardware can hit this.
   Fix: raise the bound to a generous ceiling (e.g. 16_384) that still fits the 8 s
   preallocation, *or* remove the hard reject and have `push` chunk an oversize buffer
   into successive `maximumCallbackFrames`-sized writes (preserving one sequence bump
   per source callback). The acceptance test for "maximum callback size" stays valid
   either way; production stops being fragile to the render quantum.

3. **MINOR** — `Sources/PrivyCore/Capture/CaptureEngine.swift:255-263`
   On a conversion failure mid-drain, `conversionTerminated` becomes true (drainOne,
   line 323) and the stop path skips `converter.finish()`:
   ```swift
   while !conversionTerminated, ring?.count ?? 0 > 0 { _ = drainOne() }
   if !conversionTerminated, let converter {
       if !output.yield(converter.finish()) { conversionTerminated = true }
   }
   ```
   The converter's in-flight partial package (up to 1_599 already-converted samples,
   < 100 ms) is then discarded by the subsequent `converter = nil` with no
   `.queueOverrun` accounting: those source frames were already popped (ring
   `acceptedReadFrame` advanced), so they are not in `takeDroppedSourceFrames()` and not
   in `discardAll()`. Only `.conversionFailed` fires. The plan requires that "any silent
   discard without accounting" be eliminated. Fix: when `conversionTerminated` is true
   at stop, compute the partial package's sample count and emit one `.queueOverrun`
   before nil-ing the converter, or have `drainOne`'s catch account the partial via the
   converter.

4. **MINOR** — `Sources/PrivyCore/Capture/CaptureEngine.swift:287-293`
   `drainLoop` busy-waits with `try? await Task.sleep(for: .milliseconds(1))` whenever
   the ring is empty. This is not a correctness defect (the contract only forbids
   waiting on the *producer*), but it pins a 1 ms wakeup forever, adds up to 1 ms drain
   latency before each new callback is converted, and there is no producer→consumer
   signal. For an always-on 48-hour recorder this is wasteful. Optional fix: a
   `ManagedAtomic` sequenced-byte semaphore or a `DispatchSemaphore` signaled from
   `push` when transitioning empty→non-empty (the tap would then do one non-blocking
   `signal`, which is bounded and allocation-free).

Priority-list verification (what I checked and found clean, to show coverage):
- a. **Tap realtime safety** — VERIFIED SAFE. `makeTap` is `nonisolated static`
  (CaptureEngine.swift:366-372), returns an explicit `@Sendable` closure capturing only
  the preallocated `RealtimeAudioRing` (@unchecked Sendable with an inline SPSC proof).
  `push` (RealtimeAudioRing.swift:108-164) does only scalar work, `UnsafeMutablePointer`
  `update(from:count:)` bounded copies, and `ManagedAtomic` ops; no `self`, allocation,
  lock, `await`, `Task`, conversion, logging, SQLite, or file I/O on that path.
- b. **Ring correctness** — VERIFIED. Producer publishes samples+metadata before
  `writeIndex.store(.releasing)`; consumer `readIndex.load(.acquiring)` (and the
  symmetric read→write pair via `acceptedReadFrame`/`readIndex`) gives a correct
  acquire/release SPSC with no overwrite of unread storage; the frame-capacity guard
  (`frameWrite &- frameRead + frameCount <= frameCapacity`) and slot guard
  (`write &- read < slotCount`) both reject the *newest whole callback*; sequence and
  `nextSourceFrame` advance on every callback including drops; metadata (sequence,
  sourceFrameStart, deviceSampleTime, hostTime, frameCount) round-trips through `pop`.
  `discardAll` correctly drains and accounts.
- c. **Conversion** — VERIFIED. One `AVAudioConverter` per `AudioConverter16k` instance;
  `CaptureEngine.start` builds a fresh converter+ring+epoch each start, and `stop` nils
  them, so mixed formats never share a converter. Discontinuity detection
  (`expectedNextSourceFrame`) flushes the partial, `converter.reset()`s, resets the
  feeder, and re-anchors `outputCursor` at the new normalized position — no discontinuous
  samples are joined. 1_600-sample packaging and cross-callback continuity are asserted
  by `converts44100MonoContinuouslyAcrossNonIntegerBoundaries` against a one-shot
  reference (max delta < 1e-4). `captureTime(for:)` back-dates `firstSampleTime` from
  `hostTime`, so drain latency does not shift capture time.
- d. **Stream overflow** — VERIFIED. `CaptureOutput` uses `.bufferingOldest(80)` exactly
  as frozen; every `yield` result is inspected; consecutive contiguous drops coalesce
  into one `.queueOverrun` with the exact summed frame range and
  `frames/privySampleRate` duration; `.terminated` stops conversion. The 82-block test
  proves 80 retained + 3_200 dropped frames / 0.2 s telemetry.
- e. **Lifecycle** — Mostly verified; the one failure is finding #1. `start` with no
  input emits `.inputUnavailable` and throws before `installTap` (test
  `captureStartWithoutInputReportsUnavailableAndNeverStarted`); `stop` is idempotent via
  the `guard running || tapInstalled || drainTask != nil` gate.
- f. **Swift 6 concurrency** — VERIFIED. `swift build --target PrivyCore` is clean under
  strict concurrency (only an unrelated FluidAudio resource warning). `@unchecked
  Sendable` is used only on `RealtimeAudioRing` with a documented proof; all crossing
  closures are `@Sendable` from `nonisolated` factories; `CaptureEventEmitter`,
  `CaptureOutput`, `ConversionInputFeeder` are genuinely `Sendable`.
- g. **Test honesty** — Mostly strong (real `AVAudioConverter`, real ring push/pop,
  producer-faster-than-consumer at 100 k callbacks, non-integer 44.1 kHz, channel mix,
  gap reset). Gaps: no explicit non-integer resampling *boundary* assertion beyond
  44.1 kHz (e.g. 22.05 kHz or 47.99 kHz edge cases are not exercised), and the
  coalescing test is non-deterministic (finding #1). TSan variant was not run here per
  instructions; the acquire/release ordering in the ring reads correctly by inspection.

## Re-review

Re-examined delta `83a6653..6532891` (commits b4977fb "Accept larger audio callbacks",
6532891 "Debounce capture restart bursts"). Built `PrivyCore` (clean, Swift 6, zero
concurrency warnings), ran `RealtimeAudioRingTests` (6/6) and `AudioConverterTests`
(9/9), and ran `concurrentRestartBurstCoalescesToOneAttempt` 10× in isolation (10/10
pass — the prior ~1-in-5 flakiness is gone). TSan not re-run by me (instructed); user
reports TSan clean.

Finding-by-finding:

1. **Restart debounce (BLOCKER #1) — RESOLVED, race-free.** `CaptureEngine.restart`
   (CaptureEngine.swift:324-336) now records a monotonic deadline + coalesced reason,
   creates exactly one `pendingRestartTask` the first time, and absorbs every subsequent
   caller via `guard pendingRestartTask == nil else { return }`. `performDebouncedRestart`
   (338-354) loops on `restartDeadlineMonotonic` with a swappable `CaptureEngineSleeping`
   seam, breaking only when `remaining <= 0`; the `defer` clears task/deadline/reason so a
   failed attempt cannot leak state into the next burst.
   - Race-free: all restart state mutations are synchronous on the actor up to the
     `try await task.value` suspension; the task cannot enter `performDebouncedRestart`
     until the first caller yields the actor, which is strictly after `pendingRestartTask`
     is assigned. Absorbed callers extend the deadline/reason atomically.
   - Error propagation: correct and matches the documented intent. Only the first caller
     awaits `task.value`; absorbed callers return cleanly. Nothing material is lost
     because every failure is still surfaced on the event stream (`.inputUnavailable` /
     `.conversionFailed`), which is the contract's source of observed reality. The
     pipeline derives state from events, not from per-call error returns.
   - Test is now deterministic (`RestartTestClock` frozen monotonic time +
     `ManualCaptureEngineSleeper` blocking on a continuation): the burst runs with the
     clock frozen, the test advances 0.5 s and resumes once, exactly one stop+start fires.
   Minor observations (non-blocking, all acceptable for the intended device-burst use case):
   - **MINOR** Trailing-edge debounce: a hypothetical *sustained* stream of calls
     (<0.5 s apart forever) would extend the deadline indefinitely and never fire. Real
     CoreAudio/NSWorkspace bursts are finite and settle in <1 s, and the pipeline layer
     debounces too, so this is theoretical. Flagging only so it is a conscious choice.
   - **MINOR** A restart call arriving *during* the post-sleep stop+start phase is
     absorbed, but its coalesced reason is then discarded by `defer` (the in-flight
     attempt already captured its own reason). The engine still restarts, so the effect
     is satisfied; only stop-reason telemetry for that late reason is approximate.
     `.deviceChange` is preserved-if-any via `coalescedRestartReason`, and the writer's
     terminal-state table maps `.restart` and `.deviceChange` identically, so no
     downstream correctness impact.
   - **MINOR** `pendingRestartTask` is not cancelled by `stop()`/`shutdown`; a pending
     restart will fire `start()` after a manual stop. This is a W4 pipeline-lifecycle
     responsibility (do not call `restart` after `shutdown`), not a W3 contract breach.

2. **16384-frame ceiling + 4096 tap hint (MAJOR #2) — RESOLVED.** `tapBufferHintFrames
   = 4_096` is passed to `installTap` while `maximumCallbackFrames = 16_384` is the hard
   bound (CaptureEngine.swift:217-220). Preallocation is consistent: `RealtimeAudioRing`
   `frameCapacity = ceil(sampleRate * 8)` is independent of `maximumCallbackFrames`
   (RealtimeAudioRing.swift:81-84), so the 8 s guarantee is unchanged; the scratch buffer
   is allocated at `frameCapacity: AVAudioFrameCount(maximumCallbackFrames)` = 16 384
   (CaptureEngine.swift:236-240). The `pop` precondition was correctly relaxed from
   `destination.frameCapacity >= maximumCallbackFrames` to `>= item.frameCount`
   (RealtimeAudioRing.swift:175, moved after the slot read) — more precise and always
   satisfied by the scratch buffer since `item.frameCount <= 16 384`. New test
   `callbackLargerThanTapHintIsCapturedWhole` proves an 8192-frame callback is accepted
   whole and round-trips. Memory cost (~128 KB scratch for stereo, ring unchanged at
   ~3 MB for 8 s stereo) is trivial.

3. **finalizeConversion partial-package accounting (MINOR #3) — RESOLVED, exact, no
   double-count.** `CaptureOutput.finalizeConversion(_:afterTermination:)`
   (CaptureEngine.swift:113-125) calls the new `AudioConverter16k.discardPendingPackage()`
   (AudioConverter16k.swift:188-196), which claims the partial via `takePartialPackage`,
   resets converter/feeder, and returns the block; the caller emits one `.queueOverrun`
   with `block.samples.count` normalized frames and `count/privySampleRate` duration.
   Traced the failure path end-to-end: on a `drainOne` conversion throw, the partial
   package holds only samples from *previously popped and converted* callbacks; those
   source frames already advanced `acceptedReadFrame` so they are absent from both
   `takeDroppedSourceFrames()` and `discardAll()`. The failed callback's own frames are
   accounted by the separate `emitDiscardedSourceFrames(metadata.frameCount)`. The second
   `finalizeConversion` call in `stop()` finds `packageSamples` already empty
   (`takePartialPackage` cleared it) and emits nothing — verified no re-emit. New test
   `conversionFailureSurfacesPendingPackageAsExactOverrun` asserts exactly 800 frames /
   0.05 s with the correct `firstSampleTime`.
   - **MINOR** (test-honesty gap, not a code defect): the test exercises
     `finalizeConversion` directly rather than driving the full `drainOne` → catch →
     `finalizeConversion` + `emitDiscardedSourceFrames` path through the actor, so the
     two-events-on-failure sequencing is verified by inspection only. Optional
     end-to-end test would harden it.
   - Note: the partial-package overrun reports normalized (16 kHz) frame counts in the
     `droppedSourceFrames` field. This is *consistent* with the pre-existing
     converted-stream overrun convention (`emitOverrun` already does the same) and the
     duration — which is what `verify-m1.sh` consumes — is exact. Not a regression.

4. **Finding 4 (1 ms drain poll) — CONFIRMED DEFERRED/UNCHANGED.**
   `drainLoop` still does `try? await Task.sleep(for: .milliseconds(1))` when idle
   (CaptureEngine.swift:373). Still MINOR and acceptable; the contract only forbids
   waiting on the realtime producer, not the consumer task.

5. **No API widening, no regressions.** Public surface is byte-identical to the first
   review: `public actor CaptureEngine`, `public nonisolated let streams`,
   `public init(clock:)`, `public func start/stop/restart`. Every new seam
   (`CaptureEngineSleeping`, `ContinuousCaptureEngineSleeper`,
   `CaptureOutput.finalizeConversion`, `AudioConverter16k.discardPendingPackage`,
   the `internal init(clock:forceInputUnavailable:restartDebounceSeconds:restartSleeper:)`)
   is `internal`. `RealtimeAudioRing`/`AudioConverter16k` remain fully `internal`.
   Build is warning-clean under Swift 6 strict concurrency; the new `Task<Void, Error>`
   captures `[weak self]` on the actor and hops correctly, and `pendingRestartTask`
   state is confined to the actor. Ring SPSC/converter/tap-realtime-safety conclusions
   from the first review are unchanged by this delta.

All three actionable findings are correctly fixed with exact accounting and
race-free state machines; the two remaining items are the explicitly-deferred MINOR
poll and minor non-blocking observations. No blockers remain.

RE-VERDICT: APPROVE
