<!-- refreshed: 2026-07-20 -->
# Architecture

**Analysis Date:** 2026-07-20

## System Overview

Native macOS MVVM app. Two parallel "sources" (YouTube **Music** and regular **YouTube**), each with its own API client, parsers, player service, and WebView. Data is fetched over HTTP (InnerTube API); WebViews are used only for DRM playback + auth.

```text
┌──────────────────────────────────────────────────────────────────────┐
│  SwiftUI Views  (Sources/Kaset/Views/, 120 files)                      │
│  read @Environment(PlayerService.self) / @Environment(YouTube…)        │
└───────────────┬───────────────────────────────────┬──────────────────┘
                │ observes                            │ observes
                ▼                                     ▼
┌───────────────────────────────┐   ┌───────────────────────────────────┐
│ PlayerService  (@Observable)  │   │ YouTubePlayerService (@Observable)│
│ Services/Player/PlayerService* │   │ Services/Player/YouTubePlayer…    │
│  → currentTrack: Song?  ★      │   │  (regular YouTube video)          │
│  → queueStorage: [QueueEntry]  │   └───────────────────────────────────┘
└───────┬──────────────────┬─────┘
        │ commands          │ reads/writes metadata
        ▼                   ▼
┌────────────────────────┐  ┌────────────────────────────────────────────┐
│ SingletonPlayerWebView │  │ YTMusicClient (@MainActor)                 │
│ (hidden WKWebView)     │  │ Services/API/YTMusicClient.swift           │
│ Views/MiniPlayerWebView│  │  InnerTube HTTP → SongMetadataParser etc.  │
│  .currentVideoId ◆     │  └──────────────────┬─────────────────────────┘
│  JS bridge STATE_UPDATE│                     │ cookies / SAPISID
└───────┬────────────────┘                     ▼
        │ WKScriptMessage           ┌──────────────────────────────────┐
        ▼ (videoId/title/artist)    │ WebKitManager (cookies, auth)    │
   PlayerService.updateTrackMetadata│ Services/WebKit/WebKitManager*   │
                                    └──────────────────────────────────┘

★ = authoritative "now playing" Song at runtime
◆ = authoritative "now playing" videoId in the WebView layer
```

## Module Map

| Module | Path | Responsibility |
|--------|------|----------------|
| App entry / DI wiring | `Sources/Kaset/KasetApp.swift`, `AppDelegate.swift` | Instantiates services, injects them into SwiftUI `@Environment`, sets `PlayerService.shared`, window lifecycle for background audio |
| Views | `Sources/Kaset/Views/` (120) | SwiftUI UI; player bar, mini player, library, search, playlists |
| ViewModels | `Sources/Kaset/ViewModels/` (26) | Per-screen state/logic |
| Models | `Sources/Kaset/Models/` (42) | `Song`, `Album`, `Artist`, `Playlist`, `QueueEntry`, etc. |
| Player services | `Sources/Kaset/Services/Player/` | `PlayerService` (music) + 12 extensions; `YouTubePlayerService` (video) |
| Playback WebView | `Sources/Kaset/Views/MiniPlayerWebView.swift` + `SingletonPlayerWebView+*` | The one hidden `WKWebView` + JS bridge |
| API clients | `Sources/Kaset/Services/API/` | `YTMusicClient`, `YouTubeClient`, `Parsers/`, `APICache` |
| WebKit/auth | `Sources/Kaset/Services/WebKit/` | Cookies, SAPISID, `WKWebsiteDataStore` |
| Audio (EQ) | `Sources/Kaset/Services/Audio/` | CoreAudio process-tap equalizer |
| Scrobbling | `Sources/Kaset/Services/Scrobbling/` | Last.fm (via Cloudflare `worker/`) |
| AI (macOS 26) | `Sources/Kaset/Services/AI/` | FoundationModels command bar / intents |
| Utilities / Extensions | `Sources/Kaset/Utilities/` (16), `Sources/Kaset/Extensions/` | `DiagnosticsLogger`, `UITestConfig`, Swift stdlib extensions |

## Pattern Overview

**Overall:** MVVM + dependency-injected `@Observable @MainActor` services shared through SwiftUI `@Environment`.

**Key characteristics:**
- Single shared long-lived service objects created once in `KasetApp.init()` and injected via `.environment(...)` (`KasetApp.swift:196-205`). `PlayerService` also exposes a `static var shared` for AppleScript/non-SwiftUI callers (`PlayerService.swift:61`, set at `KasetApp.swift:108`).
- Strict Swift 6 concurrency; nearly everything playback-related is `@MainActor`.
- Playback is a **hybrid**: control/UI state lives in native Swift; the actual audio element lives in a WebView and reports back over a JS bridge. Native state is treated as authoritative ("Queue Authority").

## PLAYBACK / NOW-PLAYING DATA FLOW  ← read this for the download feature

### Where "now playing" lives at runtime

**Authoritative now-playing object:** `PlayerService.currentTrack` — type `Song?`
- Declared: `Sources/Kaset/Services/Player/PlayerService.swift:120`
- `PlayerService` is `@MainActor @Observable final class` (`PlayerService.swift:12`).
- Access from SwiftUI: `@Environment(PlayerService.self) private var playerService` → `playerService.currentTrack`.
- Access from non-SwiftUI code (AppleScript, controllers): `PlayerService.shared?.currentTrack`.

**`Song` model** (`Sources/Kaset/Models/Song.swift`) — this is exactly what a "download current song" feature reads:

| Property | Type | Notes |
|----------|------|-------|
| `videoId` | `String` | **The identity you need for the stream.** `id == videoId` for songs. Equality/hash are by `videoId` only. |
| `title` | `String` | Track title (may be transiently `"Loading..."` right after play starts, before metadata fetch resolves). |
| `artists` | `[Artist]` | Use `song.artistsDisplay` for a comma-joined string. |
| `album` | `Album?` | Optional. |
| `duration` | `TimeInterval?` | Seconds; may be nil until metadata/observer fills it. `song.durationDisplay` → "3:45". |
| `thumbnailURL` | `URL?` | API thumbnail. Fallbacks: `song.fallbackThumbnailURL` (`i.ytimg.com/vi/<videoId>/hqdefault.jpg`), `song.wideHighQualityThumbnailURL`. |
| `isExplicit`, `likeStatus`, `isInLibrary`, `feedbackTokens`, `musicVideoType`, `hasVideo` | optionals | enrichment fields |

So: **given the app is playing, the current song's videoId + full metadata is `PlayerService.shared?.currentTrack` (or the environment-injected `playerService.currentTrack`).** For metadata-quality decisions, the WebView-observed video identity is also mirrored on `PlayerService.playbackStateVideoId` (`PlayerService.swift:170`) and the low-level truth is `SingletonPlayerWebView.shared.currentVideoId`.

### The play path (how currentTrack gets set)

1. A View calls `await playerService.play(song:)` or `play(videoId:)` — `Sources/Kaset/Services/Player/PlayerService+PlaybackControls.swift:85 / 165 / 195`.
2. `play(song:…)` sets `self.currentTrack = song` immediately (`PlaybackControls.swift:275`), sets `pendingPlayVideoId = song.videoId`, then routes to the WebView via `routePlaybackToWeb(...)`.
3. `play(videoId:)` (no Song yet) creates a **placeholder** `Song(title: "Loading...", videoId:)` (`PlaybackControls.swift:141`), then calls `fetchSongMetadata(videoId:…)` (`PlayerService+Library.swift:398`) → `YTMusicClient.getSong(videoId:)` to fill real metadata and overwrite `currentTrack`.
4. `SingletonPlayerWebView.shared.loadVideo(videoId:)` (`Views/MiniPlayerWebView.swift`) loads the `music.youtube.com` watch URL in the hidden `WKWebView` and sets `SingletonPlayerWebView.shared.currentVideoId`.

### The observer path (how currentTrack stays correct)

- Injected JS in the player page posts `STATE_UPDATE` / `TRACK_ENDED` to `window.webkit.messageHandlers.singletonPlayer`.
- Swift handles them in `WKScriptMessageHandler.userContentController(_:didReceive:)` → `MiniPlayerWebView.swift` / `MiniPlayerWebView+Coordinator.swift`.
- Handler calls `PlayerService.updatePlaybackState(...)` and `PlayerService.updateTrackMetadata(...)` (in `PlayerService+WebQueueSync.swift`, which rebuilds `currentTrack` at lines 109 / 689). When the WebView reports a new `videoId`, that is treated as authoritative even if DOM title/artist are stale (see `docs/playback.md` "Queue Authority").
- On natural end, `handleTrackEnded(observedVideoId:)` advances the native queue.

### How the queue relates

- Queue lives in `PlayerService.queueStorage: [QueueEntry]` (private; exposed read-only via `queue: [Song]`, `queueEntries: [QueueEntry]`) — `PlayerService.swift:270-292`.
- `QueueEntry` (`Sources/Kaset/Services/Player/PlayerQueueModels.swift:5`) wraps `let song: Song` + a `source` (`.queued` / `.suggested` for Smart Shuffle).
- `currentIndex` (`PlayerService.swift:295`) points into the queue; `currentQueueEntryID` / `activePlaybackQueueEntryID` track the playing entry. The playing track is normally `queueStorage[currentIndex].song`, but **`currentTrack` is the single source of truth for "what is playing now"** — it is also set for queue-less plays (`play(videoId:)`, standalone episodes). Prefer `currentTrack` over indexing the queue.

### How YTMusicClient fetches song data

- `YTMusicClient.getSong(videoId:)` (`Services/API/YTMusicClient.swift:1286`) POSTs InnerTube `next` endpoint (`isAudioOnly: true`) → `SongMetadataParser.parse(...)` → returns a fully-populated `Song` (title, artists, album, duration, thumbnails, `feedbackTokens`, like/library status).
- Other relevant fetches: `getRadioQueue(videoId:)` (:1218), `getMixQueue(...)` (:1242), `searchSongs(query:)` (:434), `getPlaylistAllTracks(...)` (:903), `getLyrics/getTimedLyrics` (:1146/:1177).
- The client is `@MainActor final class YTMusicClient: YTMusicClientProtocol`; `PlayerService` holds it as `ytMusicClient: (any YTMusicClientProtocol)?` (`PlayerService.swift:396`, injected via `setYTMusicClient` in `KasetApp.swift:102`).

> **Note for a "download as mp3" feature:** YouTube Music streams are **DRM/Widevine-protected and audio plays only inside the WebView** (`docs/playback.md` §Overview). The InnerTube `player` endpoint is NOT currently called by `YTMusicClient` (only `next`/`browse`/`search`), and no stream-URL/download code exists (`grep` for "download" in Services returns nothing). Reading *identity + metadata* is trivial (`currentTrack`); actually obtaining a decrypted audio stream is the hard/uncertain part and is not solved anywhere in this codebase.

## Entry Points

- **App launch:** `Sources/Kaset/KasetApp.swift` (`@main`) builds all services, wires DI, injects `@Environment`.
- **Window/background lifecycle:** `Sources/Kaset/AppDelegate.swift` — keeps the WebView alive on window close so audio continues (`windowShouldClose` returns false).
- **URL scheme:** `kaset://` handled by `Sources/Kaset/Services/URLHandler.swift` (`Info.plist` registers scheme).
- **AppleScript:** `Sources/Kaset/Services/Scripting/ScriptCommands.swift` + `Resources/Kaset.sdef`, using `PlayerService.shared`.

## Architectural Constraints

- **Threading:** almost entirely `@MainActor`. `PlayerService`, `YTMusicClient`, `SingletonPlayerWebView` are all main-actor isolated. Swift 6 strict concurrency — no `DispatchQueue`, use `async`/`await` (`AGENTS.md`).
- **Global/singletons:** `PlayerService.shared` (set once at init, never mutated — `PlayerService.swift:52-61`); `SingletonPlayerWebView.shared`; `WebKitManager.shared`; `SettingsManager.shared`; `SongLikeStatusManager.shared`. The single WebView is deliberate (prevents multiple audio streams).
- **Sandbox:** app-sandboxed. Writing a downloaded file outside the container needs an `NSSavePanel`-granted URL + `files.user-selected.read-write` entitlement (already present). Keychain hangs in ad-hoc builds; logging/`/tmp` unreliable (see STACK.md Sandbox).
- **Two sources never merge:** Music vs YouTube keep separate data models, clients, parsers, and player services. The **Playback Arbiter** pauses one when the other starts.

## Anti-Patterns

### Reading "now playing" by indexing the queue
**What happens:** code does `queueStorage[currentIndex].song` to find the current track.
**Why it's wrong:** queue-less plays (`play(videoId:)`, standalone episodes, restored sessions) set `currentTrack` without a matching queue entry, and index/entry sync is subtle (`activePlaybackQueueEntryID`, Smart Shuffle `.suggested` entries).
**Do this instead:** read `PlayerService.currentTrack` (`PlayerService.swift:120`). It is maintained as the single source of truth on every play/observer path.

### Guessing the currently-playing videoId from metadata
**What happens:** deriving the video from `currentTrack.title`/DOM text.
**Why it's wrong:** during track changes YouTube switches `videoId` before DOM title/artist catch up (`docs/playback.md`).
**Do this instead:** use `currentTrack.videoId`, cross-checked with `PlayerService.playbackStateVideoId` (`PlayerService.swift:170`) or `SingletonPlayerWebView.shared.currentVideoId` for the WebView's ground truth.

### Using a WebView (or new HTTP scraper) when an API client method exists
**What happens:** adding one-off `WKWebView` scraping or ad-hoc network code.
**Why it's wrong:** violates `AGENTS.md` "Prefer API over WebView"; auth/cookies must flow through `WebKitManager`.
**Do this instead:** add a method to `YTMusicClient` and explore the endpoint first with `swift run api-explorer` (mandatory per `AGENTS.md`).

## Error Handling

**Strategy:** typed throws + `async`. API errors surface as `YTMusicError` (`Sources/Kaset/Models/YTMusicError.swift`); throw `.authExpired` on HTTP 401/403 (`AGENTS.md`). No force-unwraps — use `guard`/optional handling.

**Presentation:** `Sources/Kaset/Services/ErrorPresenter.swift`.

## Cross-Cutting Concerns

**Logging:** `DiagnosticsLogger` (subsystem `com.sertacozercan.Kaset`); never `print()`. Sandbox suppresses much of it — use `NSTemporaryDirectory()` traces for diagnostics.
**Validation/parsing:** InnerTube JSON → `Sources/Kaset/Services/API/Parsers/` (`SongMetadataParser`, `ParsingHelpers`, `ResponseTreeSearch`).
**Authentication:** cookies + SAPISID from `WebKitManager` sign every `YTMusicClient`/`YouTubeClient` request; brand-account switching via `brandIdProvider` (`KasetApp.swift`).

---

*Architecture analysis: 2026-07-20*
