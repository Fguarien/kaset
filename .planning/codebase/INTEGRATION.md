# Integration Map — "Download current song as mp3"

**Analysis Date:** 2026-07-20
**Feature:** Add a UI action that POSTs the currently-playing song's `videoId` + metadata to the homelab jukebox backend (`http://10.234.1.43:8772`), then shows progress/result.
**App:** kaset (Swift/SwiftUI, macOS, fork of sozercan/kaset). SwiftPM package (`Package.swift`) + `Kaset.entitlements` + `Info.plist`.

---

## TL;DR

- **Best UI hook:** add a `DownloadSongContextMenu` item alongside `ShareContextMenu` in the current-song context menu at `Sources/Kaset/Views/PlayerBar.swift:851` (and mirror it in the queue row at `Sources/Kaset/Views/QueueView.swift:212`). Optional secondary: a dedicated `PlayerBarIconButton` in the player bar's `playbackOptionsSection` (`PlayerBar.swift:700`).
- **Current-song accessor:** `PlayerService.currentTrack` → `Song?` (`Sources/Kaset/Services/Player/PlayerService.swift:120`). Injected everywhere via `@Environment(PlayerService.self)`. Gives `videoId`, `title`, `artists`, `album`, `duration`, `thumbnailURL`.
- **Networking:** No generic HTTP client, but `LastFMService` (`Sources/Kaset/Services/Scrobbling/LastFMService.swift`) is a ready-made template: `@MainActor @Observable final class` doing `URLSession` JSON POST. Copy its `postJSON(...)` pattern into a new `JukeboxDownloadService`.
- **Sandbox caveat:** app IS sandboxed with `com.apple.security.network.client` (outgoing allowed), but there is **no `NSAppTransportSecurity` block** in `Info.plist`. A plain-HTTP request to `10.234.1.43` will be blocked by ATS. Must add an ATS exception (see Section C).
- **Settings:** `SettingsManager` (`Sources/Kaset/Services/SettingsManager.swift`) — singleton, `@Observable`, UserDefaults-backed. Add a `jukeboxBaseURL` key here; expose a `TextField` in a settings tab (e.g. `ExtensionsSettingsView` or a new tab in `KasetApp.swift:753`).

---

## A. UI ACTION HOOK

### Recommended primary: context-menu item in the player bar (mirror `ShareContextMenu`)

The player bar already builds a rich context menu for the current track. The closest analog to "Download" is the existing **Share** item, wired at:

- `Sources/Kaset/Views/PlayerBar.swift:851` — `ShareContextMenu.menuItem(for: track)` inside `currentSongContextMenu(for track: Song)` (function starts `PlayerBar.swift:822`).
- That context menu is attached to the song-info section at `PlayerBar.swift:151`:
  ```swift
  .contextMenu {
      if let track = self.playerService.currentTrack {
          self.currentSongContextMenu(for: track)   // PlayerBar.swift:152-154
      }
  }
  ```

**How similar menu items are structured** — all are static `@MainActor enum` or small `struct` builders returning `some View`, each a `Button { action } label: { Label(..., systemImage:) }`:
- `ShareContextMenu.menuItem(for:)` — `Sources/Kaset/Views/SharedViews/ShareContextMenu.swift:48`
- `AddToQueueContextMenu` (a `struct: View`) — `Sources/Kaset/Views/SharedViews/SongContextMenus.swift:56`
- `StartRadioContextMenu.menuItem(for:playerService:)` — used at `PlayerBar.swift:834`
- `LikeDislikeContextMenu` — `SongContextMenus.swift:7`

**Recommendation:** Create `Sources/Kaset/Views/SharedViews/DownloadSongContextMenu.swift` following the `ShareContextMenu` enum shape:
```swift
@MainActor
enum DownloadSongContextMenu {
    @ViewBuilder
    static func menuItem(for song: Song, service: JukeboxDownloadService) -> some View {
        Button {
            Task { await service.download(song) }
        } label: {
            Label(String(localized: "Download as MP3"), systemImage: "arrow.down.circle")
        }
    }
}
```
Insert one line after `PlayerBar.swift:851` (after the Share divider). It automatically has `track` in scope.

### Recommended secondary: same item on the queue row

Queue rows already carry `.contextMenu` with Favorites/Radio/Share at `Sources/Kaset/Views/QueueView.swift:203-221` (Share at `QueueView.swift:212`). Add the download item there too, using `self.song` which is already the row's `Song`. This lets the user download any queued song, not just the current one.

### Optional tertiary: a toolbar-style icon button in the player bar

The player bar's right cluster (`playbackOptionsSection`, `PlayerBar.swift:700-709`) is composed of `PlayerBarIconButton`s (lyrics/queue/picture/miniPlayer, `PlayerBar.swift:711-803`). A download button could be added here following the `lyricsButton`/`queueButton` pattern (each is a computed `var ... : some View` returning a `PlayerBarIconButton` with `action:`, `accessibilityID:`, `icon:`). This is more discoverable than a context menu but costs horizontal space (section is fixed `width: 142`, `PlayerBar.swift:64`). Prefer the context menu unless a persistent affordance is required.

### NOT recommended: CommandBar

`Sources/Kaset/ViewModels/CommandBarViewModel.swift` is an **AI/natural-language** command parser (Foundation Models), not a static command palette. Adding a deterministic "download" verb there is high-effort and mismatched. Skip it.

### Keyboard shortcut (optional)

`.keyboardShortcut` is used exactly once — the video button at `PlayerBar.swift:778` (`"v", modifiers: [.command, .shift]`). If a shortcut is desired, attach `.keyboardShortcut(...)` to the download button using the same pattern.

---

## B. CURRENT-SONG ACCESS

**Observable object:** `PlayerService` — `@MainActor @Observable final class`, injected as `@Environment(PlayerService.self) private var playerService` (see `PlayerBar.swift:14`). Registered as an environment object in `Sources/Kaset/KasetApp.swift:199`.

**Accessor:** `playerService.currentTrack` → `Song?`
- Declared at `Sources/Kaset/Services/Player/PlayerService.swift:120`.
- In the player-bar context menu the non-optional `track: Song` is already unwrapped and passed in (`PlayerBar.swift:823`, `:852`).

**`Song` model** (`Sources/Kaset/Models/Song.swift`) — the exact fields to send to jukebox:
- `videoId: String` (`Song.swift:14`) — **the primary identifier for the backend POST.**
- `title: String` (`Song.swift:8`)
- `artists: [Artist]` → `artistsDisplay: String` convenience (comma-joined, `Song.swift:133`)
- `album: Album?` (`Song.swift:10`)
- `duration: TimeInterval?` (`Song.swift:11`) + `durationDisplay` (`Song.swift:138`)
- `thumbnailURL: URL?` (`Song.swift:13`); public fallbacks: `fallbackThumbnailURL` → `https://i.ytimg.com/vi/<videoId>/hqdefault.jpg` (`Song.swift:146`).
- A canonical watch URL is not on `Song` directly but `Song.shareURL` exists (used by `ShareContextMenu`, `ShareContextMenu.swift:49`) — reuse it if the backend wants a full YouTube URL, or just build `https://music.youtube.com/watch?v=<videoId>`.

Related current-track state on `PlayerService` if needed: `currentEpisode: ArtistEpisode?` (`PlayerService.swift:130`, podcasts — probably exclude from download), `currentTrackHasVideo` (`:380`), `state: PlaybackState` (`:109`).

---

## C. NETWORKING

### No shared generic HTTP client — but a clean template exists

There is **no** `Services/Networking` layer or reusable `HTTPClient`. `URLSession` is used ad-hoc in a handful of services:
- `Sources/Kaset/Services/Scrobbling/LastFMService.swift` — **best template** (JSON POST via Worker proxy)
- `Sources/Kaset/Services/API/YTMusicClient.swift`, `YouTubeClient.swift`, `APISessionConfiguration.swift` — YouTube InnerTube clients (heavier, cookie/auth-bound)
- `Sources/Kaset/Services/Lyrics/Providers/LRCLibProvider.swift` — simple GET
- `Sources/Kaset/Services/WebKit/WebKitManager.swift`

**Reuse pattern from `LastFMService`** (`LastFMService.swift:308-326`):
```swift
nonisolated private func postJSON(endpoint: String, bodyData: Data, baseURL: URL) async throws -> [String: Any] {
    let url = baseURL.appendingPathComponent(endpoint)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = bodyData
    let (data, httpResponse) = try await self.session.data(for: request)
    // guard HTTPURLResponse, JSONSerialization ...
}
```
Note the whole class shape: `@MainActor @Observable final class LastFMService` (`:7-9`) with `private(set) var authState` for observable status, injected `session: URLSession = .shared` (`:39`), and `DiagnosticsLogger.scrobbling` logging (`:17`). This is exactly the shape a new `JukeboxDownloadService` should take, with a `private(set) var downloadState` enum (`.idle/.uploading/.success/.failed`) that the UI observes for progress.

**Where to create it:** `Sources/Kaset/Services/` (e.g. a new `Services/Jukebox/JukeboxDownloadService.swift`). Register it as an environment object next to the others in `KasetApp.swift:196-215` so views can read progress via `@Environment(JukeboxDownloadService.self)`.

### No existing download / export / save-file code

Grep for `download`/`NSSavePanel`/`.write(to:` found only image-cache and localization strings — **no file-download or export feature exists**. Since the actual mp3 write happens on the jukebox backend, the app only needs a fire-and-forget POST + status; no `NSSavePanel` or file writing is required. (Entitlements `com.apple.security.files.user-selected.read-write` and app-scoped bookmarks exist in `Kaset.entitlements` if a local save is ever added.)

### App Sandbox / ATS — IMPORTANT for the LAN plain-HTTP POST

`Kaset.entitlements`:
- `com.apple.security.app-sandbox = true` (sandboxed)
- `com.apple.security.network.client = true` → **outgoing network is permitted** by the sandbox.

However, `Info.plist` has **no `NSAppTransportSecurity` dictionary**. App Transport Security therefore blocks arbitrary plain-`http://` loads by default. A POST to `http://10.234.1.43:8772` will fail with an ATS error (`-1022 / NSURLErrorAppTransportSecurityRequiresSecureConnection`).

**Fix (required):** add an ATS exception to `Info.plist`. Least-broad option is a per-domain exception (works for the IP literal):
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>10.234.1.43</key>
        <dict>
            <key>NSExceptionAllowsInsecureHTTPLoads</key>
            <true/>
            <key>NSIncludesSubdomains</key>
            <false/>
        </dict>
    </dict>
</dict>
```
Alternative if the backend URL is user-configurable (arbitrary LAN host): use `NSAllowsLocalNetworking` (`<true/>`) which permits cleartext to `.local`, unqualified, and private-range hosts without whitelisting a specific IP. This pairs well with the configurable-URL setting in Section D. (macOS may also prompt for Local Network permission on first connect under recent OS versions.)

---

## D. SETTINGS

**Store:** `Sources/Kaset/Services/SettingsManager.swift` — `@MainActor @Observable final class SettingsManager`, `static let shared`, all values persisted to `UserDefaults.standard` via `didSet`. This is the single source of truth for preferences (the app does **not** use `@AppStorage` for user settings; `@AppStorage` appears only in a few isolated player/EQ spots).

**How to add the configurable backend URL:**
1. Add a key in the `Keys` enum (`SettingsManager.swift:13-39`), e.g. `static let jukeboxBaseURL = "settings.jukeboxBaseURL"`.
2. Add a stored property mirroring the existing pattern (e.g. `scrobbleMinSeconds`, `SettingsManager.swift:301`):
   ```swift
   var jukeboxBaseURL: String {
       didSet { UserDefaults.standard.set(self.jukeboxBaseURL, forKey: Keys.jukeboxBaseURL) }
   }
   ```
3. Initialize in `private init()` (`SettingsManager.swift:457`) with default `"http://10.234.1.43:8772"`:
   ```swift
   self.jukeboxBaseURL = UserDefaults.standard.string(forKey: Keys.jukeboxBaseURL) ?? "http://10.234.1.43:8772"
   ```

**Where to expose the UI field:** the Settings scene is a `TabView` in `KasetApp.swift:747-795` (`SettingsView`). Each tab is a `Form`/`Section`-based view (see `ScrobblingSettingsView` which uses `Section { ... }`, `ScrobblingSettingsView.swift:13,41`, and reads `@State private var settings = SettingsManager.shared`, `:37`). Options:
- Add a `TextField` binding to `settings.jukeboxBaseURL` inside an existing tab — `ExtensionsSettingsView` (`KasetApp.swift:791`) or `GeneralSettingsView` (`KasetApp.swift:754`) are natural homes for a homelab/integration setting.
- Or add a new tab (e.g. "Jukebox") to the `TabView` at `KasetApp.swift:753` following the `.tabItem { Label(..., systemImage:) }` pattern.

Read the setting from the service: `URL(string: SettingsManager.shared.jukeboxBaseURL)`.

---

## Summary for planner

1. **Hook:** new `DownloadSongContextMenu.menuItem(for:service:)` inserted after `PlayerBar.swift:851` (current song) + `QueueView.swift:212` (any queue row). Optional icon button in `PlayerBar.swift:700` cluster.
2. **Data:** `playerService.currentTrack: Song?` (`PlayerService.swift:120`) → `.videoId`, `.title`, `.artistsDisplay`, `.album`, `.duration`, `.thumbnailURL` (`Song.swift`).
3. **Networking:** new `JukeboxDownloadService` modeled on `LastFMService` (`LastFMService.swift:7,308`); register in `KasetApp.swift:~199`; observe `downloadState` for progress; feedback via local `ToastView` (`Views/ToastView.swift`, presented through `@State` + `.overlay(alignment:.top)` — there is no global toast center).
4. **Sandbox:** outgoing network already allowed; **must add ATS exception** (`NSExceptionDomains` for `10.234.1.43`, or `NSAllowsLocalNetworking`) to `Info.plist` — currently absent.
5. **Settings:** add `jukeboxBaseURL` to `SettingsManager` (`SettingsManager.swift:13/301/457`), expose `TextField` in a Settings tab (`KasetApp.swift:753`).

---

*Integration analysis: 2026-07-20*
