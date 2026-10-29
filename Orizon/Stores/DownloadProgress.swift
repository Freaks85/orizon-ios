import SwiftUI

/// Progress of the running downloads, kept apart from the download queues: a queue change re-renders
/// every view that shows downloads (tab bar badge, detail screens), a progress tick should only redraw
/// the rows that display it. Changes are published at most 4 times a second.
@MainActor
final class DownloadProgress: ObservableObject {
    struct Value: Hashable {
        var done: Int
        var total: Int

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    @Published private(set) var values: [String: Value] = [:]
    private var latest: [String: Value] = [:]
    private var flushTask: Task<Void, Never>?

    func set(_ id: String, done: Int, total: Int) {
        latest[id] = Value(done: done, total: total)
        scheduleFlush()
    }

    func remove(_ id: String) {
        guard latest.removeValue(forKey: id) != nil else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.flushTask = nil
            self.values = self.latest
        }
    }
}

/// Shows the progress of one download, observing only `DownloadProgress`.
struct DownloadProgressReader<Content: View>: View {
    @ObservedObject var progress: DownloadProgress
    let id: String
    @ViewBuilder var content: (DownloadProgress.Value?) -> Content

    var body: some View { content(progress.values[id]) }
}
