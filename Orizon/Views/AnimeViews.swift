import SwiftUI

enum HomeMode: CaseIterable {
    case manga, anime

    var label: String { self == .manga ? "Manga" : "Animé" }
}

/// Manga / Animé switch shown at the top of the home screen.
struct HomeModeSwitch: View {
    @Binding var mode: HomeMode
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeMode.allCases, id: \.self) { item in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = item }
                } label: {
                    Text(item.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(mode == item ? 1 : 0.6))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if mode == item {
                                Capsule().fill(Theme.gradient).matchedGeometryEffect(id: "mode", in: highlight)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

struct AnimeHomeView: View {
    @Binding var mode: HomeMode
    @StateObject private var popular = PagedLoader<Anime> { try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0) }
    @StateObject private var newest = PagedLoader<Anime> { try await AniverseAPI.shared.animeSearch(sort: .newest, page: $0) }
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !popular.items.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Populaires")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(popular.items.prefix(20)) { anime in
                                        NavigationLink(value: anime) { AnimeCard(anime: anime).frame(width: 140) }
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Nouveautés")
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(newest.items) { anime in
                                NavigationLink(value: anime) { AnimeCard(anime: anime) }
                                    .buttonStyle(.plain)
                                    .task { await newest.loadMoreIfNeeded(current: anime) }
                            }
                        }
                        .padding(.horizontal)

                        if newest.isLoading {
                            ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
                        } else if let error = newest.error ?? popular.error {
                            ErrorView(message: error) { Task { await reload() } }
                        }
                    }
                }
                .padding(.vertical)
                .padding(.bottom, 30)
            }
            .background(Theme.background)
            .refreshable { await reload() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo() }
                ToolbarItem(placement: .principal) { HomeModeSwitch(mode: $mode) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                }
            }
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task {
                if popular.items.isEmpty { await popular.loadMore() }
                if newest.items.isEmpty { await newest.loadMore() }
            }
        }
    }

    private func reload() async {
        popular.reset { try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0) }
        newest.reset { try await AniverseAPI.shared.animeSearch(sort: .newest, page: $0) }
        async let a: Void = popular.loadMore()
        async let b: Void = newest.loadMore()
        _ = await (a, b)
    }
}

struct AnimeCard: View {
    let anime: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MangaCover(url: anime.cover)
                .overlay(alignment: .topLeading) {
                    if let status = anime.status {
                        StatusBadge(status: status).padding(6)
                    }
                }
            Text(anime.title)
                .font(.footnote.weight(.bold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
            Text(anime.versions)
                .font(.caption2)
                .foregroundStyle(Theme.pink)
                .lineLimit(1)
        }
    }
}

struct AnimeDetailView: View {
    let anime: Anime
    /// The season whose episodes are listed; starts on the anime that was opened.
    @State private var current: Anime
    @State private var seasons: [AnimeSeason] = []
    @State private var episodes: [Episode] = []
    @State private var language: AnimeLanguage
    @State private var isLoading = false
    @State private var error: String?
    @State private var playing: PlayerContext?
    @EnvironmentObject private var episodeDownloads: EpisodeDownloads

    init(anime: Anime) {
        self.anime = anime
        _current = State(initialValue: anime)
        _language = State(initialValue: anime.subCount == 0 && anime.dubCount > 0 ? .dub : .sub)
    }

    private var available: [Episode] {
        let count = language == .sub ? current.subCount : current.dubCount
        return episodes.filter { $0.number <= count }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Color.clear
                    .frame(height: 260)
                    .overlay { RemoteImage(url: anime.banner ?? anime.cover) }
                    .clipped()
                    .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 12) {
                    Text(anime.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    let tags = [anime.format, anime.status].compactMap { $0 }
                    if !tags.isEmpty {
                        Text(tags.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let synopsis = anime.synopsis {
                        Text(synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal)

                if seasons.count > 1 {
                    seasonPicker
                }

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Version", selection: $language) {
                        ForEach(AnimeLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(seasons.count > 1 ? current.title : "Épisodes")
                        .font(.system(size: 22, weight: .heavy))
                        .fontWidth(.condensed)
                        .lineLimit(2)
                }
                .padding(.horizontal)

                ForEach(available) { episode in
                    row(episode).padding(.horizontal)
                }

                if isLoading {
                    ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
                } else if let error {
                    ErrorView(message: error) { Task { await load() } }
                } else if available.isEmpty {
                    Text("Aucun épisode en \(language.label).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { if episodes.isEmpty { await load() } }
        .task { if seasons.isEmpty { seasons = (try? await AniverseAPI.shared.seasons(animeId: anime.id)) ?? [] } }
        .fullScreenCover(item: $playing) { AnimePlayerView(context: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        episodeDownloads.enqueue(available, anime: current, language: language)
                    } label: {
                        Label("Télécharger les \(available.count) épisodes (\(language.label))", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .disabled(available.isEmpty)
            }
        }
    }

    private var seasonPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saisons")
                .font(.system(size: 22, weight: .heavy))
                .fontWidth(.condensed)
                .padding(.horizontal)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(seasons) { season in
                            let selected = season.id == current.id
                            Button { select(season) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    MangaCover(url: season.image, cornerRadius: 10)
                                        .overlay {
                                            if selected {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(Theme.pink, lineWidth: 2)
                                            }
                                        }
                                    Text(season.name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(2, reservesSpace: true)
                                    if let type = season.type {
                                        Text(type).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 100)
                                .opacity(selected ? 1 : 0.65)
                            }
                            .buttonStyle(.plain)
                            .id(season.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
            }
        }
    }

    private func row(_ episode: Episode) -> some View {
        HStack(spacing: 8) {
            Button {
                playing = PlayerContext(anime: current, episodes: available, language: language, startEpisode: episode.number)
            } label: {
                HStack(spacing: 14) {
                    Text("\(episode.number)")
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceHigh))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Épisode \(episode.number)")
                            .font(.subheadline.weight(.semibold))
                        if let title = episode.title, title != "Épisode \(episode.number)" {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            EpisodeDownloadButton(anime: current, episode: episode, language: language)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
    }

    private func select(_ season: AnimeSeason) {
        guard season.id != current.id else { return }
        current = season.id == anime.id ? anime : season.anime
        episodes = []
        Task { await load() }
    }

    private func load() async {
        let target = current.id
        error = nil
        isLoading = true
        do {
            async let list = AniverseAPI.shared.episodes(animeId: target)
            async let counts = AniverseAPI.shared.episodeCounts(animeId: target)
            let loaded = try await list
            let fresh = try? await counts
            guard target == current.id else { return }
            if let fresh {
                current.subCount = fresh.sub
                current.dubCount = fresh.dub
            }
            if current.subCount == 0 && current.dubCount > 0 { language = .dub }
            episodes = loaded
        } catch {
            guard target == current.id else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

/// Netflix-style download control: arrow, progress ring (tap to stop), then a check mark.
struct EpisodeDownloadButton: View {
    let anime: Anime
    let episode: Episode
    let language: AnimeLanguage
    @EnvironmentObject private var downloads: EpisodeDownloads
    @State private var confirmDelete = false

    private var id: String { EpisodeDownloads.key(anime.id, language, episode.number) }

    var body: some View {
        Group {
            if downloads.downloaded[id] != nil {
                Button { confirmDelete = true } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.pink)
                }
                .accessibilityLabel("Téléchargé")
            } else if let job = downloads.job(id) {
                if job.error != nil {
                    Button { downloads.retryFailed() } label: {
                        Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Réessayer le téléchargement")
                } else {
                    Button { downloads.cancel(id) } label: {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: max(job.progress, 0.02))
                                .stroke(Theme.pink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.2), value: job.progress)
                            Image(systemName: "stop.fill").font(.system(size: 9))
                        }
                        .frame(width: 26, height: 26)
                    }
                    .accessibilityLabel("Arrêter le téléchargement")
                }
            } else {
                Button { downloads.enqueue([episode], anime: anime, language: language) } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .accessibilityLabel("Télécharger l'épisode")
            }
        }
        .font(.title2)
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .buttonStyle(.plain)
        .confirmationDialog("Supprimer l'épisode \(episode.number) téléchargé ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { downloads.delete(id) }
        }
    }
}
