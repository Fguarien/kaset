# Kaset — Download Music Function

## What This Is

Kaset is a native macOS (SwiftUI, macOS 15.4+) YouTube Music + YouTube client — a fork of `sozercan/kaset` under `Fguarien/kaset`. This milestone adds a **download-current-song-as-mp3** capability: from the player, the user triggers a download; the app hands the song's `videoId` to an existing homelab backend (**jukebox** on vm-docker) which uses yt-dlp to fetch, transcode to tagged mp3, and store it in the NAS music library. Personal use (solo demo).

## Core Value

**One click on the playing song → a tagged mp3 lands in the NAS music library.** The app never blocks, never handles the stream itself, and always tells the user whether it worked.

## Requirements

### Validated

<!-- Existing kaset capabilities inherited by the fork. -->

- ✓ Play YouTube Music / YouTube inside the app (`SingletonPlayerWebView`, DRM) — existing
- ✓ Track "now playing" identity + metadata (`PlayerService.currentTrack: Song?` with `videoId`, `title`, `artistsDisplay`, `album`, `thumbnailURL`) — existing
- ✓ Player-bar + queue context menus (Share item pattern) — existing
- ✓ Persisted user settings (`SettingsManager`, UserDefaults) — existing
- ✓ URLSession JSON service pattern (`LastFMService`) — existing
- ✓ Server-side yt-dlp → mp3 + square cover + mutagen tag pipeline (jukebox `downloader.download()`) — existing

### Active

<!-- This milestone. -->

- [ ] Add an on-demand single-track download endpoint to jukebox (accepts a videoId/URL)
- [ ] Add a `JukeboxDownloadService` in kaset (HTTP POST, observable status)
- [ ] Add a "Download" action to the player-bar current-song context menu (and queue rows)
- [ ] Make the jukebox base URL configurable in Settings
- [ ] Allow the plain-HTTP LAN request past App Transport Security
- [ ] Give the user success/failure feedback (toast)

### Out of Scope

- Client-side stream extraction / DRM bypass — YT Music audio is Widevine-DRM in-app; yt-dlp on the backend re-fetches from the videoId, sidestepping it. Doing it in Swift is technically uncertain and unnecessary.
- Batch / playlist / library bulk download — v1 is the single currently-playing song. (jukebox already has a batch/file-drop path for lists.)
- Public exposure / auth on the backend — LAN-only, no FQDN; personal demo.
- Video (mp4) download — audio-only mp3 for v1.
- Sync of downloaded files back into the app UI / a "downloads" library view.

## Context

- **Two repos, one feature:** kaset (Swift, this repo, `/home/parallels/kaset`) is the client; the backend change lives in the homelab-vault repo at `10-stacks/jukebox/` (Python/FastAPI on vm-docker `10.234.1.43:8772`).
- **jukebox today** is batch-only: drop a list file → cron `POST /run` → downloads all → NAS `/volume1/music/ExtraMusic/`. Its `downloader.download(item, dest)` already handles a single item given a `direct_url`; the new endpoint is a thin wrapper (~20 lines).
- **Network reachability:** jukebox publishes `0.0.0.0:8772`, so the Mac (10.234.1.41) reaches `http://10.234.1.43:8772` directly on the LAN.
- **Build reality:** Swift/SwiftUI app builds only on macOS + Xcode. Editing/git/GSD run on vm-claude (Linux); build & test shell out to the Mac (Xcode 26.3, macOS 15.7.7) over SSH, mirroring the repo.
- **kaset conventions (from AGENTS.md):** new data/network work goes through typed clients (not WebView scraping); endpoints probed with `swift run api-explorer` first. The download POST is a homelab call, not a YouTube API call, so it's a fresh small service.

## Constraints

- **Tech stack**: kaset = Swift 6 / SwiftUI, SPM, macOS 15.4+ target; jukebox = Python 3 / FastAPI + yt-dlp + mutagen + Pillow.
- **Platform**: app builds/runs on macOS only; cross-host build loop (edit on Linux, `xcodebuild` on Mac).
- **Sandbox / ATS**: app is sandboxed with `network.client`; `Info.plist` has no ATS exception → plain-HTTP to the LAN IP requires `NSAllowsLocalNetworking` (or an `NSExceptionDomains` entry).
- **Backend**: LAN-only, no auth in v1; must not block kaset's UI (async fire-and-forget + status poll/return).
- **Legal**: downloading from YouTube violates YouTube ToS — personal use, user's explicit choice.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Download runs server-side (jukebox), app sends only `videoId` | Sidesteps in-app Widevine DRM; reuses proven yt-dlp+tag pipeline; keeps Swift thin | ✅ Done |
| Extend jukebox with an on-demand `/download` endpoint (vs file-drop) | Button UX needs synchronous single-track; `downloader.download()` already supports it | ✅ Done |
| Hook = player-bar current-song context menu (beside Share) | Existing, discoverable pattern; `currentTrack` in scope; mirrors on queue rows | ✅ Done |
| New `JukeboxDownloadService` modeled on `LastFMService` | No generic HTTP client exists; LastFM is a copy-ready URLSession-POST template | ✅ Done |
| Backend base URL configurable via `SettingsManager` | Avoid hardcoding the homelab IP; survive network changes | ✅ Done |
| Audio-only mp3, single current song for v1 | Matches "download music"; smallest useful slice | ✅ Done |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-20 after initialization*
