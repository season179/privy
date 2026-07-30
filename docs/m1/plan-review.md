# M1 plan review (adversarial)

**Verdict: APPROVE-WITH-CHANGES.** Hunted hard for a blocker across all seven attack surfaces and did not find one that makes the plan unimplementable as written — but found three MAJOR specification holes that will produce divergent W2/W4 implementations or a failed hour-48 audit if workers launch without resolving them. All MAJORs should be fixed in the contract text before W1 lands; MINORs can be fixed in the owning worker's lane.

## Findings

### 1. [MAJOR] §Writer and VAD contracts + §Crash and lifecycle invariants — `close(reason:)` terminal-state mapping is undefined, and same-process writer failure can strand a `recording` row until the next launch

The writer contract exposes `close(reason: StopReason, at:)` and `StopReason` includes `.fatalError`, `.systemSleep`, `.deviceChange`, `.restart`, `.manualPause` — but nothing in the plan says which reasons finalize the chunk as `ready` versus `failed`, and reconciliation is specified as *startup-only* (§Crash and lifecycle invariants, case 5: "Kill/relaunch: no shutdown hook is assumed"). The only same-process failure language is invariant 6: "A DB or writer failure immediately leaves `.recording` UI state and keeps retry/recovery evidence" — which addresses the icon, not the row.

Concrete failure: W5's own acceptance injects a writer error mid-run. The pipeline leaves `.recording`, retries, and `ShadowChunkWriter` opens a *new* chunk. The abandoned row stays `recording` for the rest of the process lifetime, violating invariant 6's "exactly one row is `recording`" and verify-m1's "no row remains `recording`". Per the plan's own rule, that discovery at hour 48 "restart[s] the 48-hour acceptance clock". Alternatively, if W4 guesses and `close(.fatalError)` marks the chunk `ready`, possibly-corrupt audio gets a clean state.

**Fix:** add an explicit `close(reason)` → terminal-state table to the writer contract: `.manualPause`/`.systemSleep`/`.deviceChange`/`.restart` → normal finalize to `ready`; `.fatalError` → preserve the file, finalize from the last checkpoint if decodable, else `failChunk`. And require the pipeline to terminally transition the abandoned row (via `failChunk` or checkpoint-finalize) *before* opening a replacement chunk in the same process — i.e., extend the reconciliation rules from startup-only to writer-recovery.

### 2. [MAJOR] §Monitor, health, and pipeline state + invariant 4 — GapWatchdog gating across intentional stops and sleep/wake is unspecified

The state contract says: "`.recording` requires ... an audio heartbeat less than 2 seconds old. Missing frames for 2 seconds triggers `.recovering` plus one restart attempt; at 5 seconds it becomes `.error` and persists a `.gap`." It never says the watchdog is armed only in `.recording`. Two concrete bad readings:

- **Pause:** manual pause stops the engine by design (invariant 4). Heartbeat goes stale; 2 s later the pipeline enters `.recovering` and fires a restart attempt *during an intentional pause*; at 5 s it persists a spurious `.error` + `.gap`. Every pause manufactures false health rows and a racing restart.
- **Sleep:** if `willSleep` processing loses the race (or the machine sleeps between heartbeat checks), the process is suspended with a stale heartbeat. On wake, the watchdog timer and `didWake` fire in an unspecified order; if the watchdog wins, a spurious `.error`/`.gap` plus a restart attempt fires while the device may not be re-enumerated yet, racing the `didWake` restart.

Either reading fails W5's acceptance: "Menu transitions observed during pause, sleep/wake ... agree with persisted health and pipeline reality."

**Fix:** state explicitly that GapWatchdog is armed only while in `.recording`, is disarmed before any intentional engine stop (pause, `willSleep`, device-change rebuild), and that `didWake` opens a defined recovery grace window during which heartbeat staleness is attributed to the sleep event rather than a new fault. Add a fake-clock test for each: pause-for-1h produces zero `.gap`/`.error` rows; wake-after-long-sleep produces exactly one `.sleep`/`.wake`/measured-gap sequence.

### 3. [MAJOR] §Store contract + §Monitor, health, and pipeline state — `HealthEvent.severity` has no persistence mapping

`HealthEvent` carries `severity: HealthSeverity` as a top-level field, but the locked schema is `health(id, at_utc TEXT, kind TEXT, detail TEXT)` and the plan says the Store "encodes this as JSON in `health.detail`" — where "this" is `HealthDetail`, which has no severity field. As written, severity is silently dropped on persist, or W2 and W4 each invent their own encoding (W4 writes it, W2's `menuSummary` reads it back for "last 3 health events" and the icon alert state depends on it).

**Fix:** define in the contract that `health.detail` stores a JSON object `{"severity": "...", "detail": { ...HealthDetail fields... }}` (or move `severity` into `HealthDetail`), and add a W2 round-trip test asserting severity survives persist/read.

### 4. [MINOR] §Runtime architecture (req 4) — the bounded-queue story stops at the ring; the conversion→pipeline `AsyncStream` is unbounded

The realtime producer is carefully bounded (8 s SPSC ring, exact drop accounting), but `CaptureStreams.audio` is an `AsyncStream` with the default unbounded buffering policy, and the pipeline's first hop is an actor (`ShadowChunkWriter.append`) whose serial path includes rotation-time work: Ogg finish + rename + SHA-256 of ~10 MB + a GRDB write. A stall there (disk pressure, slow external volume) buffers converted Float audio invisibly at ~3.8 MB/min with no drop telemetry — the exact silent-backpressure failure req 4 exists to prevent, one hop downstream of where the plan stops looking.

**Fix:** specify a buffering bound for the capture streams (e.g. `.bufferingOldest(N)` with the dropped blocks converted into the same `.queueOverrun` accounting as ring overflow), or explicitly document that any writer stall transitions to `.error` and finishes the stream rather than buffering.

### 5. [MINOR] §Crash and lifecycle invariants (kill/relaunch case 1) — crash-recovered rows persist checkpoint-stale size/duration against a real checksum

Case 1 ("`recording` row + `.partial`") says: "checksum, mark `ready` using the last checkpoint". The checkpoint is up to 5 s stale, but the file on disk is up to ~1 s stale (force-flushed pages) — so `size_bytes` and `duration_s` in the recovered row will under-report the actual file, while `checksumSHA256` is computed from the real bytes. The row and the file then permanently disagree, and M2 range extraction / M5 upload verification inherit the skew.

**Fix:** at reconciliation, set `size_bytes` from the filesystem and `duration_s` from decoded samples (or ffprobe), falling back to the checkpoint only when the file is undecodable (in which case the row should be `failed` anyway).

### 6. [MINOR] §Store contract — `StorageLayout.quarantineDirectory` is dead contract surface

`StorageLayout` defines a `quarantineDirectory`, but none of the five reconciliation cases moves anything there — every case preserves in place ("never discard or overwrite it", "remain preserved ... for inspection"). W2 must either invent a use or ignore a public field; W5's verify script won't know whether to look there.

**Fix:** either specify the semantics (e.g. empty/unreadable files and path-traversal suspects are moved to `Quarantine/` with the row's relative path updated) or delete the field from the contract.

### 7. [MINOR] W1 hard constraints vs W3 reality — the `@unchecked Sendable` budget is under-scoped for the SPSC ring

W1's hard constraints permit `@unchecked Sendable` only for "a small event-emitter wrapper". But W3's ring — preallocated `UnsafeMutable` sample storage plus `ManagedAtomic` indices, captured by the explicitly `@Sendable` tap closure — is necessarily a reference type and cannot be checked-`Sendable`. The plan's tap discipline ("captures only the preallocated ring producer plus atomic counters") is correct, but the ring's own `Sendable` story is nowhere stated, so W3 either silently widens the W1-stated policy or contorts the design to avoid it.

**Fix:** explicitly bless `RealtimeAudioRing` as `@unchecked Sendable` in the contract text, with the SPSC invariant (single producer = tap thread, single consumer = drain task, acquire/release index ordering, no resize after `installTap`) documented inline as the justification.

### 8. [MINOR] W4 scope/acceptance — VADService unit tests are not implementable as specified without an undeclared seam

W4 acceptance requires proving "arbitrary input block sizes become exact 4096-sample calls, carry state, timestamp scores" — i.e., observing the FluidAudio boundary. But `VadManager` is a concrete `public actor` (verified in the 0.15.5 checkout); its logic-only `init(skipModelLoading:)` is `internal` to FluidAudio; there is no protocol to fake. Without either the real model (network download — wrong for a unit test) or a PrivyCore-internal wrapper protocol around `processStreamingChunk`/`makeStreamState`, the required tests can't intercept anything.

**Fix:** add an internal `VADModelProcessing` protocol seam to the W4 section (just `makeStreamState()` + `processStreamingChunk`), make `VADService` generic over it, and reserve the concrete `VadManager` for the opt-in smoke test.

### 9. [MINOR] W4 hard constraints + `Sources/OpusIO/OggOpusWriter.swift` — the no-synthesized-tail close path interacts with hardcoded granulepos

W4 correctly catches that `finish()` injects a full 20 ms zero frame at exact rotation boundaries. But `encodeFrame` also hardcodes `granulePos += 960` (20 ms in 48 kHz units) per packet. The replacement close path — a minimal 2.5 ms Opus pad frame, or EOS-less termination (no final packet; ogg decoders tolerate a missing EOS page, and PLAN.md's spike already proved crash-truncated files decode fully) — must advance granulepos by the *actual* padded amount, or every file's ffprobe duration skews up to ~18 ms, degrading verify-m1's chunk-ordering/rotation checks.

**Fix:** require the new close path to compute granulepos from actual padded samples (or explicitly choose EOS-less termination), and assert ffprobe-reported duration matches persisted `duration_s` within one frame in `ShadowChunkWriterTests`.

### 10. [MINOR] W5 scope + §M1 verification — verify-m1.sh cannot audit within-chunk holes

"Gaps over 5 seconds without an overlapping structured health event" is only detectable *between* chunks (from `started_at_utc` + `duration_s` adjacency). Within a chunk, dropped callbacks are collapsed by the writer into continuous audio — the `.ogg` carries no timestamp trace of the hole, so the script cannot cross-check in-chunk losses against `.queueOverrun` rows. The "no silent gaps >5 s unlogged" acceptance criterion is therefore only half-auditable; in-chunk silence rests entirely on the health-writer's honesty.

**Fix:** either scope the audit claim explicitly to inter-chunk gaps, or persist sample-timeline discontinuities (e.g. a `gaps` table or column populated from `streamSampleStart` jumps and overrun telemetry) that verify-m1.sh can sum per chunk.

## Checked, no finding

- **FluidAudio 0.15.5 API claims** — verified against the pinned checkout: `VadManager` is a `public actor`; `processStreamingChunk(_:state:config:returnSeconds:timeResolution:)` signature matches; the >4096-sample silent truncation and repeat-last padding claims are true (`VadManager.processChunk` takes `prefix(4096)`); `VadStreamState`/`VadSegmentationConfig` exist with public inits; model cache path is `~/Library/Application Support/FluidAudio/Models`.
- **Verification commands** — `swift test --filter <SuiteName>` confirmed working with swift-testing on the installed 6.3.3 toolchain (ran against the repo's placeholder suite); `--sanitize=thread` is a valid SwiftPM option form; TSan is supported on arm64 macOS.
- **Worker split** — zero-file-overlap claim holds (checked every owned path across W1–W5); W2/W3/W4 are genuinely independent given the W1 contracts; W4's protocol-fake strategy works for `PrivyStoring`/`AudioCapturing`/`VADAnalyzing`/`ShadowChunkWriting` (all five dependencies are W1 contracts or pre-existing OpusIO).
- **PLAN.md M1 acceptance coverage** — every M1 deliverable and acceptance line maps to a plan section (fault schedule + verify-m1.sh); no contradictions with locked decisions found. The §3 dropdown's "speech minutes" is not in the M1 deliverables list, so its absence from the W5 menu spec is consistent.
- **Reconciliation windows** — the five cases plus orphan/traversal/idempotency tests cover all realistic kill-9 windows given the committed-before-open DB ordering and atomic rename; the remaining hole is same-process recovery (finding 1), not crash recovery.
