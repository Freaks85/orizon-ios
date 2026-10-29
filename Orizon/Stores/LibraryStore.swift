import Foundation

struct LibraryEntry: Codable, Identifiable, Hashable {
    var manga: MangaSummary
    var addedAt: Date
    var chapters: [Chapter]
    var newChapterIds: [String]
    var lastChecked: Date?

    var id: String { manga.slug }
}

struct ReadingProgress: Codable, Hashable {
    var manga: MangaSummary
    var chapterId: String
    var chapterNumber: String
    var pageIndex: Int
    var pageCount: Int
    var updatedAt: Date
    /// Position inside the page (0 = top, 1 = bottom), for tall webtoon strips.
    var pageOffset: Double?
}

struct NewChapterItem: Identifiable, Hashable {
    var manga: MangaSummary
    var chapter: Chapter
    var id: String { chapter.id }
}

private struct LibraryState: Codable {
    var entries: [String: LibraryEntry] = [:]
    var progress: [String: ReadingProgress] = [:]
    var readChapters: [String: Set<String>] = [:]
}

/// Library, reading progress, read chapters and new-chapter tracking.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private var state: LibraryState {
        didSet { rebuildDerived() }
    }
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var lastUpdateError: String?

    private let fileName = "library.json"
    private var saveTask: Task<Void, Never>?

    // Sorted views of the state, rebuilt once per change rather than on every read from a view body.
    private(set) var entries: [LibraryEntry] = []
    private(set) var continueReading: [ReadingProgress] = []
    private(set) var newChapters: [NewChapterItem] = []
    private(set) var newChapterCount = 0

    init() {
        state = Persistence.load(LibraryState.self, from: "library.json") ?? LibraryState()
        rebuildDerived()
    }

    private func rebuildDerived() {
        entries = state.entries.values.sorted { lhs, rhs in
            if lhs.newChapterIds.isEmpty != rhs.newChapterIds.isEmpty { return !lhs.newChapterIds.isEmpty }
            return lhs.manga.title.localizedCaseInsensitiveCompare(rhs.manga.title) == .orderedAscending
        }
        continueReading = state.progress.values.sorted { $0.updatedAt > $1.updatedAt }
        newChapters = state.entries.values.flatMap { entry in
            let ids = Set(entry.newChapterIds)
            return entry.chapters.filter { ids.contains($0.id) }
                .map { NewChapterItem(manga: entry.manga, chapter: $0) }
        }
        .sorted { ($0.chapter.date ?? .distantPast) > ($1.chapter.date ?? .distantPast) }
        newChapterCount = state.entries.values.reduce(0) { $0 + $1.newChapterIds.count }
    }

    // MARK: - Library

    func contains(_ slug: String) -> Bool { state.entries[slug] != nil }

    func entry(_ slug: String) -> LibraryEntry? { state.entries[slug] }

    func add(_ manga: MangaSummary, chapters: [Chapter]) {
        state.entries[manga.slug] = LibraryEntry(manga: manga, addedAt: Date(), chapters: chapters, newChapterIds: [], lastChecked: Date())
        save()
    }

    func remove(_ slug: String) {
        state.entries[slug] = nil
        save()
    }

    func toggle(_ manga: MangaSummary, chapters: [Chapter]) {
        if contains(manga.slug) { remove(manga.slug) } else { add(manga, chapters: chapters) }
    }

    /// Called whenever fresh chapters are loaded for a manga (details screen or update check).
    @discardableResult
    func merge(chapters: [Chapter], for manga: MangaSummary) -> Int {
        let fresh = Self.merge(chapters: chapters, for: manga, into: &state)
        save()
        return fresh
    }

    /// Applies fresh chapters to a copy of the state, so several mangas can be merged with a single
    /// change (one re-render and one save instead of one per manga).
    @discardableResult
    private static func merge(chapters: [Chapter], for manga: MangaSummary, into state: inout LibraryState) -> Int {
        guard var entry = state.entries[manga.slug] else { return 0 }
        let known = Set(entry.chapters.map(\.id))
        let read = state.readChapters[manga.slug] ?? []
        let fresh = known.isEmpty ? [] : chapters.filter { !known.contains($0.id) && !read.contains($0.id) }.map(\.id)
        entry.chapters = chapters
        entry.manga.title = manga.title
        if manga.cover != nil { entry.manga.cover = manga.cover }
        if manga.status != nil { entry.manga.status = manga.status }
        if manga.kind != nil { entry.manga.kind = manga.kind }
        let current = Set(chapters.map(\.id))
        entry.newChapterIds = Array(Set(entry.newChapterIds + fresh)).filter { current.contains($0) }
        entry.lastChecked = Date()
        state.entries[manga.slug] = entry
        return fresh.count
    }

    // MARK: - New chapters

    func isNew(_ chapterId: String, slug: String) -> Bool {
        state.entries[slug]?.newChapterIds.contains(chapterId) ?? false
    }

    func clearNew(slug: String) {
        state.entries[slug]?.newChapterIds = []
        save()
    }

    func clearAllNew() {
        for slug in state.entries.keys { state.entries[slug]?.newChapterIds = [] }
        save()
    }

    /// Fetches the chapter list of every followed manga. `minimumInterval` skips the mangas checked
    /// more recently than that (used when the app comes back to the foreground: each check
    /// downloads a whole manga page).
    func checkForUpdates(minimumInterval: TimeInterval = 0) async {
        guard !isCheckingUpdates else { return }
        let now = Date()
        let mangas = state.entries.values
            .filter { now.timeIntervalSince($0.lastChecked ?? .distantPast) >= minimumInterval }
            .map(\.manga)
        guard !mangas.isEmpty else { return }
        isCheckingUpdates = true
        lastUpdateError = nil
        defer { isCheckingUpdates = false }

        var results: [(MangaSummary, [Chapter])] = []
        var failures = 0
        await withTaskGroup(of: (MangaSummary, [Chapter]?).self) { group in
            var iterator = mangas.makeIterator()
            // Keep 4 requests in flight at a time.
            for _ in 0..<4 {
                guard let manga = iterator.next() else { break }
                group.addTask { (manga, try? await AniverseAPI.shared.chapters(slug: manga.slug)) }
            }
            while let (manga, chapters) = await group.next() {
                if let chapters { results.append((manga, chapters)) } else { failures += 1 }
                if let next = iterator.next() {
                    group.addTask { (next, try? await AniverseAPI.shared.chapters(slug: next.slug)) }
                }
            }
        }
        if !results.isEmpty {
            var updated = state
            for (manga, chapters) in results {
                Self.merge(chapters: chapters, for: manga, into: &updated)
            }
            state = updated
            save()
        }
        if failures > 0 {
            lastUpdateError = "\(failures) manga(s) n'ont pas pu être vérifiés."
        }
    }

    // MARK: - Read state & progress

    func isRead(_ chapterId: String, slug: String) -> Bool {
        state.readChapters[slug]?.contains(chapterId) ?? false
    }

    func setRead(_ read: Bool, chapterIds: [String], slug: String) {
        var set = state.readChapters[slug] ?? []
        if read {
            set.formUnion(chapterIds)
            state.entries[slug]?.newChapterIds.removeAll { chapterIds.contains($0) }
        } else {
            set.subtract(chapterIds)
        }
        state.readChapters[slug] = set
        save()
    }

    func progress(for slug: String) -> ReadingProgress? { state.progress[slug] }

    func clearHistory() {
        state.progress.removeAll()
        save()
    }

    func removeProgress(_ slug: String) {
        state.progress[slug] = nil
        save()
    }

    func saveProgress(manga: MangaSummary, chapter: Chapter, pageIndex: Int, pageCount: Int, offset: Double = 0) {
        let chapterChanged = state.progress[manga.slug]?.chapterId != chapter.id
        state.progress[manga.slug] = ReadingProgress(
            manga: manga,
            chapterId: chapter.id,
            chapterNumber: chapter.number,
            pageIndex: pageIndex,
            pageCount: pageCount,
            updatedAt: Date(),
            pageOffset: offset
        )
        if pageCount > 0, pageIndex >= pageCount - 1, offset > 0.5, !isRead(chapter.id, slug: manga.slug) {
            setRead(true, chapterIds: [chapter.id], slug: manga.slug)
        } else {
            // Page changes are frequent: debounce them. A new chapter is saved right away.
            save(debounced: !chapterChanged)
        }
    }

    /// Mangas being read are kept in the library automatically.
    func addIfNeeded(_ manga: MangaSummary, chapters: [Chapter]) {
        guard state.entries[manga.slug] == nil else { return }
        add(manga, chapters: chapters)
    }

    /// Writes the current state synchronously (used when the app goes to background).
    func flush() {
        saveTask?.cancel()
        Persistence.save(state, to: fileName)
    }

    // MARK: - Persistence

    private func save(debounced: Bool = false) {
        saveTask?.cancel()
        let snapshot = state
        let name = fileName
        saveTask = Task.detached(priority: .utility) {
            if debounced {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
            }
            Persistence.save(snapshot, to: name)
        }
    }
}
