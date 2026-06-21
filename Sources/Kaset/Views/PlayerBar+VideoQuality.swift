import SwiftUI

// MARK: - PlayerBar Video Quality Menu

extension PlayerBar {
    /// Resolution menu for music video mode. Mirrors the YouTube side's quality
    /// menu and reuses ``YouTubeQuality/displayName(for:)`` since the music
    /// `#movie_player` reports the same level identifiers. Shown only while
    /// video mode is active and the player has reported selectable levels.
    ///
    /// Takes the service explicitly so this lives in its own file (keeping
    /// `PlayerBar.swift` under the file-length limit) without widening the
    /// access level of `PlayerBar`'s private environment.
    func videoQualityMenu(_ player: PlayerService) -> some View {
        Menu {
            ForEach(player.videoQualityLevels, id: \.self) { level in
                Button {
                    player.selectVideoQuality(level)
                } label: {
                    if player.currentVideoQuality == level {
                        Label(YouTubeQuality.displayName(for: level), systemImage: "checkmark")
                    } else {
                        Text(YouTubeQuality.displayName(for: level))
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.PlayerBar.videoQualityButton)
        .accessibilityLabel(String(localized: "Video quality"))
    }
}
