# Requirements — Download Music Function (v1)

Milestone: add "download the currently-playing song as a tagged mp3" to the kaset macOS fork, via the existing homelab jukebox yt-dlp backend.

## v1 Requirements

### Backend (jukebox — homelab-vault `10-stacks/jukebox/`)

- [ ] **BE-01**: jukebox exposes `POST /download` accepting a single `{videoId}` (or full URL) and downloads that one track on demand (not the batch file-drop path).
- [ ] **BE-02**: The endpoint reuses `downloader.download()` (yt-dlp → mp3 + square cover + mutagen tags) and writes to a dedicated output dir (e.g. `ExtraMusic/kaset/`) on the NAS.
- [ ] **BE-03**: The endpoint returns a JSON result (`{status: ok|skip|fail, reason?, file?}`) synchronously, and is safe against concurrent calls (does not corrupt or clash with an in-progress batch `/run`).
- [ ] **BE-04**: `GET /health` continues to work and the endpoint degrades gracefully (clear error JSON, no 500 crash) on a bad/unavailable videoId.

### Download Service (kaset — `Sources/Kaset/Services/`)

- [ ] **SVC-01**: A `JukeboxDownloadService` (`@MainActor @Observable`, modeled on `LastFMService`) issues the `POST` to the jukebox base URL using `URLSession`, off the main thread.
- [ ] **SVC-02**: The service exposes observable per-request status (idle / downloading / success / failure with message) that the UI can bind to.
- [ ] **SVC-03**: The service is registered/injected at app startup (`KasetApp.swift`) like other services.
- [ ] **SVC-04**: The service builds its request from a `Song` (uses `videoId`; may pass `title`/`artistsDisplay`/`album`/`thumbnailURL` so the backend can tag/name correctly).

### UI (kaset — `Sources/Kaset/Views/`)

- [ ] **UI-01**: A "Download" action appears in the player-bar current-song context menu, beside the existing Share item (`PlayerBar.swift` `currentSongContextMenu`), using the app's standard `Button { } label: { Label(_, systemImage:) }` shape.
- [ ] **UI-02**: The same action is available on queue rows (`QueueView.swift`) for any queued song.
- [ ] **UI-03**: The action reads the target song from `PlayerService.currentTrack` (current song) or the row's `Song`, and is disabled/hidden when there is no valid song/`videoId`.
- [ ] **UI-04**: The user gets clear feedback on start and result (a toast: "Downloading…", "Saved to library", or an error), without blocking playback or the UI.

### Config (kaset — Settings + Info.plist)

- [ ] **CFG-01**: The jukebox base URL is configurable in Settings (`SettingsManager` + a `TextField` in the Settings `TabView`), defaulting to `http://10.234.1.43:8772`.
- [ ] **CFG-02**: `Info.plist` allows the plain-HTTP LAN request (`NSAppTransportSecurity` → `NSAllowsLocalNetworking`, or an `NSExceptionDomains` entry for the backend host) so the POST is not blocked by ATS.

## v2 Requirements (deferred)

- [ ] Batch download of a playlist / album / library selection.
- [ ] A "Downloads" view or badge inside kaset showing what was saved.
- [ ] Video (mp4) download option + quality/format choice.
- [ ] Backend auth + public FQDN (if kaset ever leaves the LAN).
- [ ] Cookie/premium-quality auth for yt-dlp (`--cookies-from-browser`) for higher-bitrate YT Music.

## Out of Scope

- Client-side stream extraction / Widevine DRM bypass — backend re-fetches from `videoId`; unnecessary and technically uncertain in-app.
- Any change to kaset's existing playback, library, or queue behavior beyond adding the action.
- Progress bars with byte-level granularity — coarse status (downloading/done/failed) is enough for v1.

## Traceability

<!-- Filled by roadmap: REQ-ID → Phase -->
