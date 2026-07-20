# Technology Stack

**Analysis Date:** 2026-07-20

## Languages

**Primary:**
- Swift 6.0 (language mode `.v6`, toolchain `swift-tools-version: 6.2`) — all app/source code under `Sources/Kaset/` (~340 Swift files)
- JavaScript (ES) — one file, `worker/src/index.js` (Cloudflare Worker), plus injected WebView user scripts embedded as Swift string literals

**Secondary:**
- AppleScript definition — `Sources/Kaset/Resources/Kaset.sdef` (scripting bridge, wired in `Info.plist` via `OSAScriptingDefinition`)

## Runtime

**Environment:**
- macOS **15.4 minimum** declared in `Package.swift` (`platforms: [.macOS("15.4")]`).
- **BUT** `AGENTS.md` states the intended target is **macOS 26.0+ / Swift 6.0+**. macOS 26-only features (Apple Intelligence / FoundationModels, Liquid Glass `.glassEffect()`) are gated behind `@available(macOS 26, *)`. macOS 15 gets a fallback path (see `Tests/KasetUITests/MacOS15FallbackUITests.swift`).
- Native macOS app, sandboxed (see Sandbox below).

**Package Manager:**
- Swift Package Manager (SPM) — `Package.swift` at repo root. Executable products: `Kaset` (app), `api-explorer` (CLI).
- Worker side: npm (`worker/`, wrangler). Separate, deploy-only.
- Lockfile: `Package.resolved` (SPM-managed; not committed in the file list but SPM-standard).

## Frameworks

**Core (Apple, no import needed as SPM deps):**
- SwiftUI — all UI under `Sources/Kaset/Views/` (120 files)
- Observation (`@Observable` / `@MainActor`) — state objects (`PlayerService`, etc.)
- WebKit (`WKWebView`) — playback/auth surfaces (see WebKit section)
- AVFoundation / CoreAudio — equalizer via process tap (`Sources/Kaset/Services/Audio/`)
- FoundationModels (Apple Intelligence) — AI features, macOS 26+ only, `Sources/Kaset/Services/AI/`
- CoreTransferable — `Song: Transferable` drag/drop (`Sources/Kaset/Models/Song.swift`)

**Third-party SPM dependencies (only ONE):**
- **Sparkle** `2.8.1+` (`https://github.com/sparkle-project/Sparkle`) — auto-update. Config in `Info.plist` (`SUFeedURL` → `appcast.xml`, `SUPublicEDKey`). Service: `Sources/Kaset/Services/UpdaterService.swift`.

> ⚠️ `AGENTS.md` rule: **No third-party frameworks may be added without asking.** Sparkle is the sole external dependency.

**Testing:**
- Swift Testing (`@Test`, `@Suite`, `#expect`) — mandated for all new unit tests (`AGENTS.md`)
- XCTest — legacy + UI tests (`Tests/KasetUITests/`)

## Build System

**CLI-first (default workflow, per `AGENTS.md`):**
```bash
swift build                      # Build the app
swift test --skip KasetUITests   # Unit tests (NEVER combine with UI tests)
swift run api-explorer <cmd>     # InnerTube API explorer CLI (Sources/APIExplorer/main.swift)
swiftlint --strict && swiftformat .   # Lint + format (required before commit)
```

**Xcode / xcodebuild:** escalation only — used for the UI-test project `KasetUITests.xcodeproj`, simulator, screenshots, or scheme-specific runtime debugging. There is **no packaged .xcodeproj for the main app**; the app builds via SPM + a `build-app.sh` (referenced in `Package.swift` comments) that compiles the string catalog for the packaged `.app`.

**SPM targets** (`Package.swift`):
- `Kaset` (executableTarget) — main app. Strict concurrency enabled (`.enableExperimentalFeature("StrictConcurrency")`, `.swiftLanguageMode(.v6)`). Resources: `Assets.xcassets`, 16 `.lproj` localizations, `Kaset.sdef`, and a `.copy("Extensions")` dir (browser web-extensions payload; currently only `.gitkeep`).
- `APIExplorer` (executableTarget) — `Sources/APIExplorer/main.swift`, InnerTube endpoint explorer.
- `KasetTests` (testTarget) — unit tests, `Fixtures/` resources. **Excludes** 11 AI/FoundationModels test files (macOS 26-only APIs don't compose with Swift Testing macros).

**Formatting quirk:** `.swiftformat` uses `--self insert` → explicit `self.` on instance members and `Self.` on static calls. Always run `swiftformat .` before finishing.

## Sandbox & Entitlements

`Kaset.entitlements`:
- `com.apple.security.app-sandbox` = true (**app is sandboxed** — has major runtime consequences)
- `com.apple.security.network.client` = true (outbound HTTP only)
- `com.apple.security.files.user-selected.read-write` + `files.bookmarks.app-scope` — **user-selected file write access** (relevant for a download-to-disk feature: writing outside the container requires an `NSOpenPanel`/`NSSavePanel`-granted URL + security-scoped bookmark)
- `com.apple.security.device.audio-input` — CoreAudio process tap (equalizer)
- `com.apple.security.cs.jit` — required by WebKit
- Sparkle mach-lookup exceptions for sandboxed installer

**Sandbox gotchas (from `AGENTS.md` / `docs/common-bug-patterns.md`):**
- Ad-hoc/debug builds **hang in `SecItemCopyMatching`** (Keychain). `#if DEBUG` stores cookies in Application Support `Kaset/cookies.dat`, bypassing Keychain. Override with `KASET_DEBUG_COOKIE_STORAGE=keychain`.
- `os_log`/`Logger` `.info`/`.debug` often don't surface; hardcoded `/tmp` writes are blocked. Use `NSTemporaryDirectory()` → `~/Library/Containers/com.sertacozercan.Kaset/Data/tmp/`.
- Bundle ID: `com.sertacozercan.Kaset`.

## How WebKit Is Used

WebKit is **not** the general data layer — it is confined to three surfaces (`AGENTS.md`: "Prefer API over WebView"):

1. **Music playback (DRM):** `SingletonPlayerWebView` (a single hidden `WKWebView`) loads `music.youtube.com` watch pages so Widevine-protected Premium audio plays. Native AVPlayer cannot do this (bot detection + DRM + user-gesture requirement). Files: `Sources/Kaset/Views/MiniPlayerWebView.swift` (+ `SingletonPlayerWebView+*` extensions).
2. **YouTube video playback:** `YouTubeWatchWebView` / `YouTubePlayerService` (`Sources/Kaset/Services/Player/YouTubePlayerService.swift`).
3. **Authentication + cookies:** `Sources/Kaset/Services/WebKit/WebKitManager.swift` (+ `WebKitManager+Cookies.swift`, `+AuthMaterial.swift`). Holds the `WKWebsiteDataStore`, cookies, and SAPISID material used to sign InnerTube API calls.

Everything else (search, library, playlists, metadata, lyrics) goes through the **InnerTube HTTP API** via `YTMusicClient` / `YouTubeClient`, not WebViews.

**WebView ⇄ Swift bridge:** JS user scripts injected into the player page post messages to `window.webkit.messageHandlers.singletonPlayer`; Swift receives them in `WKScriptMessageHandler.userContentController(_:didReceive:)` (implemented in `MiniPlayerWebView.swift` / `MiniPlayerWebView+Coordinator.swift`). Message types include `STATE_UPDATE`, `TRACK_ENDED`, `PLAYBACK_AUDIO_QUALITY_STATS`.

## The `worker/` Directory

A standalone **Cloudflare Worker** (`worker/src/index.js`, `worker/wrangler.toml`, name `kaset-lastfm`) — **not part of the macOS build**. It is a Last.fm signing proxy: the app sends unsigned scrobble/now-playing requests; the Worker adds `api_key` + computes `api_sig` (MD5) server-side so the Last.fm shared secret never ships in the app binary. Endpoints: `/health`, `/auth/token`, `/auth/url`, `/auth/session`, `/auth/validate`, `/nowplaying`, `/scrobble`. App-side counterpart: `Sources/Kaset/Services/Scrobbling/`. Secrets set via `wrangler secret put LASTFM_API_KEY / LASTFM_SHARED_SECRET`. Irrelevant to a download feature.

## Key Dependencies (Data Layer)

**Critical:**
- `YTMusicClient` (`Sources/Kaset/Services/API/YTMusicClient.swift`) — InnerTube (`https://music.youtube.com/youtubei/v1`) client, client version `WEB_REMIX 1.20231204.01.00`. Auth via WebKit-sourced cookies/SAPISID. `@MainActor final class`.
- `YouTubeClient` (`Sources/Kaset/Services/API/YouTubeClient.swift`) — regular YouTube InnerTube surface.
- `AuthService` + `WebKitManager` — supply cookies/API keys to the clients.
- `APICache` (`Sources/Kaset/Services/API/APICache.swift`) — TTL-based response cache.

**Infrastructure:**
- `DiagnosticsLogger` (`Sources/Kaset/Utilities/`) — logging (subsystem `com.sertacozercan.Kaset`). Use instead of `print()`.
- `SettingsManager` (`Sources/Kaset/Services/SettingsManager.swift`) — user prefs singleton.

## Configuration

**App config:** `Info.plist` (URL scheme `kaset://`, Sparkle keys, AppleScript, audio-capture usage strings), `Kaset.entitlements`, `version.env`.

**Env vars (dev/test):** `KASET_DEBUG_COOKIE_STORAGE`, plus `UITestConfig` environment keys for injecting mock player/track state (`Sources/Kaset/Utilities/UITestConfig`).

## Test Setup

- Unit: `Tests/KasetTests/` — Swift Testing, `Fixtures/` JSON. Run `swift test --skip KasetUITests`.
- UI: `Tests/KasetUITests/` + `KasetUITests.xcodeproj` — XCUITest; **requires human permission to run** (`AGENTS.md`). Mock clients: `MockUITestYTMusicClient`, `MockUITestYouTubeClient` injected in `KasetApp.swift` when `UITestConfig.isUITestMode`.
- AI tests excluded from SPM test target (macOS 26 gating).

## Platform Requirements

**Development:** macOS with Swift 6.2 toolchain (Xcode 26 era). SwiftLint + SwiftFormat installed.
**Production:** macOS 15.4+ (nominal) / 26+ (full feature set). Distributed as a signed, sandboxed `.app`, auto-updated via Sparkle appcast on GitHub (`sozercan/kaset`). Homebrew Cask in `Casks/`.

---

*Stack analysis: 2026-07-20*
