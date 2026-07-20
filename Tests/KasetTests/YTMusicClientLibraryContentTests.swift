import Foundation
import Testing
@testable import Kaset

// MARK: - YTMusicClientLibraryRequestTests

@Suite(.serialized, .tags(.api), .timeLimit(.minutes(1)))
@MainActor
struct YTMusicClientLibraryRequestTests {
    @Test("Library content fetches all saved album pages and stops on a repeated token")
    func libraryContentFetchesAllSavedAlbumPages() async throws {
        APICache.shared.invalidateAll()
        let session = MockURLProtocol.makeMockSession()
        let recorder = LibraryRequestRecorder()

        MockURLProtocol.setRequestHandler(for: session) { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let response = try #require(
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )
                )
                return (response, Data(#"ytcfg.set({"INNERTUBE_API_KEY":"REDACTED"});"#.utf8))
            }

            let bodyData = try LibraryRequestTestSupport.bodyData(from: request)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )

            let payload: [String: Any]
            let statusCode: Int
            if let continuation = body["continuation"] as? String {
                recorder.appendCursor(continuation)
                switch continuation {
                case "albums-page-2":
                    payload = Self.libraryAlbumsContinuationPayload(
                        albumID: "MPREALBUMB",
                        title: "Album B",
                        nextPage: "albums-page-3"
                    )
                    statusCode = 200
                case "albums-page-3":
                    payload = Self.libraryAlbumsContinuationPayload(
                        albumID: "MPREALBUMC",
                        title: "Album C",
                        nextPage: "albums-page-2"
                    )
                    statusCode = 200
                default:
                    payload = [:]
                    statusCode = 400
                }
            } else if let browseID = body["browseId"] as? String {
                recorder.appendBrowseID(browseID)
                switch browseID {
                case "FEmusic_liked_albums":
                    payload = Self.libraryAlbumsPagePayload(
                        albumID: "MPREALBUMA",
                        title: "Album A",
                        nextPage: "albums-page-2"
                    )
                    statusCode = 200
                case "FEmusic_library_landing",
                     "FEmusic_liked_playlists",
                     "FEmusic_library_corpus_artists",
                     Playlist.uploadedSongsBrowseID:
                    payload = [:]
                    statusCode = 200
                default:
                    payload = [:]
                    statusCode = 400
                }
            } else {
                payload = [:]
                statusCode = 400
            }

            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, data)
        }
        defer { MockURLProtocol.reset(session: session) }

        let client = try await Self.makeAuthenticatedClient(session: session)
        let content = try await client.getLibraryContent()

        #expect(content.albums.map(\.id) == [
            "MPREALBUMA",
            "MPREALBUMB",
            "MPREALBUMC",
        ])
        #expect(recorder.cursors == [
            "albums-page-2",
            "albums-page-3",
        ])
        #expect(recorder.browseIDs == [
            "FEmusic_library_landing",
            "FEmusic_liked_playlists",
            "FEmusic_liked_albums",
            "FEmusic_library_corpus_artists",
            Playlist.uploadedSongsBrowseID,
        ])
    }

    private static func makeAuthenticatedClient(session: URLSession) async throws -> YTMusicClient {
        let webKitManager = WebKitManager.makeTestInstance()
        let cookie = try #require(HTTPCookie(properties: [
            .name: WebKitManager.fallbackAuthCookieName,
            .value: "test-cookie",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        await webKitManager.dataStore.httpCookieStore.setCookie(cookie)

        let authService = AuthService(webKitManager: webKitManager)
        authService.completeLogin(sapisid: "test-cookie")
        return YTMusicClient(
            authService: authService,
            webKitManager: webKitManager,
            session: session
        )
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsPagePayload(
        albumID: String,
        title: String,
        nextPage: String?
    ) -> [String: Any] {
        var gridRenderer: [String: Any] = [
            "items": [Self.libraryAlbumItem(id: albumID, title: title)],
        ]
        if let nextPage {
            gridRenderer["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [["gridRenderer": gridRenderer]],
                                ],
                            ],
                        ],
                    ]],
                ],
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumsContinuationPayload(
        albumID: String,
        title: String,
        nextPage: String?
    ) -> [String: Any] {
        var gridContinuation: [String: Any] = [
            "items": [Self.libraryAlbumItem(id: albumID, title: title)],
        ]
        if let nextPage {
            gridContinuation["continuations"] = [[
                "nextContinuationData": ["continuation": nextPage],
            ]]
        }

        return [
            "continuationContents": [
                "gridContinuation": gridContinuation,
            ],
        ]
    }

    // swiftlint:disable:next modifier_order
    private nonisolated static func libraryAlbumItem(id: String, title: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "subtitle": [
                    "runs": [
                        ["text": "Album"],
                        ["text": " • "],
                        ["text": "Test Artist"],
                        ["text": " • "],
                        ["text": "2026"],
                    ],
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": id,
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM",
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }
}

// MARK: - LibraryRequestTestSupport

private enum LibraryRequestTestSupport {
    /// URLSession may bridge `httpBody` to a stream before URLProtocol observes the request.
    static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            throw YTMusicError.parseError(message: "Request body was missing")
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? YTMusicError.parseError(message: "Request body could not be read")
            }
            if count == 0 {
                return data
            }
            data.append(buffer, count: count)
        }
    }
}

// MARK: - LibraryRequestRecorder

private final class LibraryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBrowseIDs: [String] = []
    private var storedCursors: [String] = []

    var browseIDs: [String] {
        self.lock.withLock { self.storedBrowseIDs }
    }

    var cursors: [String] {
        self.lock.withLock { self.storedCursors }
    }

    func appendBrowseID(_ browseID: String) {
        self.lock.withLock {
            self.storedBrowseIDs.append(browseID)
        }
    }

    func appendCursor(_ cursor: String) {
        self.lock.withLock {
            self.storedCursors.append(cursor)
        }
    }
}
