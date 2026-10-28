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
}

/// Anime library ("Ma liste"), watch history, resume positions and watched episodes.
@MainActor
final class AnimeStore: ObservableObject {
    static let shared = AnimeStore()
    nonisolated static let watchedThreshold = 0.9

    @Published private var state: AnimeState
    private nonisolated static let fileName = "anime-library.json"
    private var saveTask: Task<Void, Never>?

    init() {
        state = Persistence.load(AnimeState.self, from: Self.fileName) ?? AnimeState()
    }

    // MARK: - Ma liste

    var list: [Anime] {
        state.list.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func isInList(_ anime: Anime) -> Bool { state.list[anime.seriesKey] != nil }

    func toggleList(_ anime: Anime) {
        if isInList(anime) { state.list[anime.seriesKey] = nil } else { state.list[anime.seriesKey] = anime }
        scheduleSave()
    }

    // MARK: - History

    var history: [WatchProgress] { state.history.values.sorted { $0.updatedAt > $1.updatedAt } }

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
        guard let position = state.positions[Self.key(animeId, language, episode)] else { return nil }
        if let progress = state.history.values.first(where: { $0.season.id == animeId && $0.episode == episode && $0.language == language }),
           progress.duration > 0 {
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
