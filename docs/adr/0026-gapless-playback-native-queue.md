# ADR-0026: Gapless Playback via YouTube Music Native Queue

## Status

Accepted

## Context

Kaset plays YouTube Music through a singleton hidden `WKWebView` because DRM-protected
YouTube Music audio cannot be played through `AVPlayer`. Before this change, queue
advancement usually meant navigating the WebView to a new `watch` URL for every
track. That approach had two user-visible problems:

- a full page navigation could leave several seconds of silence between tracks;
- YouTube Music autoplay could briefly win the race and start an unrelated track
  before Kaset corrected back to its local queue.

Users reported this as both a gapless-playback feature request and a playback bug:
queued next tracks did not reliably start when the current track ended or when the
user pressed Next.

A native audio engine is not available for YouTube Music, so the realistic goal is
not sample-perfect gapless playback. The goal is to avoid unnecessary WebView page
reloads and let YouTube Music's own player perform the transition whenever Kaset
can safely keep YouTube Music's native queue aligned with Kaset's queue.

## Decision

Kaset keeps its local queue as the source of truth, but mirrors the next expected
track into YouTube Music's native **Up Next** queue ahead of time.

- `SingletonPlayerWebView` preloads the YouTube Music app shell after login so
  subsequent loads can prefer in-page router navigation over full page loads.
- `loadVideo(videoId:)` first tries YouTube Music's internal SPA router with a
  `watchEndpoint`; it falls back to a full `watch` URL only when the router is not
  available or rejects the command.
- `PlayerService+WebQueueSync` calls `syncWebQueue()` only when playback is in a
  stable state (`.playing` or `.paused`). It does not manipulate the player-bar DOM
  during `.loading`/router navigation.
- `SingletonPlayerWebView+QueueInjection` opens the current player-bar menu,
  positively identifies **Play next**, and uses a click-scoped `JSON.stringify`
  interceptor to swap that command's `videoIds` payload to Kaset's expected next
  video ID.
- Swift tracks queue injection as two separate states:
  - `pendingWebQueueInjectionVideoId`: an injection attempt has started but the
    WebView has not confirmed it;
  - `injectedWebQueueVideoId`: the WebView reported that the **Play next** payload
    was swapped for the currently expected next track.
- `handleTrackEnded(observedVideoId:)` trusts native auto-advance only when the
  confirmed injected video ID still matches the current expected next queue entry.
  Otherwise Kaset falls back to deterministic queue advancement through
  `play(song:)` / `loadVideo(videoId:)`.
- Any deterministic navigation, queue replacement, empty queue persistence, or
  stale result clears both Swift-side and page-side queue-injection state.
- Hidden preload and restored-session pages start with autoplay blocked. Explicit
  user actions such as Resume/Next/Previous unblock autoplay.

## Consequences

### Positive

- Queue transitions can be handled by YouTube Music's own player without reloading
  the whole WebView page for every track.
- Manual Next/Previous stay aligned with Kaset's queue through deterministic
  navigation, while natural track-end handling can still use native web-player
  transitions when confirmed safe.
- Duplicate tracks, stale `ended` events, failed injection attempts, queue edits,
  repeat modes, and mix/smart-shuffle continuation boundaries have explicit guard
  paths and regression tests.
- If native injection fails or becomes stale, playback correctness wins over
  gaplessness: Kaset performs a deterministic load instead of trusting the web
  queue blindly.

### Negative / Risks

- The queue-injection path depends on YouTube Music DOM structure and command
  payload shape, especially the player-bar menu and **Play next** command.
- The `JSON.stringify` interception is intentionally narrow and click-scoped, but
  it is still more fragile than a public API would be.
- Real-world gaplessness still depends on YouTube Music buffering, WebKit timing,
  network state, and YouTube's internal player behavior.
- The code must carefully cancel stale page-side injection attempts when Swift
  state changes, because same-document SPA navigation keeps JavaScript globals
  alive.

## Validation

The implementation adds/updates regression coverage in:

- `PlayerServiceWebQueueSyncTests`
- `PlayerServiceWebQueueSyncFollowUpTests`
- `PlayerServiceQueueTests`
- `AutoplayRecoveryTests`
- `PlayerServiceLibraryTests`

The covered cases include confirmed vs pending queue injection, stale injection
results, duplicate video IDs, empty/edited queues, manual Next/Previous, natural
track-end advancement, repeat modes, restored playback seeks, autoplay blocking,
and account-scoped like/dislike completion races.
