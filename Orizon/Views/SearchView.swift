import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var sort: SortOrder = .popularity
    @State private var genres: Set<String> = []
    @State private var statuses: Set<StatusFilter> = []
    @StateObject private var loader = PagedLoader<MangaSummary> { page in
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
                let q = query, s = sort, g = Array(genres).sorted(), st = statuses.map(\.rawValue).sorted()
                loader.reset { page in try await AniverseAPI.shared.search(query: q, sort: s, genres: g, statuses: st, page: page) }
                await loader.loadMore()
            }
        }
    }

    private var searchKey: String {
        "\(query)|\(sort.rawValue)|\(genres.sorted().joined(separator: ","))|\(statuses.map(\.rawValue).sorted().joined(separator: ","))"
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    chip(icon: sortIcon.0, text: sort.label, active: true, iconColor: sortIcon.1)
                }

                Menu {
                    ForEach(StatusFilter.allCases) { status in
                        Button {
                            if statuses.contains(status) { statuses.remove(status) } else { statuses.insert(status) }
                        } label: {
                            if statuses.contains(status) {
                                Label(status.label, systemImage: "checkmark")
                            } else {
                                Text(status.label)
                            }
                        }
                    }
                    if !statuses.isEmpty {
                        Divider()
                        Button("Effacer les statuts", role: .destructive) { statuses.removeAll() }
                    }
                } label: {
                    chip(icon: "checkmark.circle.fill", text: statuses.isEmpty ? "Statut" : "Statut (\(statuses.count))",
                         active: !statuses.isEmpty, iconColor: .green)
                }

                Menu {
                    ForEach(Self.allGenres, id: \.self) { genre in
                        Button {
                            if genres.contains(genre) { genres.remove(genre) } else { genres.insert(genre) }
                        } label: {
                            if genres.contains(genre) {
                                Label(Self.genreName(genre), systemImage: "checkmark")
                            } else {
                                Text(Self.genreName(genre))
                            }
                        }
                    }
                    if !genres.isEmpty {
                        Divider()
                        Button("Effacer les genres", role: .destructive) { genres.removeAll() }
                    }
                } label: {
                    chip(icon: "tag.fill", text: genres.isEmpty ? "Genres" : "Genres (\(genres.count))", active: !genres.isEmpty, iconColor: Theme.pink)
                }

                ForEach(genres.sorted(), id: \.self) { genre in
                    Button { genres.remove(genre) } label: {
                        chip(icon: "xmark", text: Self.genreName(genre), active: true)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    static func genreName(_ id: String) -> String {
        GenreInfo.all.first { $0.id == id }?.name ?? id
    }

    private var sortIcon: (String, Color) {
        switch sort {
        case .popularity: return ("flame.fill", .orange)
        case .rating: return ("star.fill", .yellow)
        case .title: return ("textformat", .cyan)
        case .newest: return ("clock.fill", .purple)
        }
    }

    private func chip(icon: String, text: String, active: Bool, iconColor: Color = .primary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(iconColor)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(active ? Theme.surfaceHigh : Theme.surface))
        .overlay(Capsule().strokeBorder(active ? Theme.pink.opacity(0.5) : .clear))
        .foregroundStyle(.primary)
    }
}
