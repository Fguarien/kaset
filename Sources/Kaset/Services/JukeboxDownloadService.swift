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

    /// JSON payload describing one track for the backend.
    private func trackBody(_ song: Song) -> [String: Any] {
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
        return body
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

        let body = self.trackBody(song)

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

    // MARK: - Collections (playlists, albums, queue)

    /// How much of a collection already exists in the library, per the backend.
    struct CollectionState: Equatable {
        var total: Int
        var present: Int
        var missing: Int
        /// Job currently downloading this exact collection, if any.
        var runningJobID: String?

        var isFullyDownloaded: Bool { self.total > 0 && self.missing == 0 }
        var isPartiallyDownloaded: Bool { self.present > 0 && self.missing > 0 }
    }

    /// Progress of a backend download job.
    struct JobProgress: Equatable, Identifiable {
        var id: String { self.jobID }
        var jobID: String
        var name: String
        /// `running`, `done`, `cancelled`.
        var state: String
        var total: Int
        var done: Int
        var ok: Int
        var skip: Int
        var fail: Int
        /// Track being downloaded right now (empty once finished).
        var current: String
        var fails: [String]

        var isRunning: Bool { self.state == "running" }
        var fraction: Double { self.total > 0 ? Double(self.done) / Double(self.total) : 0 }
    }

    /// The job this app is currently following, refreshed by `pollActiveJob()`.
    private(set) var activeJob: JobProgress?
    /// Name of the collection whose download this app started (for UI attribution).
    private(set) var activeCollectionName: String?

    private var pollTask: Task<Void, Never>?

    /// Asks the backend how many tracks of `songs` are already downloaded.
    /// Read-only — downloads nothing. Returns `nil` if the backend is unreachable.
    func collectionState(name: String, songs: [Song]) async -> CollectionState? {
        guard let base = self.baseURL else { return nil }
        let tracks = songs.filter { !$0.videoId.isEmpty }.map { self.trackBody($0) }
        guard !tracks.isEmpty else { return nil }

        var request = URLRequest(url: base.appendingPathComponent("download/playlist/state"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "tracks": tracks])
            let (data, _) = try await self.session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let job = json["job"] as? [String: Any]
            return CollectionState(
                total: json["total"] as? Int ?? tracks.count,
                present: json["present"] as? Int ?? 0,
                missing: json["missing"] as? Int ?? 0,
                runningJobID: job?["job_id"] as? String
            )
        } catch {
            return nil
        }
    }

    /// Starts a background job downloading every track of `songs` into its own
    /// library folder. Already-present tracks are skipped by the backend, so
    /// re-running a partially downloaded collection only fetches what is missing.
    /// - Returns: the job id, or `nil` on failure (reason surfaced via `status`).
    @discardableResult
    func startCollectionDownload(name: String, songs: [Song]) async -> String? {
        let tracks = songs.filter { !$0.videoId.isEmpty }.map { self.trackBody($0) }
        guard !tracks.isEmpty else {
            self.status = .failure(title: name, reason: String(localized: "Nothing to download."))
            return nil
        }
        guard let base = self.baseURL else {
            self.status = .failure(title: name, reason: String(localized: "Invalid Jukebox URL in Settings."))
            return nil
        }

        self.status = .downloading(title: name)

        var request = URLRequest(url: base.appendingPathComponent("download/playlist"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "tracks": tracks])
            let (data, response) = try await self.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

            // 409: another collection is already downloading — follow that job instead
            // of failing, so the UI still shows what the backend is busy with.
            if statusCode == 409, let running = json?["job_id"] as? String {
                self.status = .failure(title: name, reason: String(localized: "Another download is already running."))
                self.follow(jobID: running, name: name)
                return nil
            }
            guard statusCode < 300, let jobID = json?["job_id"] as? String else {
                let reason = (json?["reason"] as? String) ?? String(localized: "Backend error (HTTP \(statusCode)).")
                self.status = .failure(title: name, reason: reason)
                return nil
            }
            self.follow(jobID: jobID, name: name)
            return jobID
        } catch {
            self.status = .failure(title: name, reason: error.localizedDescription)
            return nil
        }
    }

    /// Polls a job until it finishes, publishing progress on `activeJob`.
    /// The download itself lives on the backend — quitting kaset does not stop it,
    /// and calling this again later re-attaches to a job still in flight.
    func follow(jobID: String, name: String) {
        self.pollTask?.cancel()
        self.activeCollectionName = name
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let progress = await self.fetchJob(jobID) else { return }
                self.activeJob = progress
                if !progress.isRunning {
                    self.status = .success(
                        title: name,
                        file: String(localized: "\(progress.ok) downloaded, \(progress.skip) already there, \(progress.fail) failed")
                    )
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// One-shot job read.
    func fetchJob(_ jobID: String) async -> JobProgress? {
        guard let base = self.baseURL else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("download/job/\(jobID)"))
        request.timeoutInterval = 30
        do {
            let (data, _) = try await self.session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["job_id"] as? String
            else { return nil }
            let fails = (json["fails"] as? [[String: Any]] ?? []).map { fail in
                let item = fail["item"] as? String ?? "?"
                let reason = fail["reason"] as? String ?? ""
                return reason.isEmpty ? item : "\(item) — \(reason)"
            }
            return JobProgress(
                jobID: id,
                name: json["name"] as? String ?? "",
                state: json["status"] as? String ?? "running",
                total: json["total"] as? Int ?? 0,
                done: json["done"] as? Int ?? 0,
                ok: json["ok"] as? Int ?? 0,
                skip: json["skip"] as? Int ?? 0,
                fail: json["fail"] as? Int ?? 0,
                current: json["current"] as? String ?? "",
                fails: fails
            )
        } catch {
            return nil
        }
    }

    /// All jobs the backend still remembers (newest first) — powers the Downloads panel.
    func fetchJobs() async -> [JobProgress] {
        guard let base = self.baseURL else { return [] }
        var request = URLRequest(url: base.appendingPathComponent("download/jobs"))
        request.timeoutInterval = 30
        guard let (data, _) = try? await self.session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["jobs"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { job in
            guard let id = job["job_id"] as? String else { return nil }
            return JobProgress(
                jobID: id,
                name: job["name"] as? String ?? "",
                state: job["status"] as? String ?? "",
                total: job["total"] as? Int ?? 0,
                done: job["done"] as? Int ?? 0,
                ok: job["ok"] as? Int ?? 0,
                skip: job["skip"] as? Int ?? 0,
                fail: job["fail"] as? Int ?? 0,
                current: job["current"] as? String ?? "",
                fails: (job["fails"] as? [[String: Any]] ?? []).map { fail in
                    let item = fail["item"] as? String ?? "?"
                    let reason = fail["reason"] as? String ?? ""
                    return reason.isEmpty ? item : "\(item) — \(reason)"
                }
            )
        }
    }

    /// Asks the backend to stop after the track currently being fetched.
    func cancelJob(_ jobID: String) async {
        guard let base = self.baseURL else { return }
        var request = URLRequest(url: base.appendingPathComponent("download/job/\(jobID)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        _ = try? await self.session.data(for: request)
    }
}
