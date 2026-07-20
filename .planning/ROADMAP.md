# Roadmap: Download Current Song as MP3

## Overview

This milestone adds a "download the currently-playing song as a tagged mp3" capability to the kaset macOS app, delivered as three end-to-end verifiable increments, MVP-first. Phase 1 builds the on-demand download endpoint on the existing homelab **jukebox** backend (curl-testable in isolation, unblocks everything). Phase 2 adds the kaset-side `JukeboxDownloadService` plus the Settings URL field and the ATS exception, so a real request reaches the backend. Phase 3 wires the user-facing context-menu action and toast feedback, closing the loop from click to saved file.

**Two repos, one feature:**
- **Phase 1 edits the jukebox repo**, NOT this one: `/home/parallels/homelab-vault/10-stacks/jukebox/` (Python/FastAPI on vm-docker `10.234.1.43:8772`; canonical compose at `/opt/docker/jukebox/` — see homelab conventions).
- **Phases 2 and 3 edit this repo**: `/home/parallels/kaset` (Swift/SwiftUI, built on the Mac over SSH).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

- [ ] **Phase 1: Backend On-Demand Download Endpoint** - jukebox `POST /download` fetches one track by videoId → tagged mp3 on the NAS (jukebox repo)
- [ ] **Phase 2: kaset Download Service + Config Plumbing** - `JukeboxDownloadService`, configurable Settings URL, and ATS exception so a request reaches the backend
- [ ] **Phase 3: Download UI Action + Feedback** - context-menu "Download" on the player bar and queue rows, with toast feedback

## Phase Details

### Phase 1: Backend On-Demand Download Endpoint
**Goal:** The jukebox backend can download a single track on demand from a `videoId` and land a tagged mp3 in the NAS library, callable over HTTP — testable end-to-end with curl.
**Mode:** mvp
**Depends on:** Nothing (first phase)
**Repo:** jukebox — `/home/parallels/homelab-vault/10-stacks/jukebox/` (NOT the kaset repo)
**Requirements:** BE-01, BE-02, BE-03, BE-04
**Success Criteria** (what must be TRUE):
  1. `curl -X POST http://10.234.1.43:8772/download -d '{"videoId":"..."}'` returns `{status: ok, file: ...}` and a tagged mp3 appears in `ExtraMusic/kaset/` on the NAS.
  2. The downloaded mp3 has square cover art and mutagen tags (title/artist/album), matching the batch path's output quality (reuses `downloader.download()`).
  3. A bad or unavailable `videoId` returns a clear error JSON (`status: fail` + `reason`), never a 500 crash; `GET /health` continues to return healthy.
  4. A `/download` call issued while a batch `/run` is in progress completes without corrupting or clashing with the batch output.
**Plans:** TBD

### Phase 2: kaset Download Service + Config Plumbing
**Goal:** kaset can send the currently-playing song to the jukebox backend over the LAN, with a configurable base URL and observable per-request status — verifiable that a triggered request reaches the backend and an mp3 lands.
**Mode:** mvp
**Depends on:** Phase 1
**Repo:** kaset — `/home/parallels/kaset`
**Requirements:** SVC-01, SVC-02, SVC-03, SVC-04, CFG-01, CFG-02
**Success Criteria** (what must be TRUE):
  1. At app startup a `JukeboxDownloadService` (`@MainActor @Observable`, modeled on `LastFMService`) is injected into the environment; invoking `download(song)` issues a `URLSession` POST off the main thread built from the `Song`'s `videoId` (+ title/artist/album/thumbnail) and the backend receives it (an mp3 lands in `ExtraMusic/kaset/`).
  2. The service exposes observable state (idle / downloading / success / failure with message) that reflects the real request outcome.
  3. The jukebox base URL is editable via a `TextField` in Settings, defaults to `http://10.234.1.43:8772`, and persists across app relaunch (`SettingsManager`/UserDefaults).
  4. The plain-HTTP LAN POST is not blocked by App Transport Security — with the `Info.plist` exception in place, the request completes instead of failing with `-1022`.
**Plans:** TBD

### Phase 3: Download UI Action + Feedback
**Goal:** From the player, the user can one-click download the playing song (or any queued song) and always sees whether it worked — the end-to-end user-facing slice.
**Mode:** mvp
**Depends on:** Phase 2
**Repo:** kaset — `/home/parallels/kaset`
**Requirements:** UI-01, UI-02, UI-03, UI-04
**Success Criteria** (what must be TRUE):
  1. Right-clicking the playing song in the player bar shows a "Download" item beside the existing Share item; choosing it saves an mp3 to the library.
  2. The same Download action appears on queue rows and downloads that specific row's song.
  3. The action reads its target from `PlayerService.currentTrack` (or the row's `Song`) and is disabled/hidden when there is no valid song/`videoId`.
  4. The user sees a toast on start ("Downloading…") and on result ("Saved to library" or an error message), without blocking playback or the UI.
**Plans:** TBD
**UI hint:** yes

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Backend On-Demand Download Endpoint | 0/TBD | Not started | - |
| 2. kaset Download Service + Config Plumbing | 0/TBD | Not started | - |
| 3. Download UI Action + Feedback | 0/TBD | Not started | - |
