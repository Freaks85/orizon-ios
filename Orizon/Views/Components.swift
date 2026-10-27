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
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Badge(count: badge).padding(6)
                    }
                }
            Text(manga.title)
                .font(.footnote.weight(.semibold))
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
final class PagedLoader: ObservableObject {
    @Published private(set) var items: [MangaSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = true

    private var page = 1
    private var fetch: (Int) async throws -> PagedResult<MangaSummary>
    private var generation = 0

    init(fetch: @escaping (Int) async throws -> PagedResult<MangaSummary>) {
        self.fetch = fetch
    }

    func reset(fetch: @escaping (Int) async throws -> PagedResult<MangaSummary>) {
        self.fetch = fetch
        generation += 1
        items = []
        page = 1
        hasMore = true
        error = nil
        isLoading = false
    }

    func loadMoreIfNeeded(current: MangaSummary?) async {
        guard let current else { await loadMore(); return }
        let threshold = items.index(items.endIndex, offsetBy: -8, limitedBy: items.startIndex) ?? items.startIndex
        if let index = items.firstIndex(of: current), index >= threshold {
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
            let known = Set(items.map(\.slug))
            items += result.items.filter { !known.contains($0.slug) }
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
    @ObservedObject var loader: PagedLoader

    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 12)]

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
    @StateObject private var loader: PagedLoader

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
