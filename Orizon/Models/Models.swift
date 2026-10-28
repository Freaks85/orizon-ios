import Foundation

/// A manga as shown in lists and grids.
struct MangaSummary: Codable, Hashable, Identifiable {
    /// The site slug (e.g. "chainsaw-man"), used in every URL.
    let slug: String
    var title: String
    var cover: URL?
    var subtitle: String?
    var banner: URL? = nil
    var synopsis: String? = nil
    /// Already translated, e.g. "En cours".
    var status: String? = nil
    /// "Manga", "Manhwa", "Manhua"…
    var kind: String? = nil
    /// ISO country code of origin, e.g. "KR".
    var country: String? = nil
    /// The most recent chapters, newest first (only in "recently updated" lists).
    var latestChapters: [Chapter] = []

    var id: String { slug }

    var flag: String? {
        guard let country, country.count == 2 else { return nil }
        let base: UInt32 = 127397
        var result = ""
        for scalar in country.uppercased().unicodeScalars {
            guard let flagScalar = UnicodeScalar(base + scalar.value) else { return nil }
            result.unicodeScalars.append(flagScalar)
        }
        return result
    }
}

// Decoding written by hand so that fields added in later versions are optional:
// an older save file must never fail to load (a failure would reset the library).
extension MangaSummary {
    enum CodingKeys: String, CodingKey {
        case slug, title, cover, subtitle, banner, synopsis, status, kind, country, latestChapters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? slug
        cover = try? c.decodeIfPresent(URL.self, forKey: .cover)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        banner = try? c.decodeIfPresent(URL.self, forKey: .banner)
        synopsis = try? c.decodeIfPresent(String.self, forKey: .synopsis)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        country = try? c.decodeIfPresent(String.self, forKey: .country)
        latestChapters = (try? c.decodeIfPresent([Chapter].self, forKey: .latestChapters)) ?? []
    }
}

struct MangaDetails: Codable, Hashable {
    let slug: String
    var title: String
    var altTitles: [String]
    var cover: URL?
    var banner: URL?
    var description: String
    var status: String
    var authors: [String]
    var artists: [String]
    var genres: [String]
    var isAdult: Bool
    var kind: String? = nil

    var summary: MangaSummary {
        MangaSummary(slug: slug, title: title, cover: cover, subtitle: nil,
                     banner: banner, synopsis: description, status: status, kind: kind)
    }
}

struct Chapter: Codable, Hashable, Identifiable {
    let id: String
    var number: String
    var title: String?
    var date: Date?
    var premiumUntil: Date?
    /// Small preview image of the chapter (first page), when the site provides one.
    var thumbnail: URL? = nil

    var numberValue: Double { Double(number) ?? 0 }

    var isPremium: Bool {
        guard let premiumUntil else { return false }
        return premiumUntil > Date()
    }

    /// Released less than 48 hours ago.
    var isNew: Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < 48 * 3600
    }

    var displayName: String {
        if let title, !title.isEmpty {
            return "Chapitre \(number) – \(title)"
        }
        return "Chapitre \(number)"
    }
}

struct Page: Codable, Hashable {
    var url: URL
    var width: Double?
    var height: Double?

    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width / height
    }
}

struct PagedResult<T> {
    var items: [T]
    var hasNextPage: Bool
}

enum SortOrder: String, CaseIterable, Identifiable {
    case popularity, newest, rating, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .popularity: return "Popularité"
        case .newest: return "Plus récents"
        case .rating: return "Note"
        case .title: return "Titre"
        }
    }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case ongoing = "Ongoing", finished = "Finished", upcoming = "Upcoming", hiatus = "On hiatus", cancelled = "Cancelled"

    var id: String { rawValue }

    var label: String { MangaStatus.label(rawValue) }
}

enum MangaKind {
    static func label(type: String?, country: String?) -> String? {
        switch (country ?? "").uppercased() {
        case "KR": return "Manhwa"
        case "CN", "TW", "HK": return "Manhua"
        case "JP": return "Manga"
        default:
            guard let type, !type.isEmpty else { return nil }
            return type.uppercased() == "MANGA" ? "Manga" : type.capitalized
        }
    }
}

enum MangaStatus {
    static func label(_ raw: String?) -> String {
        switch (raw ?? "").uppercased() {
        case "RELEASING", "ONGOING": return "En cours"
        case "FINISHED": return "Terminé"
        case "HIATUS", "ON HIATUS": return "En pause"
        case "CANCELLED": return "Annulé"
        case "NOT_YET_RELEASED", "UPCOMING": return "À venir"
        default: return "Inconnu"
        }
    }
}
