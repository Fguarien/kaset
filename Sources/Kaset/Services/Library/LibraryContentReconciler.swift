import Foundation

// MARK: - LibraryContentSnapshot

/// Visible Library content plus the ID indexes that power membership checks.
struct LibraryContentSnapshot {
    var playlists: [Playlist]
    var albums: [Album]
    var artists: [Artist]
    var podcastShows: [PodcastShow]
    var uploadedSongsPlaylist: Playlist?
    var playlistIds: Set<String>
    var artistIds: Set<String>
    var podcastIds: Set<String>

    static let empty = LibraryContentSnapshot(
        playlists: [],
        albums: [],
        artists: [],
        podcastShows: [],
        uploadedSongsPlaylist: nil,
        playlistIds: [],
        artistIds: [],
        podcastIds: []
    )

    var hasVisibleContent: Bool {
        !self.playlists.isEmpty || !self.albums.isEmpty || !self.artists.isEmpty || !self.podcastShows.isEmpty
            || self.uploadedSongsPlaylist != nil
            || !self.playlistIds.isEmpty || !self.artistIds.isEmpty || !self.podcastIds.isEmpty
    }
}

// MARK: - LibraryContentReconciler

/// Reconciles optimistic local Library mutations with eventually-consistent backend snapshots.
///
/// YouTube Music can lag or oscillate after add/remove operations. This module owns the
/// optimistic pending state so callers can ask for visible Library content without knowing
/// the stabilization rules.
struct LibraryContentReconciler {
    struct Result {
        let snapshot: LibraryContentSnapshot
        let preservedExistingArtists: Bool
    }

    private static let playlistMutationStableMatchCount = 2
    private static let albumMutationStableMatchCount = 2
    private static let artistMutationStableMatchCount = 2

    private var pendingAddedPlaylists: [String: Playlist] = [:]
    private var pendingAddedPlaylistMatchCounts: [String: Int] = [:]
    private var pendingRemovedPlaylistKeys: Set<String> = []
    private var pendingRemovedPlaylistMissCounts: [String: Int] = [:]

    private var pendingAddedAlbums: [String: Album] = [:]
    private var pendingAddedAlbumMatchCounts: [String: Int] = [:]
    private var pendingRemovedAlbumIdentities: [String: Set<String>] = [:]
    private var pendingRemovedAlbumMissCounts: [String: Int] = [:]

    private struct ArtistReconciliationResult {
        let artists: [Artist]
        let artistKeys: Set<String>
        let preservedExistingArtists: Bool
    }

    private var pendingAddedArtists: [String: Artist] = [:]
    private var pendingAddedArtistMatchCounts: [String: Int] = [:]
    private var pendingRemovedArtistKeys: Set<String> = []
    private var pendingRemovedArtistMissCounts: [String: Int] = [:]

    mutating func apply(
        _ content: LibraryContentParser.LibraryContent,
        currentSnapshot: LibraryContentSnapshot
    ) -> Result {
        let playlists = self.reconciledPlaylists(from: content.playlists)
        let albums = self.reconciledAlbums(from: content.albums)
        let artistResult = self.reconciledArtists(from: content, currentSnapshot: currentSnapshot)
        let podcastShows = content.podcastShows

        return Result(
            snapshot: LibraryContentSnapshot(
                playlists: playlists,
                albums: albums,
                artists: artistResult.artists,
                podcastShows: podcastShows,
                uploadedSongsPlaylist: content.uploadedSongsPlaylist,
                playlistIds: Set(playlists.map(\.id)),
                artistIds: artistResult.artistKeys,
                podcastIds: Set(podcastShows.map(\.id))
            ),
            preservedExistingArtists: artistResult.preservedExistingArtists
        )
    }

    func needsArtistReconciliation(artistIds: [String], expectedInLibrary: Bool) -> Bool {
        let artistKeys = Set(artistIds.map { LibraryContentIdentity.artistKey(for: $0) })
        if expectedInLibrary {
            return artistKeys.contains { self.pendingAddedArtists[$0] != nil }
        }

        return artistKeys.contains { self.pendingRemovedArtistKeys.contains($0) }
    }

    mutating func addPlaylistId(_ playlistId: String, to snapshot: inout LibraryContentSnapshot) {
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.pendingRemovedPlaylistKeys.remove(playlistKey)
        self.pendingRemovedPlaylistMissCounts.removeValue(forKey: playlistKey)
        snapshot.playlistIds.insert(playlistId)
    }

    mutating func addPlaylist(_ playlist: Playlist, to snapshot: inout LibraryContentSnapshot) {
        snapshot.playlistIds.insert(playlist.id)
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlist.id)
        self.pendingRemovedPlaylistKeys.remove(playlistKey)
        self.pendingRemovedPlaylistMissCounts.removeValue(forKey: playlistKey)
        self.pendingAddedPlaylists[playlistKey] = playlist
        self.pendingAddedPlaylistMatchCounts[playlistKey] = 0

        if let existingIndex = snapshot.playlists.firstIndex(where: { LibraryContentIdentity.playlistKey(for: $0.id) == playlistKey }) {
            snapshot.playlists[existingIndex] = playlist
        } else {
            snapshot.playlists.insert(playlist, at: 0)
        }
    }

    /// Removes a locally-created playlist without recording a backend removal.
    /// Used when the account that owned the optimistic creation is no longer active.
    mutating func discardAddedPlaylist(_ playlistId: String, from snapshot: inout LibraryContentSnapshot) {
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.pendingAddedPlaylists.removeValue(forKey: playlistKey)
        self.pendingAddedPlaylistMatchCounts.removeValue(forKey: playlistKey)
        snapshot.playlistIds = LibraryContentIdentity.removingPlaylist(playlistId, from: snapshot.playlistIds)
        snapshot.playlists.removeAll { LibraryContentIdentity.playlistKey(for: $0.id) == playlistKey }
    }

    mutating func removePlaylistId(_ playlistId: String, from snapshot: inout LibraryContentSnapshot) {
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.pendingAddedPlaylists.removeValue(forKey: playlistKey)
        self.pendingAddedPlaylistMatchCounts.removeValue(forKey: playlistKey)
        self.pendingRemovedPlaylistKeys.insert(playlistKey)
        self.pendingRemovedPlaylistMissCounts[playlistKey] = 0
        snapshot.playlistIds = LibraryContentIdentity.removingPlaylist(playlistId, from: snapshot.playlistIds)
    }

    mutating func removePlaylist(_ playlistId: String, from snapshot: inout LibraryContentSnapshot) {
        self.removePlaylistId(playlistId, from: &snapshot)
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        snapshot.playlists.removeAll { LibraryContentIdentity.playlistKey(for: $0.id) == playlistKey }
    }

    mutating func addAlbum(_ album: Album, to snapshot: inout LibraryContentSnapshot) {
        let albumIdentities = LibraryContentIdentity.albumKeys(for: album)
        for removalKey in self.pendingRemovedAlbumIdentities.keys.filter({ key in
            guard let identities = self.pendingRemovedAlbumIdentities[key] else { return false }
            return !identities.isDisjoint(with: albumIdentities)
        }) {
            self.pendingRemovedAlbumIdentities.removeValue(forKey: removalKey)
            self.pendingRemovedAlbumMissCounts.removeValue(forKey: removalKey)
        }

        for pendingKey in self.pendingAddedAlbums.keys.filter({ key in
            guard let pendingAlbum = self.pendingAddedAlbums[key] else { return false }
            return LibraryContentIdentity.albumsMatch(pendingAlbum, album)
        }) {
            self.pendingAddedAlbums.removeValue(forKey: pendingKey)
            self.pendingAddedAlbumMatchCounts.removeValue(forKey: pendingKey)
        }

        self.pendingAddedAlbums[album.id] = album
        self.pendingAddedAlbumMatchCounts[album.id] = 0

        if let existingIndex = snapshot.albums.firstIndex(where: { LibraryContentIdentity.albumsMatch($0, album) }) {
            snapshot.albums[existingIndex] = album
        } else {
            snapshot.albums.insert(album, at: 0)
        }
    }

    mutating func removeAlbum(
        albumId: String,
        targetPlaylistId: String? = nil,
        from snapshot: inout LibraryContentSnapshot
    ) {
        var albumIdentities = Set([albumId])
        if let targetPlaylistId {
            albumIdentities.insert(targetPlaylistId)
        }

        for pendingKey in self.pendingAddedAlbums.keys.filter({ key in
            guard let pendingAlbum = self.pendingAddedAlbums[key] else { return false }
            return !LibraryContentIdentity.albumKeys(for: pendingAlbum).isDisjoint(with: albumIdentities)
        }) {
            self.pendingAddedAlbums.removeValue(forKey: pendingKey)
            self.pendingAddedAlbumMatchCounts.removeValue(forKey: pendingKey)
        }

        let removalKey = targetPlaylistId ?? albumId
        self.pendingRemovedAlbumIdentities[removalKey] = albumIdentities
        self.pendingRemovedAlbumMissCounts[removalKey] = 0
        snapshot.albums.removeAll { album in
            !LibraryContentIdentity.albumKeys(for: album).isDisjoint(with: albumIdentities)
        }
    }

    mutating func addPodcast(_ podcast: PodcastShow, to snapshot: inout LibraryContentSnapshot) {
        snapshot.podcastIds.insert(podcast.id)
        if !snapshot.podcastShows.contains(where: { $0.id == podcast.id }) {
            snapshot.podcastShows.insert(podcast, at: 0)
        }
    }

    mutating func addPodcastId(_ podcastId: String, to snapshot: inout LibraryContentSnapshot) {
        snapshot.podcastIds.insert(podcastId)
    }

    mutating func removePodcast(_ podcastId: String, from snapshot: inout LibraryContentSnapshot) {
        snapshot.podcastIds.remove(podcastId)
        snapshot.podcastShows.removeAll { $0.id == podcastId }
    }

    mutating func removePodcastId(_ podcastId: String, from snapshot: inout LibraryContentSnapshot) {
        snapshot.podcastIds.remove(podcastId)
    }

    mutating func addArtist(
        _ artist: Artist,
        libraryArtistId: String? = nil,
        to snapshot: inout LibraryContentSnapshot
    ) {
        let artistKey = LibraryContentIdentity.artistKey(for: libraryArtistId ?? artist.id)
        let canonicalArtist = LibraryContentIdentity.canonicalArtist(artist, libraryArtistID: artistKey)
        self.pendingRemovedArtistKeys.remove(artistKey)
        self.pendingRemovedArtistMissCounts.removeValue(forKey: artistKey)
        self.pendingAddedArtists[artistKey] = canonicalArtist
        self.pendingAddedArtistMatchCounts[artistKey] = 0
        snapshot.artistIds.insert(artistKey)

        if let existingIndex = snapshot.artists.firstIndex(where: { LibraryContentIdentity.artistKey(for: $0.id) == artistKey }) {
            snapshot.artists[existingIndex] = canonicalArtist
        } else {
            snapshot.artists.insert(canonicalArtist, at: 0)
        }
    }

    mutating func addArtistId(_ artistId: String, to snapshot: inout LibraryContentSnapshot) {
        let artistKey = LibraryContentIdentity.artistKey(for: artistId)
        self.pendingRemovedArtistKeys.remove(artistKey)
        self.pendingRemovedArtistMissCounts.removeValue(forKey: artistKey)
        snapshot.artistIds.insert(artistKey)
    }

    mutating func removeArtist(_ artistId: String, from snapshot: inout LibraryContentSnapshot) {
        self.removeArtistId(artistId, from: &snapshot)
        let artistKey = LibraryContentIdentity.artistKey(for: artistId)
        snapshot.artists.removeAll { LibraryContentIdentity.artistKey(for: $0.id) == artistKey }
    }

    mutating func removeArtistId(_ artistId: String, from snapshot: inout LibraryContentSnapshot) {
        let artistKey = LibraryContentIdentity.artistKey(for: artistId)
        self.pendingAddedArtists.removeValue(forKey: artistKey)
        self.pendingAddedArtistMatchCounts.removeValue(forKey: artistKey)
        self.pendingRemovedArtistKeys.insert(artistKey)
        self.pendingRemovedArtistMissCounts[artistKey] = 0
        snapshot.artistIds.remove(artistKey)
    }

    private mutating func reconciledPlaylists(from backendPlaylists: [Playlist]) -> [Playlist] {
        let rawPlaylistKeys = Set(backendPlaylists.map { LibraryContentIdentity.playlistKey(for: $0.id) })
        self.updatePendingPlaylistAdditions(rawPlaylistKeys: rawPlaylistKeys)
        self.updatePendingPlaylistRemovals(rawPlaylistKeys: rawPlaylistKeys)

        var playlists = backendPlaylists.filter { playlist in
            !self.pendingRemovedPlaylistKeys.contains(LibraryContentIdentity.playlistKey(for: playlist.id))
        }
        playlists = LibraryContentIdentity.deduplicatedPlaylists(playlists)
        var visiblePlaylistKeys = Set(playlists.map { LibraryContentIdentity.playlistKey(for: $0.id) })

        for (playlistKey, playlist) in self.pendingAddedPlaylists where !visiblePlaylistKeys.contains(playlistKey) {
            playlists.insert(playlist, at: 0)
            visiblePlaylistKeys.insert(playlistKey)
        }

        return playlists
    }

    private mutating func updatePendingPlaylistAdditions(rawPlaylistKeys: Set<String>) {
        for playlistKey in Array(self.pendingAddedPlaylists.keys) {
            if rawPlaylistKeys.contains(playlistKey) {
                self.pendingAddedPlaylistMatchCounts[playlistKey, default: 0] += 1
                if self.pendingAddedPlaylistMatchCounts[playlistKey, default: 0] >= Self.playlistMutationStableMatchCount {
                    self.pendingAddedPlaylists.removeValue(forKey: playlistKey)
                    self.pendingAddedPlaylistMatchCounts.removeValue(forKey: playlistKey)
                }
            } else {
                self.pendingAddedPlaylistMatchCounts[playlistKey] = 0
            }
        }
    }

    private mutating func updatePendingPlaylistRemovals(rawPlaylistKeys: Set<String>) {
        for playlistKey in Array(self.pendingRemovedPlaylistKeys) {
            if rawPlaylistKeys.contains(playlistKey) {
                self.pendingRemovedPlaylistMissCounts[playlistKey] = 0
                continue
            }

            self.pendingRemovedPlaylistMissCounts[playlistKey, default: 0] += 1
            if self.pendingRemovedPlaylistMissCounts[playlistKey, default: 0] >= Self.playlistMutationStableMatchCount {
                self.pendingRemovedPlaylistKeys.remove(playlistKey)
                self.pendingRemovedPlaylistMissCounts.removeValue(forKey: playlistKey)
            }
        }
    }

    private mutating func reconciledAlbums(from backendAlbums: [Album]) -> [Album] {
        self.updatePendingAlbumAdditions(backendAlbums: backendAlbums)
        self.updatePendingAlbumRemovals(backendAlbums: backendAlbums)

        var albums = backendAlbums.filter { album in
            let albumIdentities = LibraryContentIdentity.albumKeys(for: album)
            return self.pendingRemovedAlbumIdentities.values.allSatisfy { identities in
                albumIdentities.isDisjoint(with: identities)
            }
        }
        albums = LibraryContentIdentity.deduplicatedAlbums(albums)

        for album in self.pendingAddedAlbums.values where !albums.contains(where: { LibraryContentIdentity.albumsMatch($0, album) }) {
            albums.insert(album, at: 0)
        }

        return albums
    }

    private mutating func updatePendingAlbumAdditions(backendAlbums: [Album]) {
        for pendingKey in Array(self.pendingAddedAlbums.keys) {
            guard let pendingAlbum = self.pendingAddedAlbums[pendingKey] else { continue }
            if backendAlbums.contains(where: { LibraryContentIdentity.albumsMatch($0, pendingAlbum) }) {
                self.pendingAddedAlbumMatchCounts[pendingKey, default: 0] += 1
                if self.pendingAddedAlbumMatchCounts[pendingKey, default: 0] >= Self.albumMutationStableMatchCount {
                    self.pendingAddedAlbums.removeValue(forKey: pendingKey)
                    self.pendingAddedAlbumMatchCounts.removeValue(forKey: pendingKey)
                }
            } else {
                self.pendingAddedAlbumMatchCounts[pendingKey] = 0
            }
        }
    }

    private mutating func updatePendingAlbumRemovals(backendAlbums: [Album]) {
        for removalKey in Array(self.pendingRemovedAlbumIdentities.keys) {
            guard let removedIdentities = self.pendingRemovedAlbumIdentities[removalKey] else { continue }
            let backendStillContainsAlbum = backendAlbums.contains { album in
                !LibraryContentIdentity.albumKeys(for: album).isDisjoint(with: removedIdentities)
            }
            if backendStillContainsAlbum {
                self.pendingRemovedAlbumMissCounts[removalKey] = 0
                continue
            }

            self.pendingRemovedAlbumMissCounts[removalKey, default: 0] += 1
            if self.pendingRemovedAlbumMissCounts[removalKey, default: 0] >= Self.albumMutationStableMatchCount {
                self.pendingRemovedAlbumIdentities.removeValue(forKey: removalKey)
                self.pendingRemovedAlbumMissCounts.removeValue(forKey: removalKey)
            }
        }
    }

    private mutating func reconciledArtists(
        from content: LibraryContentParser.LibraryContent,
        currentSnapshot: LibraryContentSnapshot
    ) -> ArtistReconciliationResult {
        let preservedExistingArtists = content.artistsSource == .landingFallback && !currentSnapshot.artists.isEmpty
        let sourceArtists = preservedExistingArtists ? currentSnapshot.artists : content.artists
        let canonicalArtists = sourceArtists.map { LibraryContentIdentity.canonicalArtist($0) }
        let rawArtistKeys = Set(canonicalArtists.map(\.id))

        if content.artistsSource == .dedicated {
            self.updatePendingArtistAdditions(rawArtistKeys: rawArtistKeys)
            self.updatePendingArtistRemovals(rawArtistKeys: rawArtistKeys)
        }

        var artists = canonicalArtists.filter { artist in
            !self.pendingRemovedArtistKeys.contains(artist.id)
        }
        artists = LibraryContentIdentity.deduplicatedArtists(artists)
        var visibleArtistKeys = Set(artists.map(\.id))

        for (artistKey, artist) in self.pendingAddedArtists where !visibleArtistKeys.contains(artistKey) {
            artists.insert(artist, at: 0)
            visibleArtistKeys.insert(artistKey)
        }

        return ArtistReconciliationResult(
            artists: artists,
            artistKeys: visibleArtistKeys,
            preservedExistingArtists: preservedExistingArtists
        )
    }

    private mutating func updatePendingArtistAdditions(rawArtistKeys: Set<String>) {
        for artistKey in Array(self.pendingAddedArtists.keys) {
            if rawArtistKeys.contains(artistKey) {
                self.pendingAddedArtistMatchCounts[artistKey, default: 0] += 1
                if self.pendingAddedArtistMatchCounts[artistKey, default: 0] >= Self.artistMutationStableMatchCount {
                    self.pendingAddedArtists.removeValue(forKey: artistKey)
                    self.pendingAddedArtistMatchCounts.removeValue(forKey: artistKey)
                }
            } else {
                self.pendingAddedArtistMatchCounts[artistKey] = 0
            }
        }
    }

    private mutating func updatePendingArtistRemovals(rawArtistKeys: Set<String>) {
        for artistKey in Array(self.pendingRemovedArtistKeys) {
            if rawArtistKeys.contains(artistKey) {
                self.pendingRemovedArtistMissCounts[artistKey] = 0
                continue
            }

            self.pendingRemovedArtistMissCounts[artistKey, default: 0] += 1
            if self.pendingRemovedArtistMissCounts[artistKey, default: 0] >= Self.artistMutationStableMatchCount {
                self.pendingRemovedArtistKeys.remove(artistKey)
                self.pendingRemovedArtistMissCounts.removeValue(forKey: artistKey)
            }
        }
    }
}
