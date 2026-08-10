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

## What is NOT done — read this before reviving

1. **The Mac does not run this fork.** As of 2026-08-10 `/Applications/Kaset.app` is the
   *upstream* build: `CFBundleVersion 23`, `TeamIdentifier 57QNR9B89Q`, hardened runtime
   (`flags=0x10000`), 53 MB binary, bundle installed 2026-08-05, `SUFeedURL` = upstream
   appcast, **no** `NSAppTransportSecurity`. So the Download action is absent from the
   installed app. The fork bundle survives at `~/kaset/.build/app/Kaset.app` (2026-07-21)
   and the pre-fork backup at `~/Kaset-0.12.0-backup.app`.
2. **Single-track GUI click-test never performed** by a human (backend proven, in-app
   wiring for `PlayerService.currentTrack` unvalidated end-to-end).
3. **swiftformat/swiftlint absent** from the Mac → house style never linted.

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
