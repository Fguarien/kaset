import Foundation
import Testing
@testable import Kaset

// MARK: - JukeboxDownloadServiceTests

/// Covers the request `JukeboxDownloadService` builds and the status it reports back.
///
/// Written at milestone close (2026-08-10): the download path had only ever been proven
/// from the backend side (curl, and ~46 mp3 produced on the NAS). Nothing pinned the
/// *client* half — the URL, the JSON keys the backend parses, and the state a toast reads.
/// These tests do, without a network or a signed-in account.
@Suite(.serialized, .tags(.api))
struct JukeboxDownloadServiceTests {
    /// Runs `body` with the shared settings pointed at `baseURL`, then restores the value.
    @MainActor
    private func withBaseURL(_ baseURL: String, _ body: () async throws -> Void) async rethrows {
        let previous = SettingsManager.shared.jukeboxBaseURL
        SettingsManager.shared.jukeboxBaseURL = baseURL
        defer { SettingsManager.shared.jukeboxBaseURL = previous }
        try await body()
    }

    private static func jsonResponse(_ url: URL, _ statusCode: Int, _ json: [String: Any]) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    @Test("Downloading a song POSTs videoId and metadata to <base>/download")
    @MainActor
    func downloadPostsTrackToBackend() async throws {
        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var seenURL: URL?
        nonisolated(unsafe) var seenMethod: String?
        nonisolated(unsafe) var seenContentType: String?
        nonisolated(unsafe) var seenBody: [String: Any] = [:]

        MockURLProtocol.setRequestHandler(for: session) { request in
            seenURL = request.url
            seenMethod = request.httpMethod
            seenContentType = request.value(forHTTPHeaderField: "Content-Type")
            if let body = request.httpBody ?? request.httpBodyStream.map(Data.init(reading:)) {
                seenBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            }
            return try Self.jsonResponse(request.url!, 200, ["status": "ok", "file": "kaset/Test Artist - Test Song.mp3"])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL("http://jukebox.test:8772") {
            let service = JukeboxDownloadService(session: session)
            let song = TestFixtures.makeSong(id: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artistName: "Rick Astley")

            #expect(service.canDownload(song))
            let ok = await service.download(song)

            #expect(ok)
            #expect(seenURL?.absoluteString == "http://jukebox.test:8772/download")
            #expect(seenMethod == "POST")
            #expect(seenContentType == "application/json")
            // Exactly the keys the FastAPI side reads — a rename here silently breaks tagging.
            #expect(seenBody["videoId"] as? String == "dQw4w9WgXcQ")
            #expect(seenBody["title"] as? String == "Never Gonna Give You Up")
            #expect(seenBody["artist"] as? String == "Rick Astley")
            #expect(seenBody["cover_url"] as? String == "https://example.com/thumb.jpg")
            #expect(service.status == .success(title: "Never Gonna Give You Up", file: "kaset/Test Artist - Test Song.mp3"))
        }
    }

    @Test("A backend skip counts as success — re-downloading an existing track is not an error")
    @MainActor
    func backendSkipIsSuccess() async throws {
        let session = MockURLProtocol.makeMockSession()
        MockURLProtocol.setRequestHandler(for: session) { request in
            try Self.jsonResponse(request.url!, 200, ["status": "skip", "file": "kaset/existing.mp3"])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL(SettingsManager.defaultJukeboxBaseURL) {
            let service = JukeboxDownloadService(session: session)
            let ok = await service.download(TestFixtures.makeSong())
            #expect(ok)
            #expect(service.status == .success(title: "Test Song", file: "kaset/existing.mp3"))
        }
    }

    @Test("A backend failure surfaces its reason instead of a generic error")
    @MainActor
    func backendFailureSurfacesReason() async throws {
        let session = MockURLProtocol.makeMockSession()
        MockURLProtocol.setRequestHandler(for: session) { request in
            try Self.jsonResponse(request.url!, 502, ["status": "fail", "reason": "no match on youtube"])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL(SettingsManager.defaultJukeboxBaseURL) {
            let service = JukeboxDownloadService(session: session)
            let ok = await service.download(TestFixtures.makeSong(title: "Broken Track"))
            #expect(!ok)
            #expect(service.status == .failure(title: "Broken Track", reason: "no match on youtube"))
        }
    }

    @Test("A song without a videoId fails before any network call")
    @MainActor
    func songWithoutVideoIDNeverHitsNetwork() async throws {
        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.setRequestHandler(for: session) { request in
            requestCount += 1
            return try Self.jsonResponse(request.url!, 200, ["status": "ok"])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL(SettingsManager.defaultJukeboxBaseURL) {
            let service = JukeboxDownloadService(session: session)
            let song = Song(
                id: "no-video",
                title: "Unplayable",
                artists: [],
                album: nil,
                duration: nil,
                thumbnailURL: nil,
                videoId: ""
            )

            #expect(!service.canDownload(song))
            let ok = await service.download(song)
            #expect(!ok)
            #expect(requestCount == 0)
            if case let .failure(title, _) = service.status {
                #expect(title == "Unplayable")
            } else {
                Issue.record("expected a failure status, got \(service.status)")
            }
        }
    }

    @Test("The Settings URL is honoured, whitespace and all")
    @MainActor
    func settingsBaseURLIsHonoured() async throws {
        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setRequestHandler(for: session) { request in
            seenURL = request.url
            return try Self.jsonResponse(request.url!, 200, ["status": "ok", "file": "x.mp3"])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL("  http://other-host:9999  ") {
            let service = JukeboxDownloadService(session: session)
            _ = await service.download(TestFixtures.makeSong())
            #expect(seenURL?.absoluteString == "http://other-host:9999/download")
        }
    }

    @Test("Collection state reports what the library is still missing")
    @MainActor
    func collectionStateParsesBackendCounts() async throws {
        let session = MockURLProtocol.makeMockSession()
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setRequestHandler(for: session) { request in
            seenURL = request.url
            return try Self.jsonResponse(request.url!, 200, [
                "total": 12,
                "present": 5,
                "missing": 7,
                "job": ["job_id": "job-42"],
            ])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL("http://jukebox.test:8772") {
            let service = JukeboxDownloadService(session: session)
            let state = await service.collectionState(name: "My Playlist", songs: TestFixtures.makeSongs(count: 12))

            #expect(seenURL?.absoluteString == "http://jukebox.test:8772/download/playlist/state")
            #expect(state?.total == 12)
            #expect(state?.present == 5)
            #expect(state?.missing == 7)
            #expect(state?.runningJobID == "job-42")
            #expect(state?.isPartiallyDownloaded == true)
            #expect(state?.isFullyDownloaded == false)
        }
    }

    @Test("Starting a playlist download returns the backend job id")
    @MainActor
    func startCollectionDownloadReturnsJobID() async throws {
        let session = MockURLProtocol.makeMockSession()
        MockURLProtocol.setRequestHandler(for: session) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/download/playlist") {
                return try Self.jsonResponse(request.url!, 200, ["job_id": "job-7"])
            }
            // The poll that `follow(jobID:)` kicks off — answer "done" so it stops at once.
            return try Self.jsonResponse(request.url!, 200, [
                "job_id": "job-7",
                "name": "My Playlist",
                "status": "done",
                "total": 3, "done": 3, "ok": 2, "skip": 1, "fail": 0,
                "current": "",
            ])
        }
        defer { MockURLProtocol.reset(session: session) }

        try await self.withBaseURL("http://jukebox.test:8772") {
            let service = JukeboxDownloadService(session: session)
            let jobID = await service.startCollectionDownload(name: "My Playlist", songs: TestFixtures.makeSongs(count: 3))
            #expect(jobID == "job-7")
        }
    }
}

private extension Data {
    /// Reads a body stream fully — `URLProtocol` hands large bodies over as a stream.
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 {
                break
            }
            self.append(buffer, count: read)
        }
    }
}
