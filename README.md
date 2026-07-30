# Privy

An always-listening ambient assistant for macOS — a native menu bar app that captures speech throughout the day, transcribes it, and makes it searchable. On top of that substrate sits an hourly **assessor** that reads recent transcripts and decides whether anything is worth surfacing. Default is silence.

## Status

Design phase — nothing built yet. The full design (architecture, locked decisions, engineering requirements, milestones) lives in [PLAN.md](PLAN.md).

## How it works

```
mic → AVAudioEngine → Opus files (24 kbps)
        ↓ Silero VAD (FluidAudio, CoreML)
      SQLite + FTS5 index (GRDB)
        ↓ batch workers (idle / AC power)
      gpt-transcribe API + local speaker diarization
        ↓
      Cloudflare R2 archive → hourly assessor → notify only when it matters
```

## Stack

- Swift 6 / SwiftUI (`MenuBarExtra`), macOS 15+
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Silero VAD and speaker diarization as CoreML
- [GRDB](https://github.com/groue/GRDB.swift) — SQLite with FTS5
- OpenAI `gpt-transcribe` for ASR, Cloudflare R2 for archival

## License

[MIT](LICENSE)
