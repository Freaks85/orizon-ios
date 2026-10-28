import Foundation

enum APIError: LocalizedError {
    case http(Int, URL)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let url):
            if code == 403 || code == 503 {
                return "Aniverse a refusé la requête (\(code)). Réessaie dans un instant."
            }
            return "Erreur HTTP \(code) sur \(url.path)"
        case .parsing(let what):
            return "Impossible de lire \(what)."
        }
    }
}

/// Client for aniverse.fr: a JSON API for lists, and the Next.js flight payload of
/// `/manga/{slug}` and `/read/{slug}/{chapterId}` for details, chapters and pages.
final class AniverseAPI {
    static let shared = AniverseAPI()

    let baseURL = URL(string: "https://aniverse.fr")!
    let session: URLSession

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "Accept-Language": "fr-FR,fr;q=0.9",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - Networking

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        var request = URLRequest(url: url)
        request.setValue(baseURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, url)
        }
        return data
    }

    private func getJSON(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        let data = try await get(path, query: query)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parsing("la réponse du serveur")
        }
        return json
    }

    private func getFlight(_ path: String) async throws -> Flight {
        let data = try await get(path)
        return Flight(html: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Lists

    /// Recently updated mangas (28 per page).
    func latest(page: Int, genre: String? = nil) async throws -> PagedResult<MangaSummary> {
        var query = [URLQueryItem(name: "page", value: String(page))]
        if let genre { query.append(URLQueryItem(name: "genre", value: genre)) }
        let json = try await getJSON("api/manga", query: query)
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap(summary)
        return PagedResult(items: items, hasNextPage: json["hasNextPage"] as? Bool ?? false)
    }

    /// Catalogue search; also used for "popular" and "newest" home rows.
    func search(query: String = "", sort: SortOrder = .popularity, genres: [String] = [], statuses: [String] = [], page: Int) async throws -> PagedResult<MangaSummary> {
        let (items, hasNextPage) = try await searchItems(media: "manga", query: query, sort: sort, genres: genres, statuses: statuses, page: page)
        return PagedResult(items: items.compactMap(summary), hasNextPage: hasNextPage)
    }

    private func searchItems(media: String, query: String, sort: SortOrder, genres: [String] = [], statuses: [String] = [], page: Int) async throws -> ([[String: Any]], Bool) {
        var items = [
            URLQueryItem(name: "media", value: media),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: "40")
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        for genre in genres { items.append(URLQueryItem(name: "genres", value: genre)) }
        for status in statuses { items.append(URLQueryItem(name: "status", value: status)) }

        let json = try await getJSON("api/anime/search", query: items)
        let total = json["total"] as? Int ?? 0
        let pageSize = json["pageSize"] as? Int ?? 40
        return (json["data"] as? [[String: Any]] ?? [], page * pageSize < total)
    }

    private func summary(_ item: [String: Any]) -> MangaSummary? {
        guard let slug = item["slug"] as? String else { return nil }
        let title = item["title"] as? String ?? item["titleEnglish"] as? String ?? slug
        let latestChapters = (item["latestChapters"] as? [[String: Any]] ?? []).compactMap { chapter -> Chapter? in
            guard let id = chapter["id"] as? String, let number = chapter["number"] as? String else { return nil }
            return Chapter(
                id: id,
                number: number,
                title: nil,
                date: (chapter["updatedAt"] as? String).flatMap(isoFormatter.date(from:)),
                premiumUntil: (chapter["premiumUntil"] as? String).flatMap(isoFormatter.date(from:))
            )
        }
        let subtitle = latestChapters.first.map { "Chapitre \($0.number)" }
        let synopsis = (item["description"] as? String).map(Self.plainText)
        return MangaSummary(
            slug: slug,
            title: title,
            cover: (item["image"] as? String).flatMap(URL.init(string:)),
            subtitle: subtitle,
            banner: (item["coverImage"] as? String).flatMap(URL.init(string:)),
            synopsis: synopsis?.isEmpty == true ? nil : synopsis,
            status: (item["status"] as? String).map { MangaStatus.label($0) },
            kind: MangaKind.label(type: item["type"] as? String, country: item["countryOfOrigin"] as? String),
            country: item["countryOfOrigin"] as? String,
            latestChapters: latestChapters
        )
    }

    // MARK: - Details & chapters

    /// Details and the full chapter list come from the same page, so fetch them together.
    func manga(slug: String) async throws -> (MangaDetails, [Chapter]) {
        let flight = try await getFlight("manga/\(slug)")
        return (try details(slug: slug, flight: flight), try chapters(flight: flight))
    }

    func chapters(slug: String) async throws -> [Chapter] {
        try chapters(flight: try await getFlight("manga/\(slug)"))
    }

    private func details(slug: String, flight: Flight) throws -> MangaDetails {
        let value = flight.first(key: "manga") { ($0 as? [String: Any])?["slug"] as? String == slug }
            ?? flight.first(key: "manga") { ($0 as? [String: Any])?["title"] != nil }
        guard let manga = value as? [String: Any] else {
            throw APIError.parsing("la fiche du manga")
        }

        var titles: [String] = []
        if let t = manga["title"] as? [String: Any] {
            for key in ["userPreferred", "english", "romaji", "native"] {
                if let v = t[key] as? String, !v.isEmpty, !titles.contains(v) { titles.append(v) }
            }
        } else if let t = manga["title"] as? String {
            titles.append(t)
        }
        if titles.isEmpty { titles.append(slug) }

        let coverString = (manga["coverImage"] as? [String: Any])?["large"] as? String ?? manga["image"] as? String

        return MangaDetails(
            slug: slug,
            title: titles[0],
            altTitles: Array(titles.dropFirst()),
            cover: coverString.flatMap(URL.init(string:)),
            banner: (manga["bannerImage"] as? String).flatMap(URL.init(string:)),
            description: Self.plainText(manga["description"] as? String ?? ""),
            status: MangaStatus.label(manga["status"] as? String),
            authors: manga["authors"] as? [String] ?? [],
            artists: manga["artists"] as? [String] ?? [],
            genres: manga["genres"] as? [String] ?? [],
            isAdult: manga["isAdult"] as? Bool ?? false,
            kind: MangaKind.label(type: manga["format"] as? String, country: manga["countryOfOrigin"] as? String)
        )
    }

    private func chapters(flight: Flight) throws -> [Chapter] {
        // The page props hold "chapters":"$@<row>". Other "chapters" keys exist (counts,
        // recommendations), so only accept a reference or an array of chapter objects.
        var list = flight.reference(forKey: "chapters") as? [[String: Any]]
        if list == nil {
            list = flight.first(key: "chapters") { value in
                guard let array = value as? [[String: Any]], let first = array.first else { return false }
                return first["id"] != nil && first["number"] != nil
            } as? [[String: Any]]
        }
        guard let list, !list.isEmpty else {
            throw APIError.parsing("la liste des chapitres")
        }

        var seen = Set<String>()
        var chapters: [Chapter] = []
        for item in list {
            guard let id = item["id"] as? String, !seen.contains(id) else { continue }
            seen.insert(id)
            let number = (item["number"] as? String) ?? (item["number"] as? Double).map { String(format: "%g", $0) } ?? "?"
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(Chapter(
                id: id,
                number: number,
                title: title?.isEmpty == true ? nil : title,
                date: (item["updatedAt"] as? String).flatMap(isoFormatter.date(from:)),
                premiumUntil: (item["premiumUntil"] as? String).flatMap(isoFormatter.date(from:)),
                thumbnail: (item["previewImage"] as? String).flatMap(URL.init(string:))
            ))
        }
        return chapters.sorted { $0.numberValue > $1.numberValue }
    }

    // MARK: - Pages

    func pages(slug: String, chapterId: String) async throws -> [Page] {
        let flight = try await getFlight("read/\(slug)/\(chapterId)")
        var list = flight.first(key: "pages") { value in
            ((value as? [[String: Any]])?.first?["src"]) != nil
        } as? [[String: Any]]
        if list == nil { list = flight.reference(forKey: "pages") as? [[String: Any]] }

        let pages = (list ?? []).compactMap { item -> Page? in
            guard let src = item["src"] as? String, let url = URL(string: src) else { return nil }
            return Page(url: url, width: item["width"] as? Double, height: item["height"] as? Double)
        }
        guard !pages.isEmpty else {
            throw APIError.parsing("les pages du chapitre (chapitre premium ?)")
        }
        return pages
    }

    // MARK: - Utils

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Anime

extension AniverseAPI {
    func animeSearch(query: String = "", sort: SortOrder = .popularity, page: Int) async throws -> PagedResult<Anime> {
        let (items, hasNextPage) = try await searchItems(media: "anime", query: query, sort: sort, page: page)
        return PagedResult(items: items.compactMap(anime), hasNextPage: hasNextPage)
    }

    private func anime(_ item: [String: Any]) -> Anime? {
        guard let id = item["id"] as? String, let slug = item["slug"] as? String else { return nil }
        let synopsis = (item["description"] as? String).map(Self.plainText)
        return Anime(
            id: id,
            slug: slug,
            title: item["title"] as? String ?? item["titleEnglish"] as? String ?? slug,
            cover: (item["image"] as? String).flatMap(URL.init(string:)),
            banner: (item["coverImage"] as? String).flatMap(URL.init(string:)),
            synopsis: synopsis?.isEmpty == true ? nil : synopsis,
            status: (item["status"] as? String).map { MangaStatus.label($0) },
            format: item["type"] as? String,
            subCount: item["episodeSub"] as? Int ?? 0,
            dubCount: item["episodeDub"] as? Int ?? 0
        )
    }

    func episodes(animeId: String) async throws -> [Episode] {
        let data = try await get("api/anime/episode/episodes", query: [
            URLQueryItem(name: "animeId", value: animeId),
            URLQueryItem(name: "limit", value: "-1")
        ])
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.parsing("la liste des épisodes")
        }
        var byNumber: [Int: Episode] = [:]
        for item in list {
            guard let number = item["episodeNumber"] as? Int, byNumber[number] == nil else { continue }
            byNumber[number] = Episode(number: number, title: item["titleFr"] as? String ?? item["episodeTitle"] as? String)
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    /// Number of episodes available in each version (fresher than the search counts).
    func episodeCounts(animeId: String) async throws -> (sub: Int, dub: Int) {
        let json = try await getJSON("api/anime/\(animeId)/episode-numbers")
        return (json["sub"] as? Int ?? 0, json["dub"] as? Int ?? 0)
    }

    /// The HLS source is AES-128 encrypted with a key served next to it: AVPlayer handles it natively.
    func stream(animeId: String, episode: Int, language: AnimeLanguage) async throws -> AnimeStream {
        let json = try await getJSON("api/anime/stream/\(animeId)/\(episode)/\(language.rawValue)")
        guard let source = (json["source"] as? String).flatMap(URL.init(string:)) else {
            throw APIError.parsing("la vidéo de l'épisode")
        }
        let tracks = json["tracks"] as? [[String: Any]] ?? []
        let track = tracks.first { $0["default"] as? Bool == true } ?? tracks.first
        let subtitles = (track?["file"] as? String).flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        return AnimeStream(source: source, subtitles: subtitles)
    }

    func subtitles(_ url: URL) async throws -> [SubtitleCue] {
        let (data, _) = try await session.data(from: url)
        return SubtitleCue.parse(String(decoding: data, as: UTF8.self))
    }
}
