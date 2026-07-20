# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-20)

**Core value:** One click on the playing song → a tagged mp3 lands in the NAS music library. The app never blocks and always tells the user whether it worked.
**Current focus:** All 3 phases delivered — pending manual GUI click-test by user.

## Current Position

Phase: 3 of 3 complete (Download UI Action + Feedback)
Plan: —
Status: Delivered — code shipped, backend live-tested, Swift build clean.
Last activity: 2026-07-20 — Phases 1-3 implemented, deployed, built (0 errors).

Progress: [██████████] 100% (implementation)

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

### What shipped

- **Phase 1** — jukebox `POST /download` deployed on vm-docker; live-tested (ok/skip/400, mp3+cover in `ExtraMusic/kaset/`). Committed + dual-pushed to homelab-vault.
- **Phase 2** — `JukeboxDownloadService`, `SettingsManager.jukeboxBaseURL`, `Info.plist` ATS exception, service registered in `KasetApp`, Downloads section in Music settings.
- **Phase 3** — `DownloadContextMenu` action (PlayerBar + queue rows), `JukeboxDownloadToast` mounted in MainWindow.
- Swift 6 `swift build` clean (0 errors, 378 modules). `Kaset.app` (31M) assembled via `Scripts/build-app.sh` + **ad-hoc signed** and runnable on the Mac (`~/kaset/.build/app/Kaset.app`). Note: the script's `dev` codesign step fails over headless SSH (`errSecInternalComponent`) — ad-hoc sign used instead; see `faqs/kaset.md`.

### Pending Todos

- **Manual GUI click-test** (needs signed-in YT Music account, interactive): play a song → right-click → Download → confirm toast + mp3 in NAS. Backend already proven via curl; this validates the in-app wiring end-to-end.

### Blockers/Concerns

- swiftformat/swiftlint not installed on the Mac → house-style lint not run (build clean, code mirrors existing patterns).

## Deferred Items

Items acknowledged and carried forward from previous milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-07-20
Stopped at: ROADMAP.md and STATE.md created; REQUIREMENTS.md traceability filled.
Resume file: None
