VERDICT: APPROVE

Adversarial cross-model review of W5 branch `w5-integration` at `fe56730`
(4 commits, `main...HEAD`: 9 files, +856/−154). Reviewer: kimi k3. Implementer:
openai-codex/gpt-5.6-sol. Read in full: `docs/m1/plan.md` (W5 section, end-to-end
integration sequence, crash/lifecycle invariants, M1 verification), `docs/m1/w3-review.md`,
`docs/m1/w4-review.md`. Evidence gathered: full file reads of every changed source,
cross-checks against the W2 schema (`Sources/PrivyCore/Store/DatabaseMigrations.swift`,
`DatabaseRecords.swift`), the pipeline (`ShadowCapturePipeline.swift`), `Package.swift`,
`Support/Info.plist`, `scripts/build-app.sh`; ran `swift build --product Privy`
(clean, Swift 6, 1.62 s incremental) and `./scripts/verify-m1.sh --self-test`
(11/11 fixture cases pass: passing case + all 10 required failing invariants).
No heavy builds; the self-test touches only its own mktemp fixtures.

## Attack results by priority

### 1. AppCoordinator startup order — VERIFIED CORRECT
`Sources/Privy/AppCoordinator.swift:52-96` (`performStart`) implements the plan's
end-to-end sequence in exact order:
1. `AppPaths.ensureDirectoriesExist(AppPaths.productionLayout())` (line 54) — paths+dirs.
2. `PrivyStore(databaseURL:)` → `prepareDatabase()` → `reconcile(storage:at:)` (58-63) —
   migrate/reconcile before any writer opens.
3. `PrivyRuntimeFactory.makeShadowCaptureController(store:storage:clock:)` (70-74) —
   controller graph with protocol-typed deps (factory confirmed at
   `Sources/PrivyCore/Recording/PrivyRuntimeFactory.swift:12-26`).
4. `bindSnapshots(from:)` (82) — snapshot stream bound to `AppModel` via a Task that hops
   `await model.apply(snapshot)` (105-114).
5. `sleepMonitor.start()` / `deviceMonitor.start()` (83-86), then
   `forwardMonitorEvents(...)` (88-92) — one coordinator-owned forwarding task.
6. `await controller.start()` (94) — capture. VAD preparation is parallel inside
   `ShadowCapturePipeline.start()` (`vadPreparationTask`, pipeline lines 144-148), so VAD
   download/failure never blocks capture; pipeline publishes `.recording` only after a
   written block + fresh heartbeat (pipeline line 161 comment, W4-approved logic).
- Mic-permission insertion (line 66-68, commit 66b4627): `await
  AVCaptureDevice.requestAccess(for: .audio)` sits between reconcile and graph
  construction. Denied → `MicrophoneDenied` with actionable System Settings path (14-18);
  capture never starts, permission state never lies. Async API exists on macOS 14+;
  deployment target is 15 (Package.swift line 7) and the build compiles.
- VAD failure isolated: yes (pipeline-level, W4 round-2 finding 2 fixed and re-verified).
- Store failure prevents false recording: any throw in store init/prepare/reconcile lands
  in the generic catch (97-100) → `tearDownRuntime()` + `model.reportBootstrapError`;
  `controller` is never started, menu shows "Error", no recording claim. Independently,
  `ShadowCapturePipeline.start()` itself re-checks store health via `menuSummary` and
  enters `.error` without starting capture on failure (pipeline lines 110-124).

### 2. Task ownership, duplicate start/shutdown, no post-shutdown restart — VERIFIED
- One owner per task: `startupTask`, `snapshotTask`, `monitorForwardingTask` are all
  retained and cancelled by `AppCoordinator` alone (25-27, 168-193). Long-lived
  capture/VAD/writer tasks are owned by the pipeline (W4 scope, approved).
- Duplicate start: `start()` guards `lifecycle == .idle` (36); after any start the
  lifecycle never returns to `.idle`, so there is no post-shutdown or post-failure
  restart path (verified: the only transitions to `.stopped` are terminal).
- Duplicate shutdown: `tearDownRuntime` sets `lifecycle = .shuttingDown` synchronously at
  entry before any await (176-179); re-entrant `shutdown()` hits `case .shuttingDown:
  return` (168). `AppDelegate.applicationShouldTerminate` additionally guards with
  `terminationTask == nil` (PrivyApp.swift:40).
- Shutdown-during-startup race: closed. `startupTask` is assigned synchronously before
  `start()`'s first suspension (43-46), so a re-entrant `shutdown()` (case `.starting`,
  158-162) always sees it; it sets `shutdownRequested`, awaits the task, and
  `requireStartup()` checkpoints (99-103) convert the interruption into
  `StartupInterrupted` → `tearDownRuntime`. The final `try requireStartup()` after
  `controller.start()` (95) is in the same synchronous segment as `lifecycle = .running`,
  so a shutdown cannot interleave between them.
- Monitor forwarding cancelled/stopped before controller shutdown: `tearDownRuntime`
  (172-193) cancels the forwarding task, stops both monitors, awaits the forwarding
  task's quiescence (task-group children inherit cancellation and check
  `Task.isCancelled`, 121-134), and only then calls `controller.shutdown()`. The comment
  at 170-172 correctly identifies the restart-after-shutdown hazard this prevents. No
  post-shutdown restart path exists: pipeline `shutdown()` sets `shuttingDown` and cancels
  `deviceRestartTask` (pipeline lines 170-178).
- Quit truly awaits shutdown: `applicationShouldTerminate` returns `.terminateLater`,
  awaits `coordinator.shutdown()`, then `NSApp.reply(toApplicationShouldTerminate: true)`
  (PrivyApp.swift:39-46); the reply is on MainActor because the Task inherits the
  delegate's isolation. The menu Quit button is disabled and re-labeled "Quitting…" once
  `isShuttingDown` (MenuView.swift:87-91).

### 3. Main-actor AppModel / Swift 6 isolation / menu truth — VERIFIED
- `AppModel` is `@MainActor @Observable` (AppModel.swift:7-9); every cross-actor call is
  an `await` hop. No closure created from AppModel or the views crosses into capture,
  CoreAudio, monitor, writer, or VAD callbacks — the only view-origin closures are
  `Task { await coordinator.pause/resume }` (MenuView.swift:44-56), which hop to the
  coordinator actor and never touch hardware. Coordinator tasks capture only Sendable
  protocol references (`any ShadowCaptureControlling`, streams) and the MainActor model
  accessed via await.
- Menu derives only from the newest `PipelineSnapshot` (bufferingNewest(16) at pipeline
  init; `AppModel.apply` overwrites `snapshot`). All rendering — `statusTitle`,
  `statusDetail`, `iconName`, `canPause/canResume`, elapsed, bytes, health — switches on
  `snapshot.capture` and distinguishes starting/recording/paused/recovering/error/
  stopped (AppModel.swift:47-105). Failure/recovery replaces the recording icon
  immediately (`exclamationmark.triangle.fill` / `arrow.clockwise.circle`).
- VAD honesty: during `.recording`, VAD `.preparingModel`/`.failed` renders only as
  secondary detail — "Preparing speech model — recording continues" / "Speech model
  unavailable — recording continues: …" (AppModel.swift:63-66) — never as capture
  failure, per the plan's exact requirement.
- Permission state does not lie (finding in §1); bootstrap error clears on first real
  snapshot (`apply`, line 21) and `reportBootstrapError` is suppressed once a snapshot
  exists (29-31) so stale error text cannot mask live truth.
- `swift build --product Privy` is clean under Swift 6 language mode (tools-version 6.0).

### 4. Required menu data/actions — VERIFIED COMPLETE
Status title+detail (MenuView.swift:7-14), current-chunk elapsed (17; monotonic-aware via
`max(chunk.durationSeconds, heartbeatElapsed)`, AppModel.swift:111-117), today's bytes
(18; live-updated by the pipeline at line 1074), last three health events newest-first
(22-32, AppModel.swift:129-131), Pause 15 min / 1 h / until resumed (43-55), Resume
(58-62), launch-at-login toggle (64-73) with `.requiresApproval` surfaced as "Allow Privy
in System Settings → General → Login Items." (AppModel.swift:38-45 — register() succeeds
but `status == .requiresApproval ≠ .enabled`, so `isRegistered` is false and the guidance
appears; toggle-off is a no-op guard, LoginItem.swift:9-15), Reveal Audio / Reveal App
Support + Logs via `NSWorkspace.activateFileViewerSelecting` (76-84, 94-97), Quit
(87-91). Accessibility labels on every control and the menu-bar icon
(MenuBarLabel.swift:7-8). `LSUIElement`, mic usage text, bundle ID, and stable
Apple-Development signing discovery are intact (Support/Info.plist unchanged;
scripts/build-app.sh unchanged, which the plan permits).

### 5. Signed menu-only bundle, forbidden imports — VERIFIED
`grep "^import" Sources/Privy/`: AppKit, SwiftUI, ServiceManagement, AVFoundation,
Foundation, Observation, PrivyCore only. No GRDB/FluidAudio/OpusIO imports; Package.swift
`Privy` target depends only on `PrivyCore` (line 31). Views contain no hardware/store/
filesystem logic beyond Finder reveal.

### 6. scripts/verify-m1.sh — VERIFIED, self-test run locally
- Read-only: all DB access via `sqlite3 -readonly` (`readonly_sql`, line 52) or
  `:memory:` for time math (`memory_sql`, line 48); self-test writes only under
  `mktemp -d` and removes it via `trap … EXIT INT TERM` (183-185). No repair/rename/
  delete anywhere; `--db`/`--audio` have no defaults pointing at live data, and each
  self-test case spawns a fresh script process with explicit fixture paths (211-214).
- Quoting/strict mode: `set -euo pipefail`, `LC_ALL=C`, `sql_quote` doubles single
  quotes and SINCE/UNTIL are additionally validated by `julianday(...) IS NOT NULL`
  (82-98); `--since-hours` is validated as a positive number before interpolation
  (67-71); all path expansions quoted; `fail()` runs in the current shell via process
  substitution so `fail_count` survives (no pipe subshell bug).
- SQL correctness against the real W2 schema: `grdb_migrations.identifier =
  'v1_create_schema'` matches GRDB + `DatabaseMigrations.swift:28`; column names
  `chunks(started_at_utc, duration_s, audio_path, state)` and `health(at_utc, kind,
  detail)` match the migration exactly; the envelope extraction
  `json_extract(h.detail,'$.detail.gapStartedUTC')` matches the locked HealthEnvelope
  shape `{"severity":…,"detail":{…}}` and the store's µs-precision
  `yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'` dates parse under `julianday` (confirmed empirically:
  the self-test fixture uses 6-digit-fraction `Z` strings and window filtering works).
- Time-window filtering, stuck-`recording`, duplicate rows (both in-window GROUP BY and
  global via the file walk's `ROW_COUNT`), orphan `.partial`/`.ogg` (orphans force
  `selected=1` so they're caught even outside the window), ready-row missing files with
  path-traversal rejection, zero-byte, `ffprobe` decodability for every non-`failed`
  artifact, chunk ordering (LAG-based overlap with 50 ms tolerance), and unexplained
  inter-chunk gaps > 5 s with the plan's full evidence-kind list plus the JSON gap-span
  branch — all present and each has a passing self-test fixture (I ran it: 11/11).
- Queue-overrun telemetry reported as INFO count + summed `durationSeconds` with the
  honest limitation line (163-165); exit status nonzero with actionable rows/files on
  failure, zero on pass; no live-data access or mutation.

### 7. Spike removal / scope — VERIFIED
`Sources/Privy/CaptureSpike.swift` and `Sources/Privy/SpikeLog.swift` deleted (130 lines),
zero remaining references repo-wide; `OpusSpike` executable target retained as the
standalone diagnostic and not linked into `Privy.app`. `Tests/PrivyTests/PrivyTests.swift`
is byte-identical to `main` (already a trivial placeholder there). No M2 surface added;
`Support/Info.plist` and `build-app.sh` untouched, as allowed.

## Findings

No BLOCKERs, no MAJORs.

1. **MINOR (test gap)** — `Sources/Privy/AppCoordinator.swift` is constructed only from
   concrete types (`PrivyStore`, `PrivyRuntimeFactory`, `AVCaptureDevice`,
   `SleepWakeMonitor`/`AudioDeviceMonitor`), so its lifecycle state machine — duplicate
   start, shutdown-during-startup interruption, teardown ordering, bootstrap-error path —
   has zero automated tests. The logic is small and was verified by trace here (§2), but
   a protocol/factory seam would make the exact-order and interruption invariants
   regression-testable without hardware.
2. **MINOR** — `AppCoordinator.swift:66-68` + `158-162`: quitting during the first-run
   TCC prompt blocks termination until the user answers the prompt, because
   `shutdown()` (case `.starting`) awaits `startupTask`, which is suspended inside
   `AVCaptureDevice.requestAccess`. The prompt is on screen and answering it unblocks the
   quit; no deadlock, no false state. Acceptable for M1; a cancellation-wins race would
   be nicer.
3. **MINOR** — `AppCoordinator.swift:197-200`: the bootstrap-error suffix "Check free
   disk space and access to Library/Application Support/Privy…" is appended even when the
   cause is microphone denial; the mic-specific guidance is present earlier in the same
   message (`MicrophoneDenied.errorDescription`, 14-18), so the user is not misdirected,
   but the generic tail is mildly noisy.
4. **MINOR** — `AppCoordinator.swift:137-145` vs `AppModel.swift:99-104`: `canPause` is
   true for snapshot `.starting`, but `coordinator.pause` silently no-ops unless
   `lifecycle == .running`. A click in the narrow startup window does nothing with no
   feedback. Harmless (pipeline isn't capturing yet; pause is meaningless there), but the
   enabled/disabled truth is slightly ahead of the coordinator's.
5. **MINOR (audit edge)** — `scripts/verify-m1.sh` window-filters stuck-`recording`,
   duplicate (GROUP BY), and ready-missing-file checks on chunk *start* time
   (lines 101-124). A stuck `recording` row that began just before a `--since-hours`
   cutoff escapes those three checks (the file walk still catches orphans/duplicates
   globally). For the prescribed post-run usage (audit window covers the whole run) this
   cannot hide a defect; noted for windowed audits of partial runs.
6. **MINOR (self-test coverage gap)** — the self-test exercises the `h.at_utc BETWEEN
   gap_start AND gap_end` evidence branch but never the JSON
   `gapStartedUTC/gapEndedUTC` span branch (`verify-m1.sh:157`, the `json_extract` OR
   clause) with an event whose `at_utc` falls outside the interval it spans. The branch
   is simple and reads correctly against the HealthEnvelope schema; a fixture with
   `at_utc` after the resumed chunk's start would close it.
7. **MINOR (test gap)** — no automated test asserts AppModel's menu derivations
   (icon/status mapping per `CaptureReality`, `.requiresApproval` messaging, elapsed
   formatting). The mappings are pure switch statements verified by reading; cheap unit
   tests would protect the "menu never lies" invariant as the UI evolves.

## Honest limitations
I did not run the 48-hour acceptance run, the manual menu-observation schedule,
`build-app.sh` + codesign verification, or the full test suite (per instructions);
`swift build --product Privy` (debug, clean) and the audit self-test (11/11) were the
only executions. W2–W4 internals were trusted to their approved reviews except where W5
integration depends on them (startup gating, snapshot truth, parallel VAD prep,
`bytesRecordedToday` live update, shutdown cancellation of pending restarts), each of
which I re-verified directly in the current sources.

VERDICT: APPROVE

---

## Post-approval delta: monotonic menu elapsed (5ac1bc7)

After the APPROVE above, the orchestrator reassessed §4's `currentChunkElapsed` note
("monotonic-aware via `max(chunk.durationSeconds, heartbeatElapsed)`") against the frozen
time contract and found the heartbeat term unsound: it subtracted two wall-clock dates
(`lastAudioAtUTC − chunk.startedAtUTC`) to produce a duration within one clock epoch,
which `docs/m1/plan.md` forbids ("Wall time is never used for duration math within a
clock epoch"; `Date` is a display/absolute anchor only). A forward NTP/manual clock jump
would inflate the menu's elapsed readout by the jump size until the next hourly rotation.

The staleness concern that motivated the wall term was disproved with code evidence:
`ShadowChunkWriter` recomputes `durationSeconds` from the input sample count and writes it
into the active record at every 5-second checkpoint (`ShadowChunkWriter.swift:31,101-118`),
and the pipeline refreshes `currentChunk = await writer.activeChunk()` on every processed
block (`ShadowCapturePipeline.swift:488`), so the snapshot duration is sample-derived and
at most ~5 s stale while recording.

Fix (commit `5ac1bc7`): `currentChunkElapsed` now displays `chunk.durationSeconds` alone.

Cross-model re-review of the delta (kimi k3, fresh session): **VERDICT: APPROVE**.
- Confirmed the removed code violated the contract and that removal is "correct, not just
  permissible".
- Confirmed no other `lastAudioAtUTC` duration math exists (remaining reads are the
  pipeline heartbeat assignment, the snapshot contract field, and two test assertions).
- Confirmed plan wording ("current chunk elapsed time", "an increasing current-chunk
  duration") is satisfied by 5-second-quantum advancement.
- One MINOR, no action: the readout shows 0:00 for the first ~5 s of a chunk and steps in
  5 s quanta rather than sweeping.

Orchestrator verification at `5ac1bc7`: `swift build --product Privy`, `swift test`
(130/130), `./scripts/build-app.sh`, strict deep codesign verification, plist lint, and
`./scripts/verify-m1.sh --self-test` all pass. One unrelated full-suite flake
(`VADBoundaryAfterRotationMapsToChunkContainingSourceWindowEnd`, a `waitUntil` timing
expectation) occurred once under machine load before the committed rerun; it passes 3/3
focused and the final full-suite run was clean.
