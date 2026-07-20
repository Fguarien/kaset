import SwiftUI

// MARK: - DownloadContextMenu

/// Context-menu item that downloads a song as an mp3 via the homelab jukebox backend.
/// The request is fire-and-forget; progress/result is surfaced by `JukeboxDownloadToast`.
@MainActor
enum DownloadContextMenu {
    @ViewBuilder
    static func menuItem(for song: Song, service: JukeboxDownloadService) -> some View {
        Button {
            Task { await service.download(song) }
        } label: {
            Label(String(localized: "Download"), systemImage: "arrow.down.circle")
        }
        .disabled(!service.canDownload(song))
    }
}

// MARK: - JukeboxDownloadToast

/// Observes `JukeboxDownloadService` and shows a transient toast for each download
/// (start, success, or failure). Mount once as a top overlay, like `AccountErrorToast`.
struct JukeboxDownloadToast: View {
    @Environment(JukeboxDownloadService.self) private var service

    @State private var isVisible = false
    @State private var message = ""
    @State private var isError = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if self.isVisible {
                ToastView(
                    message: self.message,
                    isError: self.isError,
                    onDismiss: { self.dismiss() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: self.isVisible)
        .onChange(of: self.service.status) { _, status in
            self.handle(status)
        }
    }

    private func handle(_ status: JukeboxDownloadService.Status) {
        switch status {
        case .idle:
            return
        case let .downloading(title):
            // Stays until replaced by success/failure (no auto-dismiss).
            self.present(String(localized: "Downloading “\(title)”…"), isError: false, autoDismiss: false)
        case let .success(title, _):
            self.present(String(localized: "Saved “\(title)” to your library"), isError: false, autoDismiss: true)
        case let .failure(title, reason):
            self.present(String(localized: "Couldn’t download “\(title)”: \(reason)"), isError: true, autoDismiss: true)
        }
    }

    private func present(_ text: String, isError: Bool, autoDismiss: Bool) {
        self.dismissTask?.cancel()
        self.message = text
        self.isError = isError
        self.isVisible = true
        if autoDismiss {
            self.dismissTask = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled {
                    await MainActor.run { self.dismiss() }
                }
            }
        }
    }

    private func dismiss() {
        self.isVisible = false
        self.dismissTask?.cancel()
        self.dismissTask = nil
        // Reset so the next .idle transition is a no-op and repeat downloads re-trigger.
        self.service.resetStatus()
    }
}
