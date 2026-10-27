import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var sort: SortOrder = .popularity
    @State private var genres: Set<String> = []
    @StateObject private var loader = PagedLoader { page in
        try await AniverseAPI.shared.search(sort: .popularity, page: page)
    }

    static let allGenres = [
        "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy", "Horror", "Mahou Shoujo",
        "Mecha", "Music", "Mystery", "Psychological", "Romance", "Sci-Fi", "Slice of Life",
        "Sports", "Supernatural", "Thriller"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filters
                    MangaGrid(loader: loader)
                }
                .padding(.vertical)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Recherche")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher un manga par titre…")
            .navigationDestination(for: MangaSummary.self) { MangaDetailView(manga: $0) }
            .task(id: searchKey) {
                // Debounce typing.
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
                if Task.isCancelled { return }
                let q = query, s = sort, g = Array(genres).sorted()
                loader.reset { page in try await AniverseAPI.shared.search(query: q, sort: s, genres: g, page: page) }
                await loader.loadMore()
            }
        }
    }

    private var searchKey: String {
        "\(query)|\(sort.rawValue)|\(genres.sorted().joined(separator: ","))"
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    chip(icon: "arrow.up.arrow.down", text: sort.label, active: true)
                }

                Menu {
                    ForEach(Self.allGenres, id: \.self) { genre in
                        Button {
                            if genres.contains(genre) { genres.remove(genre) } else { genres.insert(genre) }
                        } label: {
                            if genres.contains(genre) {
                                Label(genre, systemImage: "checkmark")
                            } else {
                                Text(genre)
                            }
                        }
                    }
                    if !genres.isEmpty {
                        Divider()
                        Button("Effacer les genres", role: .destructive) { genres.removeAll() }
                    }
                } label: {
                    chip(icon: "tag", text: genres.isEmpty ? "Genres" : "Genres (\(genres.count))", active: !genres.isEmpty)
                }

                ForEach(genres.sorted(), id: \.self) { genre in
                    Button { genres.remove(genre) } label: {
                        chip(icon: "xmark", text: genre, active: true)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(active ? Theme.surfaceHigh : Theme.surface))
        .overlay(Capsule().strokeBorder(active ? Theme.pink.opacity(0.5) : .clear))
        .foregroundStyle(.primary)
    }
}
