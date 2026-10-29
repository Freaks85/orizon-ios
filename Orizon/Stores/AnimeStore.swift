import Foundation

/// Where the user stopped in a series (one entry per series, the last episode watched).
struct WatchProgress: Codable, Hashable, Identifiable {
    /// The anime opened from the lists (title and art of the series).
    var series: Anime
    /// The season the episode belongs to.
    var season: Anime
    var episode: Int
    var language: AnimeLanguage
    var position: Double
    var duration: Double
    var updatedAt: Date

    var id: String { series.seriesKey }
    var fraction: Double { duration > 0 ? min(position / duration, 1) : 0 }
    var isFinished: Bool { fraction >= AnimeStore.watchedThreshold }
}

private struct AnimeState: Codable {
    var list: [String: Anime] = [:]
    var history: [String: WatchProgress] = [:]
    /// Unfinished positions, by "animeId-language-episode".
    var positions: [String: Double] = [:]
    /// Watched episodes, by "animeId-episode".
    var watched: Set<String> = []
    /// Opening/ending timings corrected by hand in the player, by "animeId-language-episode".
    /// Optional so that a file saved before this field existed still decodes.
    var skipOverrides: [String: [SkipSegment]]?
}

/// Anime library ("Ma liste"), watch history, resume positions and watched episodes.
@MainActor
final class AnimeStore: ObservableObject {
    static let shared = AnimeStore()
    nonisolated static let watchedThreshold = 0.9

    @Published private var state: AnimeState {
        didSet { rebuildDerived() }
    }
    private nonisolated static let fileName = "anime-library.json"
    private var saveTask: Task<Void, Never>?

    // Sorted views of the state, rebuilt once per change rather than on every read from a view body.
    private(set) var list: [Anime] = []
    private(set) var history: [WatchProgress] = []
    /// History entries by "seasonId-language-episode", for the progress bar of each episode row.
    private var historyByEpisode: [String: WatchProgress] = [:]

    init() {
        state = Persistence.load(AnimeState.self, from: Self.fileName) ?? AnimeState()
        rebuildDerived()
    }

    private func rebuildDerived() {
        list = state.list.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        history = state.history.values.sorted { $0.updatedAt > $1.updatedAt }
        historyByEpisode = Dictionary(state.history.values.map { (Self.key($0.season.id, $0.language, $0.episode), $0) },
                                      uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Ma liste

    func isInList(_ anime: Anime) -> Bool { state.list[anime.seriesKey] != nil }

    func toggleList(_ anime: Anime) {
        if isInList(anime) { state.list[anime.seriesKey] = nil } else { state.list[anime.seriesKey] = anime }
        scheduleSave()
    }

    // MARK: - History

    func progress(series: Anime) -> WatchProgress? { state.history[series.seriesKey] }

    func removeHistory(_ id: String) {
        state.history[id] = nil
        scheduleSave()
    }

    func clearHistory() {
        state.history.removeAll()
        scheduleSave()
    }

    // MARK: - Episodes

    func isWatched(animeId: String, episode: Int) -> Bool { state.watched.contains("\(animeId)-\(episode)") }

    func setWatched(_ watched: Bool, animeId: String, episodes: [Int]) {
        for episode in episodes {
            if watched { state.watched.insert("\(animeId)-\(episode)") } else { state.watched.remove("\(animeId)-\(episode)") }
        }
        scheduleSave()
    }

    /// Fraction watched of an unfinished episode, for the thin bar under the episode.
    func partial(animeId: String, language: AnimeLanguage, episode: Int, duration: Double?) -> Double? {
        let key = Self.key(animeId, language, episode)
        guard let position = state.positions[key] else { return nil }
        if let progress = historyByEpisode[key], progress.duration > 0 {
            return progress.position / progress.duration
        }
        return duration.map { position / $0 }
    }

    func resumePosition(animeId: String, language: AnimeLanguage, episode: Int) -> Double? {
        state.positions[Self.key(animeId, language, episode)]
    }

    func save(series: Anime, season: Anime, episode: Int, language: AnimeLanguage, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        let key = Self.key(season.id, language, episode)
        if position / duration >= Self.watchedThreshold {
            state.watched.insert("\(season.id)-\(episode)")
            state.positions[key] = nil
        } else {
            state.positions[key] = position
        }
        state.history[series.seriesKey] = WatchProgress(series: series, season: season, episode: episode, language: language,
                                                        position: position, duration: duration, updatedAt: Date())
        scheduleSave()
    }

    // MARK: - Timings corrected by hand

    func skipOverride(animeId: String, language: AnimeLanguage, episode: Int) -> [SkipSegment]? {
        state.skipOverrides?[Self.key(animeId, language, episode)]
    }

    func setSkipOverride(_ segments: [SkipSegment]?, animeId: String, language: AnimeLanguage, episode: Int) {
        var overrides = state.skipOverrides ?? [:]
        overrides[Self.key(animeId, language, episode)] = segments
        state.skipOverrides = overrides
        scheduleSave()
    }

    private static func key(_ animeId: String, _ language: AnimeLanguage, _ episode: Int) -> String {
        "\(animeId)-\(language.rawValue)-\(episode)"
    }

    // MARK: - Persistence

    func flush() {
        saveTask?.cancel()
        Persistence.save(state, to: Self.fileName)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = state
        let name = Self.fileName
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            Persistence.save(snapshot, to: name)
        }
    }
}
