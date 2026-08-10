# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-07-20)

**Core value:** One click on the playing song → a tagged mp3 lands in the NAS music library. The app never blocks and always tells the user whether it worked.
**Current focus:** none — milestone closed 2026-08-10. See `.planning/CLOSEOUT.md`.

## Current Position

Phase: 3 of 3 complete (Download UI Action + Feedback)
Plan: —
Status: **CLOSED 2026-08-10.** Code delivered and pushed; repo archived read-only on GitHub.
Last code activity: 2026-07-21 — CollectionDownloadButton (whole-playlist download) shipped; had to be mounted in LegacyFallbackViews too since the Mac is on macOS 15 and never renders the macOS-26-gated views.
Last real use: 2026-07-21 — 46 mp3 in `ExtraMusic/kaset` on the NAS, nothing since.

Progress: [██████████] 100% (implementation) — 0% deployed (see Deferred Items)

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

*(emptied at close — everything still open moved to Deferred Items below.)*

- **[2026-07-21, done] Bundle Info.plist fix** — `Scripts/build-app.sh` regenerates `Contents/Info.plist` from a heredoc and ignores the repo-root `Info.plist`, so the Phase 2 ATS exception never shipped. Fixed (`fc27150`), rebuilt + ad-hoc signed, and **installed to `/Applications/Kaset.app`** on the Mac (old upstream 0.12.0 backed up at `~/Kaset-0.12.0-backup.app`). Verified: `NSAllowsLocalNetworking = true` in the installed bundle.
- **Manual GUI click-test** (needs signed-in YT Music account, interactive): play a song → right-click → Download → confirm toast + mp3 in NAS. Backend already proven via curl; this validates the in-app wiring end-to-end.

### Blockers/Concerns

- swiftformat/swiftlint not installed on the Mac → house-style lint not run (build clean, code mirrors existing patterns).

## Deferred Items

Items acknowledged and carried forward from previous milestone close:

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none — all three close-out items were resolved on 2026-08-10, see below)* | | | |

### Closed on 2026-08-10

- **Deployment** — the fork is installed again. Rebuilt on the Mac from the current sources, ad-hoc signed, copied to `/Applications/Kaset.app`. Verified on the installed bundle: `codesign` `flags=0x2(adhoc)`, `NSAppTransportSecurity:NSAllowsLocalNetworking = true`, `SUFeedURL` *Does Not Exist*, `SUEnableAutomaticChecks = false`, `CFBundleVersion 100`. The displaced upstream build (23) is kept at `~/Kaset-upstream-b23-backup.app`.
- **Testing** — `Tests/KasetTests/JukeboxDownloadServiceTests.swift` (7 tests, all passing) pins the client half that had never been exercised: the POST target `<base>/download`, method and content type, the exact JSON keys the FastAPI side reads (`videoId`/`title`/`artist`/`album`/`cover_url`), `ok`/`skip` → success, `fail` → the backend's own reason, an empty `videoId` failing *before* any network call, the Settings URL (whitespace trimmed), `collectionState` counts and `startCollectionDownload`'s job id. Run them with `swift test --disable-xctest --filter JukeboxDownloadServiceTests` — plain `swift test` dies in `swiftpm-xctest-helper` with `signalled(11)` on this Mac, independently of these tests.
- **Tooling** — swiftformat 0.62.1 and swiftlint 0.65.0 installed at `~/bin` on the Mac (no Homebrew there; release binaries, de-quarantined). swiftformat flagged 14 violations in the feature files (`redundantViewBuilder`, `wrapPropertyBodies`, `blankLinesBetweenScopes`, `markTypes`, `wrapIfStatementBodies`) — all fixed; re-lint reports `0/4 files require formatting`. swiftlint is clean on the same files.

The only thing never done by a human is the single-track right-click itself; the app is installed and able to do it, and every layer under the menu item is now covered by tests.

## Session Continuity

Last session: 2026-08-10 — milestone closeout (no code change).
Stopped at: CLOSED. `.planning/` frozen, repo archived on GitHub.
Resume file: `.planning/CLOSEOUT.md` (rebuild + un-archive procedure).
