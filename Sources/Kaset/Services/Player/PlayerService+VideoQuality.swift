import Foundation

// MARK: - MusicVideoQualitySource

/// The async quality-control surface backing music video mode. The production
/// implementation is `SingletonPlayerWebView`; tests inject a recorder so the
/// discovery/retry logic can be exercised without a live WebView.
@MainActor
protocol MusicVideoQualitySource: AnyObject {
    func availableQualityLevels() async -> [String]
    func currentQualityLevel() async -> String?
    func setQualityLevel(_ level: String)
}

// MARK: - SingletonPlayerWebView + MusicVideoQualitySource

extension SingletonPlayerWebView: MusicVideoQualitySource {}

// MARK: - PlayerService Video Quality

/// Resolution selection for music **video mode** (Official Music Videos).
///
/// Parallels the YouTube side's quality handling (`YouTubePlayerService`), but
/// drives the music `SingletonPlayerWebView`'s `#movie_player`. Only meaningful
/// while `showVideo` is active; audio-only playback reports no levels. See
/// ADR-0023.
///
/// Discovery is keyed to the active `videoId` (mirroring
/// `YouTubePlayerService.updatePlaybackState`), not to the video-window-open
/// transition — so the quality menu repopulates when the track changes while
/// video mode stays open, and a slow/empty first probe can retry.
extension PlayerService {
    /// Loads the resolution levels for the current video if they haven't been
    /// loaded yet. Idempotent: the per-video guard is set only **after** a
    /// successful (non-empty) fetch, so empty probes on a not-yet-ready player
    /// are retried on the next call. Call this whenever the active video may
    /// have changed while `showVideo` is true.
    func refreshVideoQualityOptionsIfNeeded() async {
        guard self.showVideo, let videoId = self.currentTrack?.videoId else { return }
        guard self.videoQualityOptionsVideoId != videoId else { return }

        let levels = await self.videoQualitySource.availableQualityLevels()

        // Bail if the track changed out from under us mid-fetch — a later call
        // will handle the new video.
        guard self.currentTrack?.videoId == videoId else { return }

        guard !levels.isEmpty else {
            // Player not ready yet; leave the guard unset so we retry.
            return
        }

        let current = await self.videoQualitySource.currentQualityLevel()

        // Re-check after the second await as well, so a track change mid-fetch
        // can't leak the previous video's levels/quality onto the new track.
        guard self.currentTrack?.videoId == videoId else { return }

        self.videoQualityLevels = levels
        self.currentVideoQuality = current
        self.videoQualityOptionsVideoId = videoId
    }

    /// Selects a playback resolution and remembers it optimistically.
    func selectVideoQuality(_ level: String) {
        self.currentVideoQuality = level
        self.videoQualitySource.setQualityLevel(level)
        HapticService.toggle()
    }

    /// Clears per-track quality state (called from ``resetTrackStatus()``).
    func resetVideoQualityOptions() {
        self.videoQualityLevels = []
        self.currentVideoQuality = nil
        self.videoQualityOptionsVideoId = nil
    }
}
