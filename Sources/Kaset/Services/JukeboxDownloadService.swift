import Foundation

/// Requests server-side mp3 downloads of a song from the homelab "jukebox" backend.
///
/// Kaset never handles the audio stream itself — YouTube Music audio is Widevine-DRM
/// and only plays inside the hidden `SingletonPlayerWebView`. Instead this service POSTs
/// the song's `videoId` (+ metadata) to jukebox (a yt-dlp/FastAPI service on vm-docker),
/// which fetches, transcodes to a tagged mp3, and stores it in the NAS music library.
/// See `faqs/kaset.md` in the homelab vault for the full rationale.
///
/// Modeled on `LastFMService`: `@MainActor @Observable`, `URLSession` JSON POST.
@MainActor
@Observable
final class JukeboxDownloadService {
    /// Outcome of the most recent download request, for UI feedback (toast).
    enum Status: Equatable {
        case idle
        case downloading(title: String)
        case success(title: String, file: String)
        case failure(title: String, reason: String)
    }

    /// The latest request status. A view can observe this to drive a toast.
    private(set) var status: Status = .idle

    private let session: URLSession
    private let settings: SettingsManager

    /// - Parameters:
    ///   - settings: Source of the configurable backend base URL.
    ///   - session: URLSession (injectable for testing).
    init(settings: SettingsManager = .shared, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    /// Resolved backend base URL from settings (falls back to the homelab default).
    private var baseURL: URL? {
        let raw = self.settings.jukeboxBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: raw.isEmpty ? SettingsManager.defaultJukeboxBaseURL : raw)
    }

    /// Whether a song is downloadable (has a usable videoId).
    func canDownload(_ song: Song) -> Bool {
        !song.videoId.isEmpty
    }

    /// Clears any lingering status (e.g. after a toast is dismissed).
    func resetStatus() {
        self.status = .idle
    }

    /// Downloads `song` as an mp3 via the jukebox backend.
    /// Fire-and-forget from the caller's perspective; observe `status` for the result.
    /// - Returns: `true` on backend `ok`/`skip`, `false` otherwise.
    @discardableResult
    func download(_ song: Song) async -> Bool {
        guard !song.videoId.isEmpty else {
            self.status = .failure(title: song.title, reason: String(localized: "This song has no video ID."))
            return false
        }
        guard let base = self.baseURL else {
            self.status = .failure(title: song.title, reason: String(localized: "Invalid Jukebox URL in Settings."))
            return false
        }

        self.status = .downloading(title: song.title)

        var body: [String: Any] = [
            "videoId": song.videoId,
            "title": song.title,
            "artist": song.artistsDisplay,
        ]
        if let album = song.album?.title, !album.isEmpty {
            body["album"] = album
        }
        if let cover = song.thumbnailURL?.absoluteString, !cover.isEmpty {
            body["cover_url"] = cover
        }

        var request = URLRequest(url: base.appendingPathComponent("download"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Server-side yt-dlp + transcode can take a while for long tracks.
        request.timeoutInterval = 600

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await self.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let backendStatus = json?["status"] as? String

            if statusCode < 300, backendStatus == "ok" || backendStatus == "skip" {
                let file = (json?["file"] as? String) ?? ""
                self.status = .success(title: song.title, file: file)
                return true
            }

            let reason = (json?["reason"] as? String) ?? String(localized: "Backend error (HTTP \(statusCode)).")
            self.status = .failure(title: song.title, reason: reason)
            return false
        } catch {
            self.status = .failure(title: song.title, reason: error.localizedDescription)
            return false
        }
    }
}
