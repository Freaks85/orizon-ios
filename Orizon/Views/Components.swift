import SwiftUI

struct MangaCover: View {
    let url: URL?
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06))
            }
    }
}

struct MangaCard: View {
    let manga: MangaSummary
    var badge: Int = 0
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MangaCover(url: manga.cover)
                .overlay(alignment: .topLeading) {
                    if let status = manga.status {
                        StatusBadge(status: status).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Badge(count: badge).padding(6)
                    }
                }
            if manga.status != nil || manga.kind != nil {
                HStack {
                    Text(manga.status ?? "")
                    Spacer(minLength: 4)
                    Text(manga.kind ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(manga.title)
                .font(.footnote.weight(.bold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
            if let text = caption ?? manga.subtitle {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(Theme.pink)
                    .lineLimit(1)
            }
        }
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status == "En cours" ? Color.green : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.7)))
    }
}

struct FlagBadge: View {
    let flag: String

    var body: some View {
        Text(flag)
            .font(.system(size: 15))
            .frame(width: 28, height: 28)
            .background(Circle().fill(.white))
    }
}

/// Recently updated manga, Aniverse style: big cover, flag, bookmark and the two latest chapters.
struct ReleaseCard: View {
    let manga: MangaSummary
    var openChapter: (Chapter) -> Void

    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: manga) {
                MangaCover(url: manga.cover, cornerRadius: 16)
                    .overlay(alignment: .topLeading) {
                        if let flag = manga.flag {
                            FlagBadge(flag: flag).padding(8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                BookmarkButton(manga: manga).padding(8)
            }

            NavigationLink(value: manga) {
                Text(manga.title)
                    .font(.system(size: 18, weight: .heavy))
                    .fontWidth(.condensed)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            ForEach(manga.latestChapters.prefix(2)) { chapter in
                Button { openChapter(chapter) } label: {
                    ChapterPill(chapter: chapter)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// "Ch. 59 · NOUVEAU" line used on release cards.
struct ChapterPill: View {
    let chapter: Chapter

    var body: some View {
        HStack(spacing: 6) {
            Text("Ch. \(chapter.number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(chapter.isNew ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.75)))
            Spacer(minLength: 4)
            if chapter.isPremium {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.yellow)
            } else if chapter.isNew {
                Text("NOUVEAU")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.gradient))
            } else if let date = chapter.date {
                Text(date.relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(chapter.isNew ? Theme.purple.opacity(0.14) : Color.white.opacity(0.05))
        )
        .contentShape(Rectangle())
    }
}

/// Big card for the horizontal "Populaires" row.
struct TrendCard: View {
    let manga: MangaSummary
    let rank: Int

    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: manga) {
                MangaCover(url: manga.cover, cornerRadius: 18)
                    .overlay(alignment: .bottomLeading) {
                        Text("\(rank)")
                            .font(.system(size: 54, weight: .black))
                            .fontWidth(.condensed)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 8)
                            .padding(.leading, 10)
                            .padding(.bottom, -4)
                    }
                    .overlay(alignment: .topLeading) {
                        if let flag = manga.flag {
                            FlagBadge(flag: flag).padding(8)
                        } else if let status = manga.status {
                            StatusBadge(status: status).padding(8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                BookmarkButton(manga: manga).padding(8)
            }

            Text(manga.title)
                .font(.system(size: 18, weight: .heavy))
                .fontWidth(.condensed)
                .lineLimit(1)
            let tags = [manga.status, manga.kind].compactMap { $0 }
            if !tags.isEmpty {
                Text(tags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 190)
    }
}

struct BookmarkButton: View {
    let manga: MangaSummary
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Button {
            library.toggle(manga, chapters: [])
        } label: {
            Image(systemName: library.contains(manga.slug) ? "bookmark.fill" : "bookmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(library.contains(manga.slug) ? Theme.pink : .white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}

struct GenreInfo: Identifiable {
    let id: String      // value used by the API
    let name: String
    let icon: String
    let blurb: String

    static let all: [GenreInfo] = [
        GenreInfo(id: "Action", name: "Action", icon: "bolt.fill", blurb: "Combats nerveux, cascades et adrénaline."),
        GenreInfo(id: "Adventure", name: "Aventure", icon: "mountain.2.fill", blurb: "Quêtes, voyages et découvertes."),
        GenreInfo(id: "Fantasy", name: "Fantasy", icon: "wand.and.stars", blurb: "Magie, donjons et mondes imaginaires."),
        GenreInfo(id: "Comedy", name: "Comédie", icon: "face.smiling.fill", blurb: "De quoi rire un bon coup."),
        GenreInfo(id: "Drama", name: "Drame", icon: "theatermasks.fill", blurb: "Émotions fortes et destins brisés."),
        GenreInfo(id: "Romance", name: "Romance", icon: "heart.fill", blurb: "Histoires d'amour et cœurs qui battent."),
        GenreInfo(id: "Supernatural", name: "Surnaturel", icon: "sparkles", blurb: "Esprits, pouvoirs et phénomènes étranges."),
        GenreInfo(id: "Horror", name: "Horreur", icon: "eye.trianglebadge.exclamationmark.fill", blurb: "Frissons et cauchemars garantis."),
        GenreInfo(id: "Mystery", name: "Mystère", icon: "magnifyingglass", blurb: "Énigmes, enquêtes et secrets."),
        GenreInfo(id: "Psychological", name: "Psychologique", icon: "brain.head.profile", blurb: "Manipulations et esprits torturés."),
        GenreInfo(id: "Sci-Fi", name: "Science-fiction", icon: "airplane", blurb: "Futur, technologie et espace."),
        GenreInfo(id: "Slice of Life", name: "Tranche de vie", icon: "cup.and.saucer.fill", blurb: "Le quotidien, simplement."),
        GenreInfo(id: "Sports", name: "Sport", icon: "figure.run", blurb: "Compétition, dépassement de soi."),
        GenreInfo(id: "Thriller", name: "Thriller", icon: "exclamationmark.triangle.fill", blurb: "Suspense et tension permanente.")
    ]
}

struct GenreCard: View {
    let genre: GenreInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: genre.icon)
                .font(.title2)
                .foregroundStyle(Theme.gradient)
            Text(genre.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text(genre.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(16)
        .frame(width: 170, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// A horizontal row of manga cards for the home screen.
struct MangaRow: View {
    let mangas: [MangaSummary]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(mangas) { manga in
                    NavigationLink(value: manga) {
                        MangaCard(manga: manga)
                            .frame(width: 118)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Paged loader shared by the grids (home "see all" screens and search).
@MainActor
final class PagedLoader<Item: Identifiable & Hashable>: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = true

    private var page = 1
    /// Position of each item by key: cells ask on appear whether they are near the end.
    private var positions: [AnyHashable: Int] = [:]
    private var fetch: (Int) async throws -> PagedResult<Item>
    private var generation = 0
    /// Items sharing a key are shown once (the first one loaded wins).
    private let key: (Item) -> AnyHashable

    init(key: @escaping (Item) -> AnyHashable = { AnyHashable($0.id) }, fetch: @escaping (Int) async throws -> PagedResult<Item>) {
        self.key = key
        self.fetch = fetch
    }

    func reset(fetch: @escaping (Int) async throws -> PagedResult<Item>) {
        self.fetch = fetch
        generation += 1
        items = []
        positions = [:]
        page = 1
        hasMore = true
        error = nil
        isLoading = false
    }

    func loadMoreIfNeeded(current: Item?) async {
        guard let current else { await loadMore(); return }
        let threshold = items.index(items.endIndex, offsetBy: -8, limitedBy: items.startIndex) ?? items.startIndex
        if let index = positions[key(current)], index >= threshold {
            await loadMore()
        }
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        let currentGeneration = generation
        do {
            let result = try await fetch(page)
            guard currentGeneration == generation else { return }
            var added: [Item] = []
            for item in result.items where positions[key(item)] == nil {
                positions[key(item)] = items.count + added.count
                added.append(item)
            }
            items += added   // a single change for the whole page
            hasMore = result.hasNextPage && !result.items.isEmpty
            page += 1
        } catch {
            guard currentGeneration == generation else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct MangaGrid: View {
    @ObservedObject var loader: PagedLoader<MangaSummary>

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(loader.items) { manga in
                NavigationLink(value: manga) {
                    MangaCard(manga: manga)
                }
                .buttonStyle(.plain)
                .task { await loader.loadMoreIfNeeded(current: manga) }
            }
        }
        .padding(.horizontal)

        if loader.isLoading {
            ProgressView().tint(Theme.pink).padding()
        } else if let error = loader.error {
            ErrorView(message: error) { Task { await loader.loadMore() } }
        } else if loader.items.isEmpty && !loader.hasMore {
            Text("Aucun résultat")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}

struct PagedGridScreen: View {
    let title: String
    @StateObject private var loader: PagedLoader<MangaSummary>

    init(title: String, fetch: @escaping (Int) async throws -> PagedResult<MangaSummary>) {
        self.title = title
        _loader = StateObject(wrappedValue: PagedLoader(fetch: fetch))
    }

    var body: some View {
        ScrollView {
            MangaGrid(loader: loader)
                .padding(.vertical)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if loader.items.isEmpty { await loader.loadMore() } }
    }
}
