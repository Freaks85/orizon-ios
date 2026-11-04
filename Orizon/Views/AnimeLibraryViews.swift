import SwiftUI

/// Opens the player on an episode from outside the detail screen (history, latest releases):
/// the player needs the season's episode list, fetched here, or taken from the downloads offline.
@MainActor
final class AnimeResumer: ObservableObject {
    @Published var context: PlayerContext?
    @Published var error: String?
    @Published private(set) var loading: String?

    func resume(_ progress: WatchProgress) {
        open(series: progress.series, season: progress.season, language: progress.language,
             episode: progress.episode, nextIfFinished: progress.isFinished, loadingKey: progress.id)
    }

    func open(series: Anime, season: Anime, language: AnimeLanguage, episode: Int, nextIfFinished: Bool = false, loadingKey: String) {
        guard loading == nil else { return }
        loading = loadingKey
        Task {
            defer { loading = nil }
            var episodes: [Episode]
            do {
                async let list = AniverseAPI.shared.episodes(animeId: season.id)
                async let counts = AniverseAPI.shared.episodeCounts(animeId: season.id)
                let all = try await list
                let limit = (try? await counts).map { language == .sub ? $0.sub : $0.dub } ?? 0
                episodes = all.filter { limit == 0 || $0.number <= limit }
            } catch {
                episodes = EpisodeDownloads.shared.downloaded.values
                    .filter { $0.anime.id == season.id && $0.language == language }
                    .map(\.episode)
                    .sorted { $0.number < $1.number }
                if episodes.isEmpty {
                    self.error = error.localizedDescription
                    return
                }
            }
            var start = episode
            if nextIfFinished, let next = episodes.first(where: { $0.number > episode }) { start = next.number }
            guard episodes.contains(where: { $0.number == start }) else {
                self.error = "L'épisode \(start) n'est pas disponible en \(language.label)."
                return
            }
            context = PlayerContext(anime: season, series: series, episodes: episodes, language: language, startEpisode: start)
        }
    }
}

extension View {
    func presentingPlayer(_ resumer: AnimeResumer) -> some View {
        fullScreenCover(item: Binding(get: { resumer.context }, set: { resumer.context = $0 })) { AnimePlayerView(context: $0) }
            .alert("Impossible de lancer l'épisode", isPresented: Binding(get: { resumer.error != nil }, set: { if !$0 { resumer.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resumer.error ?? "")
            }
    }
}

// MARK: - Continuer à regarder

struct ContinueWatchingRow: View {
    let items: [WatchProgress]
    @EnvironmentObject private var store: AnimeStore
    @StateObject private var resumer = AnimeResumer()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    Button { resumer.resume(item) } label: {
                        ContinueCard(item: item, loading: resumer.loading == item.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        NavigationLink(value: item.series) {
                            Label("Voir la fiche", systemImage: "info.circle")
                        }
                        Button(role: .destructive) { withAnimation { store.removeHistory(item.id) } } label: {
                            Label("Retirer de l'historique", systemImage: "xmark")
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .presentingPlayer(resumer)
    }
}

struct ContinueCard: View {
    let item: WatchProgress
    var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: 120)
                .overlay { RemoteImage(url: item.series.banner ?? item.season.cover ?? item.series.cover) }
                .overlay {
                    if loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle().fill(Theme.gradient).frame(width: geo.size.width * item.fraction)
                        }
                    }
                    .frame(height: 4)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(item.series.title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 220)
    }

    private var caption: String {
        let base = "Ép. \(item.episode) · \(item.language.label)"
        if item.isFinished { return base + " · terminé" }
        let minutes = Int(max(item.duration - item.position, 0) / 60)
        return base + " · \(max(minutes, 1)) min restantes"
    }
}

// MARK: - Bibliothèque

struct AnimeLibraryView: View {
    @EnvironmentObject private var store: AnimeStore
    @StateObject private var resumer = AnimeResumer()
    @State private var tab: Tab = .watching
    @State private var confirmClear = false

    enum Tab: String, CaseIterable, Identifiable {
        case watching = "En cours"
        case list = "Ma liste"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch tab {
                case .watching: watching
                case .list: listGrid
                }
            }
            .background(Theme.background)
            .navigationTitle("Bibliothèque")
            .toolbar {
                if tab == .watching && !store.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                    }
                }
            }
            .confirmationDialog("Effacer l'historique des animés ?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Effacer", role: .destructive) { store.clearHistory() }
            }
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
            .presentingPlayer(resumer)
        }
    }

    @ViewBuilder
    private var watching: some View {
        if store.history.isEmpty {
            emptyState(icon: "play.circle", text: "Aucun animé en cours.\nLance un épisode : il apparaîtra ici pour reprendre là où tu t'es arrêté.")
        } else {
            List {
                ForEach(store.history) { item in
                    HStack(spacing: 12) {
                        MangaCover(url: item.season.cover ?? item.series.cover, cornerRadius: 6)
                            .frame(width: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.series.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if item.season.id != item.series.id {
                                Text(item.season.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text("Épisode \(item.episode) · \(item.language.label)\(item.isFinished ? " · terminé" : "")")
                                .font(.footnote)
                                .foregroundStyle(Theme.pink)
                            ProgressView(value: item.fraction).tint(Theme.pink)
                            Text(item.updatedAt.relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        if resumer.loading == item.id {
                            ProgressView().tint(Theme.pink)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.gradient)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { resumer.resume(item) }
                    .contextMenu {
                        NavigationLink(value: item.series) {
                            Label("Voir la fiche", systemImage: "info.circle")
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.removeHistory(item.id) } label: {
                            Label("Retirer", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var listGrid: some View {
        if store.list.isEmpty {
            emptyState(icon: "bookmark", text: "Ta liste est vide.\nAjoute des animés depuis leur fiche avec le signet en haut.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.list) { anime in
                        NavigationLink(value: anime) {
                            AnimeCard(anime: anime)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.toggleList(anime) } label: {
                                Label("Retirer de ma liste", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.gradient)
                Text(text)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
            .padding(.horizontal)
        }
    }
}

// MARK: - Recherche

struct AnimeSearchView: View {
    @State private var query = ""
    @State private var sort: SortOrder = .popularity
    @StateObject private var loader = PagedLoader<Anime>(key: { $0.listKey }) {
        try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0)
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Trier par", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(loader.items) { anime in
                            NavigationLink(value: anime) {
                                AnimeCard(anime: anime)
                            }
                            .buttonStyle(.plain)
                            .task { await loader.loadMoreIfNeeded(current: anime) }
                        }
                    }
                    .padding(.horizontal)

                    if loader.isLoading {
                        ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
                    } else if let error = loader.error {
                        ErrorView(message: error) { Task { await loader.loadMore() } }
                    } else if loader.items.isEmpty && !loader.hasMore {
                        Text("Aucun résultat")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    }
                }
                .padding(.vertical)
            }
            .background(Theme.background)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Recherche")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher un animé par titre…")
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
            .task(id: "\(query)|\(sort.rawValue)") {
                // Debounce typing.
                if !query.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
                if Task.isCancelled { return }
                let q = query, s = sort
                loader.reset { try await AniverseAPI.shared.animeSearch(query: q, sort: s, page: $0) }
                await loader.loadMore()
            }
        }
    }
}

// MARK: - Accueil

/// Full-width featured animes, like the manga home.
struct AnimeHeroCarousel: View {
    let animes: [Anime]
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $selection) {
                ForEach(Array(animes.enumerated()), id: \.element.id) { index, anime in
                    page(anime).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 560)

            HStack(spacing: 7) {
                ForEach(animes.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == selection ? Color.white : Color.white.opacity(0.35))
                        .frame(width: index == selection ? 22 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.25), value: selection)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: selection) {
            // Auto-advance; restarts whenever the user swipes.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled || animes.isEmpty { return }
            withAnimation { selection = (selection + 1) % animes.count }
        }
    }

    private func page(_ anime: Anime) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay { RemoteImage(url: anime.cover ?? anime.banner) }
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.25),
                    .init(color: .clear, location: 0.45),
                    .init(color: Theme.background.opacity(0.85), location: 0.78),
                    .init(color: Theme.background, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 12) {
                Text(anime.title)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.6), radius: 8)

                let tags = [anime.format, anime.status, anime.versions.isEmpty ? nil : anime.versions].compactMap { $0 }
                if !tags.isEmpty {
                    Text(tags.joined(separator: " · "))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35)))
                        .foregroundStyle(.white)
                }

                if let synopsis = anime.synopsis {
                    Text(synopsis)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }

                NavigationLink(value: anime) {
                    Label("Voir l'animé", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// A recently updated anime: the card opens the series, the pills play the newest episodes.
struct AnimeReleaseCard: View {
    let anime: Anime
    var loadingEpisode: Int?
    var onEpisode: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: anime) {
                AnimeCard(anime: anime)
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                ForEach(anime.latestEpisodes.prefix(2), id: \.self) { number in
                    Button { onEpisode(number) } label: {
                        HStack(spacing: 4) {
                            if loadingEpisode == number {
                                ProgressView().controlSize(.mini).tint(Theme.pink)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 8))
                            }
                            Text("Ép. \(number)")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.surfaceHigh))
                        .overlay(Capsule().strokeBorder(Theme.pink.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
