import Foundation

struct DownloadedChapter: Codable, Hashable, Identifiable {
    var manga: MangaSummary
    var chapter: Chapter
    var pageFiles: [String]
    var pages: [Page]
    var downloadedAt: Date
    var byteCount: Int64

    var id: String { chapter.id }
}

struct DownloadJob: Identifiable, Hashable {
    enum State: Hashable {
        case queued
        case running(done: Int, total: Int)
        case failed(String)
    }

    var manga: MangaSummary
    var chapter: Chapter
    var state: State

    var id: String { chapter.id }

    var progress: Double {
        if case .running(let done, let total) = state, total > 0 { return Double(done) / Double(total) }
        return 0
    }
}

/// Chapter downloads: a queue processed a few chapters at a time, each chapter fetching
/// its pages in parallel, saved under Documents/Downloads/<slug>/<chapterId>/.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var downloaded: [String: DownloadedChapter] = [:]

    private let maxConcurrentChapters = 2
    private let maxConcurrentPages = 6
    private var running: [String: Task<Void, Never>] = [:]
    private let indexName = "downloads.json"

    let root: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 12
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["Referer": "https://aniverse.fr/"]
        return URLSession(configuration: config)
    }()

    init() {
        downloaded = Persistence.load([String: DownloadedChapter].self, from: indexName) ?? [:]
    }

    // MARK: - Queries

    func isDownloaded(_ chapterId: String) -> Bool { downloaded[chapterId] != nil }

    func job(for chapterId: String) -> DownloadJob? { jobs.first { $0.id == chapterId } }

    /// Local page files for a downloaded chapter, in reading order.
    func localPages(for chapterId: String) -> [Page]? {
        guard let item = downloaded[chapterId] else { return nil }
        let folder = chapterFolder(slug: item.manga.slug, chapterId: chapterId)
        return zip(item.pageFiles, item.pages).map { file, page in
            Page(url: folder.appendingPathComponent(file), width: page.width, height: page.height)
        }
    }

    struct Group: Identifiable {
        var manga: MangaSummary
        var chapters: [DownloadedChapter]
        var id: String { manga.slug }
    }

    var downloadedByManga: [Group] {
        Dictionary(grouping: downloaded.values, by: { $0.manga.slug })
            .compactMap { _, items in
                guard let manga = items.first?.manga else { return nil }
                return Group(manga: manga, chapters: items.sorted { $0.chapter.numberValue > $1.chapter.numberValue })
            }
            .sorted { $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title) == .orderedAscending }
    }

    var totalBytes: Int64 { downloaded.values.reduce(0) { $0 + $1.byteCount } }

    // MARK: - Actions

    func enqueue(_ chapters: [Chapter], manga: MangaSummary) {
        // Oldest first, so a "download all" reads in order as it fills in.
        for chapter in chapters.sorted(by: { $0.numberValue < $1.numberValue }) {
            guard !isDownloaded(chapter.id), !chapter.isPremium else { continue }
            if let index = jobs.firstIndex(where: { $0.id == chapter.id }) {
                if case .failed = jobs[index].state { jobs[index].state = .queued }
                continue
            }
            jobs.append(DownloadJob(manga: manga, chapter: chapter, state: .queued))
        }
        pump()
    }

    func cancel(_ chapterId: String) {
        running[chapterId]?.cancel()
        running[chapterId] = nil
        jobs.removeAll { $0.id == chapterId }
        pump()
    }

    func cancelAll() {
        for task in running.values { task.cancel() }
        running.removeAll()
        jobs.removeAll()
    }

    func retryFailed() {
        for index in jobs.indices {
            if case .failed = jobs[index].state { jobs[index].state = .queued }
        }
        pump()
    }

    func delete(_ chapterId: String) {
        guard let item = downloaded[chapterId] else { return }
        try? FileManager.default.removeItem(at: chapterFolder(slug: item.manga.slug, chapterId: chapterId))
        downloaded[chapterId] = nil
        saveIndex()
    }

    func deleteAll(slug: String) {
        for item in downloaded.values where item.manga.slug == slug {
            downloaded[item.id] = nil
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(slug, isDirectory: true))
        saveIndex()
    }

    // MARK: - Queue

    private func pump() {
        while running.count < maxConcurrentChapters,
              let next = jobs.first(where: { $0.state == .queued && running[$0.id] == nil }) {
            let id = next.id
            update(id, .running(done: 0, total: 0))
            running[id] = Task { [weak self] in
                await self?.download(next)
            }
        }
    }

    private func update(_ id: String, _ state: DownloadJob.State) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].state = state
        }
    }

    private func download(_ job: DownloadJob) async {
        let id = job.id
        defer {
            running[id] = nil
            pump()
        }
        do {
            let pages = try await AniverseAPI.shared.pages(slug: job.manga.slug, chapterId: id)
            let folder = chapterFolder(slug: job.manga.slug, chapterId: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            update(id, .running(done: 0, total: pages.count))

            var files = Array(repeating: "", count: pages.count)
            var bytes: Int64 = 0
            var done = 0
            let session = self.session

            try await withThrowingTaskGroup(of: (Int, String, Int64).self) { group in
                var nextIndex = 0
                while nextIndex < min(maxConcurrentPages, pages.count) {
                    group.addTask(operation: Self.pageTask(index: nextIndex, page: pages[nextIndex], folder: folder, session: session))
                    nextIndex += 1
                }
                while let (index, name, size) = try await group.next() {
                    try Task.checkCancellation()
                    files[index] = name
                    bytes += size
                    done += 1
                    update(id, .running(done: done, total: pages.count))
                    if nextIndex < pages.count {
                        group.addTask(operation: Self.pageTask(index: nextIndex, page: pages[nextIndex], folder: folder, session: session))
                        nextIndex += 1
                    }
                }
            }

            downloaded[id] = DownloadedChapter(
                manga: job.manga,
                chapter: job.chapter,
                pageFiles: files,
                pages: pages,
                downloadedAt: Date(),
                byteCount: bytes
            )
            jobs.removeAll { $0.id == id }
            saveIndex()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: chapterFolder(slug: job.manga.slug, chapterId: id))
        } catch {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: chapterFolder(slug: job.manga.slug, chapterId: id))
            } else {
                update(id, .failed(error.localizedDescription))
            }
        }
    }

    private nonisolated static func pageTask(index: Int, page: Page, folder: URL, session: URLSession) -> @Sendable () async throws -> (Int, String, Int64) {
        return {
            let ext = page.url.pathExtension.isEmpty ? "jpg" : page.url.pathExtension
            let name = String(format: "%03d.%@", index + 1, ext)
            let data = try await fetch(page.url, session: session)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return (index, name, Int64(data.count))
        }
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var lastError: Error = APIError.parsing("l'image")
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw APIError.http(http.statusCode, url)
                }
                return data
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
            }
        }
        throw lastError
    }

    private func chapterFolder(slug: String, chapterId: String) -> URL {
        root.appendingPathComponent(slug, isDirectory: true).appendingPathComponent(chapterId, isDirectory: true)
    }

    private func saveIndex() {
        let snapshot = downloaded
        let name = indexName
        Task.detached(priority: .utility) { Persistence.save(snapshot, to: name) }
    }
}
