# Closeout — Download Current Song as MP3

**Status: CLOSED 2026-08-10.** Repo archived read-only on GitHub (`Fguarien/kaset`).
Opened 2026-07-20, all code landed 2026-07-20/21, dormant since.

## Goal

One action on the playing song → a tagged mp3 lands in the NAS music library, without
touching the Widevine-DRM stream the app plays in its hidden WebView.

## What shipped

| # | Increment | Where | Commit |
|---|-----------|-------|--------|
| 1 | jukebox `POST /download {videoId}` — on-demand single track, tagged mp3 + square cover into `ExtraMusic/kaset/` | homelab-vault `10-stacks/jukebox/` (vm-docker `10.234.1.43:8772`) | `e9bc559` |
| 2 | `JukeboxDownloadService` (modeled on `LastFMService`), `SettingsManager.jukeboxBaseURL`, ATS exception, Downloads section in Settings | this repo | `d4020c2` |
| 3 | `DownloadContextMenu` on the player bar + queue rows, `JukeboxDownloadToast` in `MainWindow` | this repo | `16172c8` |
| + | Whole-playlist download: `CollectionDownloadButton` + background job endpoints (`POST /download/playlist`, `/download/playlist/state`, `DELETE /download/job/{id}`) | both repos | `2d94901`, jukebox `405c9ee` |
| + | macOS 15 legacy path: track context menus restored in `SimplePlaylistDetailView` | this repo | `ed37a61` |
| fix | ATS key emitted into the *generated* bundle Info.plist; upstream Sparkle feed dropped from local builds | this repo | `fc27150`, `262a446` |

**Architecture, in one line:** the app never touches the audio stream — it POSTs the
`videoId` (+ title/artist/album/cover) and yt-dlp re-fetches server-side through its own
InnerTube path, which is independent of the app's DRM session.

## Evidence it worked

- `GET http://10.234.1.43:8772/health` → `{"status":"ok"}` (still live at close).
- **46 mp3** under `/docker-mounts/music/ExtraMusic/kaset` on the NAS, including the
  playlist run `elyn_lane/` — produced by the app, not by curl.
- Last file written **2026-07-21**. No use since.

## The three loose ends — all closed 2026-08-10

They were found open at close and were resolved the same day rather than carried forward.

1. **The Mac did not run this fork** — `/Applications/Kaset.app` had reverted to the upstream
   build (`CFBundleVersion 23`, `TeamIdentifier 57QNR9B89Q`, hardened runtime, installed
   2026-08-05, upstream `SUFeedURL`, no ATS key). **Fixed**: rebuilt from the current sources on
   the Mac, ad-hoc signed, installed. The installed bundle now reports `flags=0x2(adhoc)`,
   `NSAllowsLocalNetworking = true`, `SUFeedURL` *Does Not Exist*, `SUEnableAutomaticChecks =
   false`, `CFBundleVersion 100`. The displaced upstream build is parked at
   `~/Kaset-upstream-b23-backup.app` (restore with a plain `cp -R`).
2. **The client half was never tested** — only the backend had been proven (curl + the mp3 on
   the NAS). **Fixed**: `Tests/KasetTests/JukeboxDownloadServiceTests.swift`, 7 tests, green.
   They pin the POST target, method, content type, the exact JSON keys the FastAPI side reads,
   `ok`/`skip` → success, `fail` → the backend's own reason, an empty `videoId` failing before
   any network call, the Settings URL (whitespace trimmed), the collection-state counts and the
   playlist job id. Run: `swift test --disable-xctest --filter JukeboxDownloadServiceTests`.
   ⚠️ Plain `swift test` (the command in CONTRIBUTING.md) dies on this Mac with
   `error: signalled(11): … swiftpm-xctest-helper` **before running anything** — a toolchain
   issue in the XCTest bridge, unrelated to these tests. `--disable-xctest` runs the Swift
   Testing suites and is the invocation that works here.
3. **No linters on the Mac** (no Homebrew) — **Fixed**: swiftformat 0.62.1 and swiftlint 0.65.0
   installed as release binaries in `~/bin` (de-quarantined). swiftformat found 14 violations in
   the feature files (`redundantViewBuilder`, `wrapPropertyBodies`, `blankLinesBetweenScopes`,
   `markTypes`, `wrapIfStatementBodies`); all fixed, re-lint clean (`0/4 files require
   formatting`), swiftlint clean on the same files, tests still green afterwards, app rebuilt
   and reinstalled from the formatted sources.

Residual, deliberately: nobody has performed the single-track right-click → Download **by hand**.
The app is installed and capable of it; every layer beneath the menu item is now covered by
tests. A 30-second manual check remains available, it is not a blocker.

**Note for `zsh` users driving the Mac over SSH**: `swiftformat $FILES` with an unquoted
variable passes the whole list as *one* argument — zsh does not word-split. Use `${=FILES}`
or explicit paths.

## Reviving

```bash
gh repo unarchive Fguarien/kaset                       # repo is read-only on GitHub
rsync -a --delete ~/kaset/ analogique@10.234.1.41:~/kaset/ -e 'ssh -p 2122'   # sources → Mac
ssh -p 2122 analogique@10.234.1.41 'cd ~/kaset && swift build && ./Scripts/build-app.sh'
ssh -p 2122 analogique@10.234.1.41 'codesign --force --deep --sign - ~/kaset/.build/app/Kaset.app'
ssh -p 2122 analogique@10.234.1.41 'rm -rf /Applications/Kaset.app && cp -R ~/kaset/.build/app/Kaset.app /Applications/'
```

Then **verify the installed bundle is yours** — this is the check that was missing:

```bash
codesign -dv /Applications/Kaset.app 2>&1 | grep flags        # want 0x2(adhoc); 0x10000(runtime) = upstream
/usr/libexec/PlistBuddy -c "Print SUFeedURL"            /Applications/Kaset.app/Contents/Info.plist  # want: Does Not Exist
/usr/libexec/PlistBuddy -c "Print NSAppTransportSecurity" /Applications/Kaset.app/Contents/Info.plist  # want: NSAllowsLocalNetworking = true
```

Gatekeeper on an ad-hoc build: first launch via right-click → Open.
Full gotcha list (DRM, ATS, heredoc Info.plist, Sparkle, macOS 15 fallback views):
`homelab-vault/faqs/kaset.md`.

## Backend kept

The jukebox endpoints are **not** decommissioned — they are useful without the app
(curl, n8n) and cost nothing idle. See `10-stacks/jukebox/decisions.md` (2026-08-10).
