# Privy — Always-Listening Ambient Assistant — Implementation Plan

**Status:** Approved design, nothing built yet. This document is self-contained: a fresh agent should be able to execute it without any prior conversation context.

**Last updated:** 2026-07-30 (rev 2 — owner directive: Privy is a **native macOS menu bar app**, not a Python daemon)
**Context:** solo personal project, single user. macOS (Apple Silicon, Darwin 25 / macOS 26), zsh.

---

## 1. Goal

**Product name: Privy** (as in "privy to everything"). Naming/branding uses English or coined terms only — owner preference.

**Full vision:** an AI assistant that is always listening in the background, so it knows what's going on. Periodically (roughly hourly), an **assessor** reviews recent transcripts and decides whether to inform the owner of anything — or act on it. Default is silence; interruption precision is the product's make-or-break quality.

**Form factor (owner decision 2026-07-30):** a native macOS app that lives in the menu bar. One `Privy.app` owns capture, indexing, workers, and UI. No Dock icon, launches at login, always running. This supersedes the earlier "Python daemon under launchd" design and moves the menu bar UI from "later" into scope from M1.

**This plan's milestones (M1–M5) build the substrate:** capture speech, transcribe it, index it. The assistant layer (M6, sketched in §6) reads from that substrate. Text is the primary product; audio is archived for re-processing (better models later, retroactive speaker diarization).

**Constraints and context:**
- Speech is ~90% Manglish (Malaysian English) with mid-sentence Mandarin/Malay code-switching. This is the single biggest accuracy risk — every model choice must be validated against the owner's real audio, not benchmarks.
- Privacy hardening is a non-goal (single user, own machine — owner's decision). Disk space and processing cost are the real concerns.
- Solo personal project: bias toward momentum and thin end-to-end slices over enterprise rigor, but never risk irreversible audio loss.

## 2. Locked architecture

```
                        ┌─────────────── Privy.app (SwiftUI menu bar app) ───────────────┐
mic → AVAudioEngine tap → ring buffer → [M1: record everything | M3+: VAD-gated] → Opus files
                        │       ↓ Silero VAD via FluidAudio (scores logged always)        │
                        │  SQLite+FTS5 via GRDB: chunks, vad_events, utterances, sessions │
                        │       ↓ in-app batch workers (idle / AC power)                  │
                        │  gpt-transcribe API (text+timestamps) ──join on time──┐         │
                        │  nightly diarization (native or Python sidecar) ──────┘         │
                        │       ↓                                                         │
                        │  Cloudflare R2 archive (checksum-verified) → local deletion     │
                        │  menu bar UI: status / pause / search / settings                │
                        └────────────────────────── M6 assessor reads SQLite ─────────────┘
```

**Locked decisions (do not relitigate without new evidence):**

| Decision | Choice | Rationale |
|---|---|---|
| Form factor | Native menu bar app: SwiftUI `MenuBarExtra`, `LSUIElement` (agent app, no Dock icon), launch-at-login via `SMAppService.mainApp` | Owner decision 2026-07-30; also cleanly solves the TCC/launchd mic-permission risk (old req 7) — a real `.app` bundle gets a normal mic prompt |
| Language | Swift 6 for the app (capture, VAD, encode, DB, workers, UI). Python (`uv`) survives only as an M4 sidecar for the diarization benchmark — eliminated entirely if the native candidate wins | Native capture/TCC/UI require Swift; pyannote & VibeVoice are Python-only |
| Deployment target | macOS 15+ | Single user on macOS 26; FluidAudio needs 14+, `MenuBarExtra`/`SMAppService` need 13+ |
| Audio capture | `AVAudioEngine` input tap → `AVAudioConverter` to 16 kHz mono once; that stream feeds both VAD and the encoder | One conversion path; 16 kHz is what Silero expects and is fine for wideband Opus |
| VAD | Silero VAD via **FluidAudio** (CoreML, ANE-optimized, verified 2026-07-30), ~1s pre-roll, 1–2s silence hangover. Fallback: onnxruntime + silero.onnx | Native Swift package, same Silero model as before; runs on Neural Engine at negligible power |
| Audio format | Opus ~24 kbps mono. Container decided in the M1 day-1 spike: `element-hq/swift-ogg` (libopus+libogg → real `.ogg`, directly API-compatible) vs CoreAudio native Opus-in-CAF (`kAudioFormatOpus`, zero deps, but OpenAI doesn't accept `.caf`) | ~10MB/h; 25MB API limit ≈ 2h+ per file. Lean swift-ogg unless integration fights back — M2 re-containerizes extracted ranges anyway, so either works |
| Index | SQLite with FTS5 via **GRDB.swift** | Owner preference for SQLite; GRDB is the standard Swift wrapper and supports FTS5 |
| ASR | OpenAI `gpt-transcribe` (verified real: released 2026-07-28, $0.0045/min, `v1/audio/transcriptions`, 25MB file limit, supports keyword/language hints) behind a **provider protocol** with `whisper-1` as fallback | Owner has OpenAI credits; hints help Manglish names/jargon; protocol hedges a days-old API |
| Diarization | Local + free, batch, retroactive. Three candidates at M4: **FluidAudio** (native pyannote-CoreML port — try first, it's already a dependency), pyannote 4.0 `community-1` (Python sidecar), VibeVoice-ASR (Python sidecar) | $0/min; FluidAudio winning would make Privy 100% Swift with no sidecar |
| Sessions | Chunks with gaps <10 min group into one session | Makes transcripts read as chat logs |
| Archive | Cloudflare R2 only. Client (aws-sdk-swift / Soto / rclone) decided at M5 | One destination; S3-compatible |
| Range extraction | `ffmpeg` (Homebrew) invoked via `Process` for M2 span extraction and M4 session reconstruction | Batch-only, not in the capture path; not worth reimplementing natively |

**Key external facts (verified online 2026-07-29/30):**
- `gpt-transcribe`: https://developers.openai.com/api/docs/models/gpt-transcribe — $0.0045/min, batch files. Sibling `gpt-live-transcribe` exists for streaming (not used). `gpt-4o-transcribe-diarize` exists but rejected as too expensive.
- FluidAudio: https://github.com/FluidInference/FluidAudio — Swift SDK, CoreML models for VAD (Silero), speaker diarization + embeddings (pyannote-based), macOS 14+, SPM, permissive licenses.
- swift-ogg: https://github.com/element-hq/swift-ogg — opus/ogg ⇄ PCM via libopus/libogg.
- pyannote `community-1`: https://huggingface.co/pyannote/speaker-diarization-community-1 — "exclusive diarization" mode designed for reconciling with transcript timestamps. Needs HF token.
- VibeVoice-ASR: https://github.com/microsoft/VibeVoice — 60-min audio in one pass, ASR+diarization+timestamps, custom keywords, runs locally.

## 3. App architecture

Modules inside `Privy.app` (each behind a protocol so the state machine and reconciliation logic are unit-testable without hardware):

- **PrivyApp** — `@main` SwiftUI app; `MenuBarExtra` scene + Search and Settings window scenes; registers login item.
- **CaptureEngine** — owns `AVAudioEngine`; the input tap callback ONLY copies buffers into a bounded queue (req 4). Rebuilds the engine on device/config changes.
- **VADService** — FluidAudio Silero; consumes the 16 kHz stream; writes frame scores and open/close events to `vad_events`. In M1 it only logs; from M3 it gates.
- **OpusWriter** — consumes the same stream; encodes to Opus; temp file + atomic rename; rotates files at ~1h (req 5).
- **Store** — GRDB; schema in §5; owns the chunk state machine and startup reconciliation.
- **SystemMonitors** — `NSWorkspace.willSleepNotification`/`didWakeNotification` (req 1); CoreAudio property listeners for default-input/device-list changes plus `AVAudioEngineConfigurationChange` (req 2); IOKit power-source check gating batch workers to AC.
- **Clock** — `ContinuousClock` (advances across system sleep) for monotonic time + UTC wall anchor per chunk (req 3).
- **Workers (M2+)** — `TranscriptionWorker` (extracts VAD ranges via ffmpeg, URLSession multipart to OpenAI), `CostMeter` (req 6), `UploadWorker` (M5), `DiarizationRunner` (M4).
- **Sidecar (M4 only, maybe never)** — `uv`-managed Python project in-repo, launched via `Process`, writes results straight into the same SQLite.

**Menu bar UI:**

- **Icon states:** recording (waveform) · paused (waveform + slash) · error (exclamation badge — the app must never look alive while capture is dead, req 2) · cost-cap-tripped (M2+).
- **Dropdown:** status line ("Recording — 42 min into current chunk") · today's disk usage and speech minutes · today's transcription $ (M2+) · last 3 health events · Pause 15 min / 1 h / until resumed · Search… (M2+) · Settings… · Quit.
- **Search window (M2):** FTS5 query box → timestamped hits grouped by session; click-through to a session transcript view.
- **Settings window:** input-device preference, daily cost cap, retention policy, Manglish hint list editor (M2).

**Signing & TCC (replaces the old launchd risk):** mic permission is keyed to bundle ID + signing identity. Ad-hoc signing changes identity every rebuild → endless re-prompts. Use a free-Apple-ID "Apple Development" certificate with Xcode automatic signing (no paid account, no notarization needed — never distributed). `NSMicrophoneUsageDescription` in Info.plist. Validated by the M1 day-1 spike.

## 4. Engineering requirements (apply to all milestones)

These came out of a two-agent design review; each maps to a real failure mode:

1. **Sleep/wake:** lid close / overnight sleep kills the audio stream silently. Subscribe to `NSWorkspace` sleep/wake notifications; tear down and re-open the engine on wake; log gaps as explicit `gap` events. Rated the #1 way to lose data.
2. **Device changes:** AirPods connecting, USB mic unplug, sample-rate changes invalidate the engine. Detect via CoreAudio listeners + `AVAudioEngineConfigurationChange`, re-enumerate, restart, record a health event. Never die silently — surface a visible error state in the menu bar icon.
3. **Clocks:** wall clock jumps (NTP, DST, manual). Store a monotonic timestamp per chunk **and** a UTC wall-clock anchor; derive all durations/offsets from monotonic time; log discontinuities. Absolute time of any word = chunk wall-anchor + monotonic offset.
4. **Real-time audio callback must never block:** the tap only copies frames into a bounded queue. Encoding, VAD, SQLite writes all happen on consumer tasks. Count and log overruns/drops.
5. **Crash consistency:** write Opus to temp files + atomic rename; every file has a SQLite row with an explicit state machine (`recording → ready → transcribing → transcribed → uploaded → deleted`, plus `failed`); on startup, reconcile orphaned files/rows.
6. **Cost circuit breaker:** daily transcription minutes + $ tracked in SQLite; hard daily cap pauses the transcription worker (not capture) and flips the menu bar icon to its alert state. Expected ~2–4h speech/day ≈ $16–32/month; a VAD misfire must not 10× that silently.
7. **TCC via stable signing:** mic permission must survive rebuilds and login-item launches. Validate signing + permission persistence in the M1 day-1 spike *before* building more.
8. **Chunk boundaries:** a 1–2s thinking pause splits sentences. Keep pre-roll AND post-roll; retain segment-level API output; adjacent utterances in a session are rejoined at display time. Never treat one Opus file as one semantic utterance.

## 5. Data model (SQLite)

```sql
-- continuous shadow recordings (M1) and gated utterance files (M3+)
chunks(id, kind TEXT,              -- 'shadow' | 'utterance'
       started_at_utc TEXT, started_mono REAL, duration_s REAL,
       audio_path TEXT, size_bytes INT, checksum TEXT,
       state TEXT,                 -- recording|ready|transcribing|transcribed|uploaded|deleted|failed
       session_id INT);

vad_events(id, chunk_id, t_mono REAL, kind TEXT, score REAL);  -- open/close/frame-score samples

utterances(id, chunk_id, start_s REAL, end_s REAL,             -- offsets within chunk
           started_at_utc TEXT,                                 -- derived absolute time
           transcript TEXT, asr_provider TEXT, asr_raw JSON,
           speaker TEXT, diar_raw JSON);

sessions(id, started_at_utc TEXT, ended_at_utc TEXT, title TEXT);

health(id, at_utc TEXT, kind TEXT, detail TEXT);   -- wake, device_change, overrun, gap, error
costs(id, date TEXT, provider TEXT, minutes REAL, usd REAL);

-- FTS5 virtual table over utterances.transcript, joined for search
```

## 6. Milestones

### M1 — Menu bar app with shadow-mode capture
The app records **everything** continuously (no VAD gating yet) into bounded ~1h Opus files (~250MB/day — fine locally), while Silero VAD runs in parallel and **logs** its open/close decisions and scores without acting on them. Rationale: zero risk of VAD false negatives losing speech while untuned, and daily use builds the real Manglish calibration corpus for free.

**Day-1 spike (timeboxed ~1 day, do first):**
- Create the signed skeleton app (Xcode project, `LSUIElement`, mic permission prompt). Rebuild 3× and confirm TCC does not re-prompt.
- Register as login item via `SMAppService`, log out/in, confirm it launches and can capture without Xcode attached.
- Prototype the Opus write path and pick the container: swift-ogg vs Opus-in-CAF.

**Deliverables:**
- Xcode project `Privy` committed to the repo (init git as part of M1).
- CaptureEngine + bounded queue per req 4; sleep/wake + device handling per reqs 1–2; monotonic+wall timestamps per req 3; OpusWriter with atomic file states per req 5.
- VADService logging scores/decisions to `vad_events` (shadow only).
- GRDB schema (§5) + startup reconciliation.
- Menu bar icon with recording/paused/error states; dropdown with status, current chunk, disk used today, last health events, pause controls, quit.
- Launch at login.

**Acceptance:** over a 48h real run — survives lid-close/reopen, AirPods switch, and a `kill -9` + relaunch with no orphaned rows; no silent gaps >5s unlogged; menu bar state matches reality throughout (never shows recording while dead).

### M2 — Transcription worker + search
- Worker picks VAD-flagged **ranges** from shadow files (with pre/post-roll), extracts those spans via ffmpeg into API-ready files, sends to ASR. Do NOT transcribe whole shadow files — that pays for 24h/day of mostly silence.
- Provider protocol: `transcribe(audio, hints) -> [Segment{text, t0, t1}]` with `gpt-transcribe` primary, `whisper-1` fallback. Store raw API responses (re-parseable later).
- Manglish hint list (names, companies, local terms) passed as keyword hints — editable in Settings, persisted to a config file.
- Session grouping (<10 min gap); Search window (FTS5 → timestamped hits, session transcript view); cost meter + circuit breaker (req 6) with dropdown $ readout and icon alert state.
- Workers run only when on AC power or idle; queue drains on next opportunity.

**Acceptance:** a day of real audio is searchable from the Search window; cost report matches OpenAI dashboard ±10%.

### M3 — Measured VAD cutover
- Compare 1–2 weeks of VAD decisions against the continuous shadow recordings. Audit a stratified sample: low-confidence regions, soft speech, short utterances, code-switch boundaries, random "non-speech". Plain SQL + spot-listening is enough — no audit UI.
- Tune threshold/pre-roll/hangover on measured miss rate (target: <2% missed speech). Flip capture to VAD-gated mode.
- **Before deleting the shadow backlog:** curate and keep a benchmark set — long conversations, Mandarin/Malay switching, overlapping speakers, different mics — for M4.

**Acceptance:** gated mode runs 1 week with disk ≈30–50MB/day and no user-noticed missing speech.

### M4 — Diarization benchmark, then integrate winner
- Benchmark on the M3 benchmark set, in this order:
  1. **FluidAudio diarization** (native, already a dependency — cheapest to try),
  2. pyannote `community-1` exclusive mode (Python sidecar via `uv`),
  3. VibeVoice-ASR (sidecar; also re-does ASR — compare its Manglish WER against gpt-transcribe too). Optional: DiariZen.
- Diarization needs conversational context: run it on session-length audio reconstructed via the manifest (chunk → ranges → offsets), NOT on tiny utterance files, or speaker labels will drift where silence was removed.
- Integrate winner as a nightly in-app batch (AC power only); join speakers to transcripts on time overlap in SQLite.
- Note: this yields per-session labels (Speaker A/B), not persistent identity. Persistent "who" = speaker embeddings + clustering (FluidAudio exposes embeddings) — out of scope, later.
- Decision gates: FluidAudio wins → no Python in the product at all. VibeVoice wins on WER *and* diarization → it may replace gpt-transcribe entirely (API cost → $0). Decide on data.

### M5 — Retention + R2 archive
- Upload Opus to R2 (client: aws-sdk-swift / Soto / rclone — pick at M5 start); verify checksum by reading back; only then delete locally per policy (e.g., local 30 days, R2 indefinitely). SQLite stays local and gets backed up to R2 daily.
- Never delete audio that isn't both transcribed and checksum-verified remote.

### M6 — Assessor (the assistant layer; design pending, do not start unprompted)
The point of the whole product: an hourly job that reads the last hour's transcript from SQLite (plus its own memory of prior assessments and standing instructions), asks an LLM "anything worth telling the owner or acting on?", and outputs *stay silent / notify / act*.

Known requirements so far:
- Default to silence; high bar to interrupt. Every notification logged (`assessments` table) so it never repeats itself and can learn from owner reactions.
- Needs its own memory: prior notifications, ignored items, standing instructions ("always tell me when X").
- Now that Privy is a native app, `UNUserNotificationCenter` is the zero-extra-infra notification channel — but the channel is still an **open owner decision** (macOS notification, Telegram, digest email), as is how far "act" goes (notify-only first vs real actions like reminders/drafts — actions need a tool layer and more trust). Ask before designing M6 in detail.

### Later (explicitly out of scope now)
- System audio capture (Slack/Meet/Zoom) via ScreenCaptureKit — echo/duplicate-voice problems make it a separate capture product.
- Persistent speaker identity; semantic/embedding search; `gpt-live-transcribe` real-time mode; distribution beyond the owner's machine (notarization etc.).

## 7. Open questions (ask the owner when relevant)

1. OpenAI API key provisioning (env var? Keychain — natural fit for a native app?) — needed at M2.
2. R2 bucket + credentials — needed at M5.
3. Daily cost cap value for the circuit breaker (suggest $2/day) — M2.
4. HuggingFace token for pyannote — M4 (only if the sidecar candidates are benchmarked).
5. Does the owner have a paid Apple Developer account? Not required (free Apple ID suffices for local signing), but worth knowing before M1.

## 8. How this plan was made

Designed 2026-07-29 in a debate between Claude (Fable 5) and a `pi` agent running `openai-codex/gpt-5.6-sol`. Notable resolved disagreements: shadow mode replaced both "VAD from day 1" (risky) and "build a labelled corpus first" (too heavy); 8 milestones compressed to 5; Google Drive dropped for R2-only; gpt-transcribe/VibeVoice-ASR existence was disputed and settled by web verification (both real).

**Rev 2 (2026-07-30):** owner directed that Privy be a native macOS menu bar app. Superseded: Python daemon + launchd (old language/TCC decisions), "menu bar UI later". Swift stack verified online same day: FluidAudio (Silero VAD + pyannote diarization as CoreML), swift-ogg / CoreAudio Opus for encoding, GRDB for SQLite+FTS5. Python remains only as an optional M4 benchmark sidecar.
