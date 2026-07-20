# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-20)

**Core value:** One click on the playing song → a tagged mp3 lands in the NAS music library. The app never blocks and always tells the user whether it worked.
**Current focus:** Phase 1 — Backend On-Demand Download Endpoint

## Current Position

Phase: 1 of 3 (Backend On-Demand Download Endpoint)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-07-20 — Roadmap created (3 phases, coarse, MVP-first)

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: -
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: -
- Trend: -

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Download runs server-side (jukebox); app sends only `videoId` — sidesteps in-app Widevine DRM, reuses proven yt-dlp+tag pipeline.
- Extend jukebox with an on-demand `POST /download` endpoint (vs file-drop batch) — button UX needs synchronous single-track.
- New `JukeboxDownloadService` modeled on `LastFMService`; backend base URL configurable via `SettingsManager`.

### Cross-Repo Note

- **Phase 1 edits the jukebox repo** at `/home/parallels/homelab-vault/10-stacks/jukebox/` (FastAPI on vm-docker `10.234.1.43:8772`), NOT the kaset repo.
- **Phases 2-3 edit this repo** (`/home/parallels/kaset`); Swift builds run on the Mac (Xcode) over SSH.

### Pending Todos

None yet.

### Blockers/Concerns

None yet.

## Deferred Items

Items acknowledged and carried forward from previous milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-07-20
Stopped at: ROADMAP.md and STATE.md created; REQUIREMENTS.md traceability filled.
Resume file: None
