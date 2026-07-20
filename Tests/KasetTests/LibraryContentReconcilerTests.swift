import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.viewModel))
struct LibraryContentReconcilerTests {
    @Test("Playlist addition remains visible until backend stabilizes")
    func playlistAdditionRemainsVisibleUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        var snapshot = LibraryContentSnapshot.empty
        let playlist = TestFixtures.makePlaylist(id: "VLcreated-playlist", title: "Created Playlist")

        reconciler.addPlaylist(playlist, to: &snapshot)
        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.map(\.id) == ["VLcreated-playlist"])
        #expect(LibraryContentIdentity.containsPlaylist("created-playlist", in: snapshot.playlistIds))

        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.map(\.id) == ["VLcreated-playlist"])

        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.isEmpty)
        #expect(snapshot.playlistIds.isEmpty)
    }

    @Test("Playlist removal stays suppressed until backend stabilizes")
    func playlistRemovalStaysSuppressedUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        let playlist = TestFixtures.makePlaylist(id: "VLold-playlist", title: "Old Playlist")
        var snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: .empty).snapshot

        reconciler.removePlaylist("old-playlist", from: &snapshot)
        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.isEmpty)
        #expect(snapshot.playlistIds.isEmpty)

        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(playlists: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.isEmpty)

        snapshot = reconciler.apply(Self.content(playlists: [playlist]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.playlists.map(\.id) == ["VLold-playlist"])
    }

    @Test("Landing fallback preserves existing artist snapshot")
    func landingFallbackPreservesExistingArtists() {
        var reconciler = LibraryContentReconciler()
        let authoritativeArtist = TestFixtures.makeArtist(id: "UC-channel-1", name: "Artist 1")
        let fallbackArtist = TestFixtures.makeArtist(id: "UC-channel-2", name: "Artist 2")
        var snapshot = reconciler.apply(Self.content(artists: [authoritativeArtist]), currentSnapshot: .empty).snapshot

        let result = reconciler.apply(
            Self.content(artists: [fallbackArtist], artistsSource: .landingFallback),
            currentSnapshot: snapshot
        )
        snapshot = result.snapshot

        #expect(result.preservedExistingArtists)
        #expect(snapshot.artists.map(\.id) == ["UC-channel-1"])
        #expect(snapshot.artistIds == Set(["UC-channel-1"]))
    }

    @Test("Saved album snapshots update from backend content")
    func savedAlbumSnapshotsUpdateFromBackendContent() {
        var reconciler = LibraryContentReconciler()
        let firstAlbum = TestFixtures.makeAlbum(id: "MPRE-first", title: "First Album")
        let secondAlbum = TestFixtures.makeAlbum(id: "MPRE-second", title: "Second Album")

        var snapshot = reconciler.apply(Self.content(albums: [firstAlbum]), currentSnapshot: .empty).snapshot
        #expect(snapshot.albums == [firstAlbum])
        #expect(snapshot.hasVisibleContent)

        snapshot = reconciler.apply(Self.content(albums: [secondAlbum]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [secondAlbum])
    }

    @Test("Album addition remains visible until backend stabilizes")
    func albumAdditionRemainsVisibleUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        var snapshot = LibraryContentSnapshot.empty
        let optimisticAlbum = TestFixtures.makeAlbum(
            id: "MPRE-optimistic",
            title: "Optimistic Album",
            libraryTargetId: "OLAK-shared"
        )
        let backendAlbum = TestFixtures.makeAlbum(
            id: "MPRE-backend",
            title: "Backend Album",
            libraryTargetId: "OLAK-shared"
        )

        reconciler.addAlbum(optimisticAlbum, to: &snapshot)
        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [optimisticAlbum])

        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [backendAlbum])

        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)
    }

    @Test("Album removal stays suppressed until backend stabilizes")
    func albumRemovalStaysSuppressedUntilBackendStabilizes() {
        var reconciler = LibraryContentReconciler()
        let album = TestFixtures.makeAlbum(
            id: "MPRE-saved",
            title: "Saved Album",
            libraryTargetId: "OLAK-saved"
        )
        var snapshot = reconciler.apply(Self.content(albums: [album]), currentSnapshot: .empty).snapshot

        reconciler.removeAlbum(
            albumId: album.id,
            targetPlaylistId: album.libraryTargetId,
            from: &snapshot
        )
        snapshot = reconciler.apply(Self.content(albums: [album]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)

        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)

        snapshot = reconciler.apply(Self.content(albums: [album]), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums == [album])
    }

    @Test("Album removal matches MPRE-only snapshot when mutation also has OLAK target")
    func albumRemovalMatchesMPREOnlySnapshot() {
        var reconciler = LibraryContentReconciler()
        let backendAlbum = TestFixtures.makeAlbum(
            id: "MPRE-saved",
            title: "Saved Album",
            libraryTargetId: nil
        )
        var snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: .empty).snapshot

        reconciler.removeAlbum(
            albumId: backendAlbum.id,
            targetPlaylistId: "OLAK-saved",
            from: &snapshot
        )
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot

        #expect(snapshot.albums.isEmpty)
    }

    @Test("Album addition matches backend row that only returns MPRE identity")
    func albumAdditionMatchesMPREOnlyBackendRow() {
        var reconciler = LibraryContentReconciler()
        var snapshot = LibraryContentSnapshot.empty
        let optimisticAlbum = TestFixtures.makeAlbum(
            id: "MPRE-shared",
            title: "Optimistic Album",
            libraryTargetId: "OLAK-shared"
        )
        let backendAlbum = TestFixtures.makeAlbum(
            id: "MPRE-shared",
            title: "Backend Album",
            libraryTargetId: nil
        )

        reconciler.addAlbum(optimisticAlbum, to: &snapshot)
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot
        snapshot = reconciler.apply(Self.content(albums: [backendAlbum]), currentSnapshot: snapshot).snapshot

        #expect(snapshot.albums == [backendAlbum])

        snapshot = reconciler.apply(Self.content(albums: []), currentSnapshot: snapshot).snapshot
        #expect(snapshot.albums.isEmpty)
    }

    @Test("Artist removal stays suppressed through stale backend response")
    func artistRemovalStaysSuppressedThroughStaleBackendResponse() {
        var reconciler = LibraryContentReconciler()
        let artist = TestFixtures.makeArtist(id: "MPLAUC-channel-1", name: "Artist 1")
        var snapshot = reconciler.apply(Self.content(artists: [artist]), currentSnapshot: .empty).snapshot

        reconciler.removeArtist("UC-channel-1", from: &snapshot)
        snapshot = reconciler.apply(Self.content(artists: [artist]), currentSnapshot: snapshot).snapshot

        #expect(snapshot.artists.isEmpty)
        #expect(snapshot.artistIds.isEmpty)
        #expect(reconciler.needsArtistReconciliation(artistIds: ["MPLAUC-channel-1"], expectedInLibrary: false))
    }

    private static func content(
        playlists: [Playlist] = [],
        albums: [Album] = [],
        artists: [Artist] = [],
        podcastShows: [PodcastShow] = [],
        artistsSource: LibraryContentParser.LibraryArtistsSource = .dedicated
    ) -> LibraryContentParser.LibraryContent {
        LibraryContentParser.LibraryContent(
            playlists: playlists,
            albums: albums,
            artists: artists,
            podcastShows: podcastShows,
            artistsSource: artistsSource
        )
    }
}
