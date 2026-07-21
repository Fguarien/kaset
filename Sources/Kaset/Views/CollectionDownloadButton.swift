import SwiftUI

/// Header button that downloads a whole collection (playlist, album, queue) as mp3s
/// via the homelab jukebox backend, and reports what is already in the library.
///
/// The label is the state: `Download` when nothing is there, `Download Missing (n)`
/// when the library holds part of it, `Downloaded` when it is complete, and live
/// progress while the backend job runs. The download itself happens server-side —
/// quitting kaset does not interrupt it.
struct CollectionDownloadButton: View {
    /// Collection name — also the backend folder name (`ExtraMusic/kaset/<slug>/`).
    let name: String
    let songs: [Song]
    /// Matches the sibling header buttons, which hide their titles when space is tight.
    var showsTitle: Bool = true

    @Environment(JukeboxDownloadService.self) private var service

    @State private var state: JukeboxDownloadService.CollectionState?
    @State private var isStarting = false

    /// The backend job downloading *this* collection, if any.
    private var runningJob: JukeboxDownloadService.JobProgress? {
        guard let job = service.activeJob, job.isRunning,
              service.activeCollectionName == self.name || job.name == self.name
        else { return nil }
        return job
    }

    private var downloadableSongs: [Song] {
        self.songs.filter { !$0.videoId.isEmpty }
    }

    var body: some View {
        Button {
            self.start()
        } label: {
            self.label
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(self.downloadableSongs.isEmpty || self.runningJob != nil || self.isStarting
            || self.state?.isFullyDownloaded == true)
        .help(self.helpText)
        .task(id: self.songs.count) { await self.refresh() }
        // A finished job changes what is on disk — re-read the state.
        .onChange(of: self.service.activeJob?.state) { _, _ in
            Task { await self.refresh() }
        }
    }

    @ViewBuilder
    private var label: some View {
        if let job = self.runningJob {
            let title = "\(job.done)/\(job.total)"
            if self.showsTitle {
                Label(title, systemImage: "arrow.down.circle.dotted")
            } else {
                Image(systemName: "arrow.down.circle.dotted").accessibilityLabel(title)
            }
        } else if let state, state.isFullyDownloaded {
            self.staticLabel(String(localized: "Downloaded"), systemImage: "checkmark.circle.fill")
        } else if let state, state.isPartiallyDownloaded {
            self.staticLabel(
                String(localized: "Download Missing (\(state.missing))"),
                systemImage: "arrow.down.circle.badge.questionmark"
            )
        } else {
            self.staticLabel(String(localized: "Download"), systemImage: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private func staticLabel(_ title: String, systemImage: String) -> some View {
        if self.showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage).accessibilityLabel(title)
        }
    }

    private var helpText: String {
        if let job = self.runningJob {
            return job.current.isEmpty
                ? String(localized: "Downloading \(job.done) of \(job.total)")
                : String(localized: "Downloading \(job.current)")
        }
        if let state, state.isFullyDownloaded {
            return String(localized: "All \(state.total) tracks are in the library")
        }
        if let state, state.isPartiallyDownloaded {
            return String(localized: "\(state.missing) of \(state.total) tracks are missing from the library")
        }
        return String(localized: "Download every track to the music library")
    }

    private func refresh() async {
        let songs = self.downloadableSongs
        guard !songs.isEmpty else { return }
        let fresh = await self.service.collectionState(name: self.name, songs: songs)
        self.state = fresh
        // Re-attach to a job started earlier (another window, or before a relaunch).
        if let jobID = fresh?.runningJobID, self.service.activeJob?.jobID != jobID {
            self.service.follow(jobID: jobID, name: self.name)
        }
    }

    private func start() {
        self.isStarting = true
        Task {
            await self.service.startCollectionDownload(name: self.name, songs: self.downloadableSongs)
            self.isStarting = false
            await self.refresh()
        }
    }
}
