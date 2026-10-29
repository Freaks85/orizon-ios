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
    @EnvironmentObject private var store: AnimeStore
    @StateObject private var popular = PagedLoader<Anime>(key: { $0.listKey }) { try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0) }
    @StateObject private var upcoming = PagedLoader<Anime> { try await AniverseAPI.shared.animeCategory("upcoming", page: $0) }
    @StateObject private var releases = PagedLoader<Anime> { try await AniverseAPI.shared.animeCategory("recently-updated", page: $0) }
    @StateObject private var resumer = AnimeResumer()
    @State private var showSettings = false

    private let releaseColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if !popular.items.isEmpty {
                        AnimeHeroCarousel(animes: Array(popular.items.prefix(8)))
                    } else {
                        Color.clear.frame(height: 110)
                    }

                    if !store.history.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Continuer à regarder")
                            ContinueWatchingRow(items: Array(store.history.prefix(15)))
                        }
                    }

                    if !popular.items.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Populaires")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(popular.items) { anime in
                                        NavigationLink(value: anime) { AnimeCard(anime: anime).frame(width: 140) }
                                            .buttonStyle(.plain)
                                            .task { await popular.loadMoreIfNeeded(current: anime) }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    if !upcoming.items.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "À venir")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(upcoming.items) { anime in
                                        NavigationLink(value: anime) { AnimeCard(anime: anime).frame(width: 140) }
                                            .buttonStyle(.plain)
                                            .task { await upcoming.loadMoreIfNeeded(current: anime) }
                                    }
                                    if upcoming.isLoading {
                                        ProgressView().tint(Theme.pink).frame(width: 60, height: 200)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    releasesSection
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: .top)
            .background(Theme.background)
            .refreshable { await reload() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
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
            .presentingPlayer(resumer)
            .task {
                async let a: Void = loadIfEmpty(popular)
                async let b: Void = loadIfEmpty(upcoming)
                async let c: Void = loadIfEmpty(releases)
                _ = await (a, b, c)
            }
        }
    }

    private var releasesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Dernières sorties")
                Text("Triés par date de sortie du dernier épisode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: releaseColumns, alignment: .leading, spacing: 26) {
                ForEach(releases.items) { anime in
                    AnimeReleaseCard(anime: anime, loadingEpisode: loadingEpisode(anime)) { number in
                        let language: AnimeLanguage = anime.subCount == 0 && anime.dubCount > 0 ? .dub : .sub
                        resumer.open(series: anime, season: anime, language: language, episode: number,
                                     loadingKey: "\(anime.id)-\(number)")
                    }
                    .task { await releases.loadMoreIfNeeded(current: anime) }
                }
            }
            .padding(.horizontal)

            if releases.isLoading {
                ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
            } else if let error = releases.error ?? popular.error {
                ErrorView(message: error) { Task { await reload() } }
            }
        }
    }

    private func loadingEpisode(_ anime: Anime) -> Int? {
        guard let key = resumer.loading, key.hasPrefix(anime.id + "-") else { return nil }
        return Int(key.dropFirst(anime.id.count + 1))
    }

    private func loadIfEmpty(_ loader: PagedLoader<Anime>) async {
        if loader.items.isEmpty { await loader.loadMore() }
    }

    private func reload() async {
        popular.reset { try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0) }
        upcoming.reset { try await AniverseAPI.shared.animeCategory("upcoming", page: $0) }
        releases.reset { try await AniverseAPI.shared.animeCategory("recently-updated", page: $0) }
        async let a: Void = popular.loadMore()
        async let b: Void = upcoming.loadMore()
        async let c: Void = releases.loadMore()
        _ = await (a, b, c)
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
                .overlay(alignment: .topTrailing) {
                    if anime.isMovie {
                        Label("Film", systemImage: "film")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.gradient))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
            Text(anime.title)
                .font(.footnote.weight(.bold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
            Text(anime.seriesId == nil || anime.isMovie ? anime.versions : [anime.versions, "Saisons"].filter { !$0.isEmpty }.joined(separator: " · "))
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
    @State private var showExtras = false
    @State private var showFullSynopsis = false
    @EnvironmentObject private var episodeDownloads: EpisodeDownloads
    @EnvironmentObject private var store: AnimeStore
    @StateObject private var resumer = AnimeResumer()

    init(anime: Anime) {
        self.anime = anime
        _current = State(initialValue: anime)
        _language = State(initialValue: Self.preferredLanguage(sub: anime.subCount, dub: anime.dubCount))
    }

    /// The version chosen in the settings, unless this anime only exists in the other one.
    static func preferredLanguage(sub: Int, dub: Int) -> AnimeLanguage {
        let preferred = AnimeLanguage(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.animeLanguage) ?? "") ?? .sub
        switch preferred {
        case .sub: return sub == 0 && dub > 0 ? .dub : .sub
        case .dub: return dub == 0 && sub > 0 ? .sub : .dub
        }
    }

    private var unwatched: [Episode] {
        available.filter { !store.isWatched(animeId: current.id, episode: $0.number) }
    }

    private var available: [Episode] {
        let count = language == .sub ? current.subCount : current.dubCount
        return episodes.filter { $0.number <= count }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Color.clear
                    .frame(height: 320)
                    .overlay { RemoteImage(url: headerImage) }
                    .clipped()
                    .overlay(LinearGradient(
                        stops: [.init(color: .clear, location: 0.35), .init(color: Theme.background, location: 1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(anime.title)
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .lineLimit(3)
                                .shadow(color: .black.opacity(0.6), radius: 8)
                            let tags = [current.format, current.status ?? anime.status].compactMap { $0 }
                            if !tags.isEmpty {
                                Text(tags.joined(separator: " · "))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(.horizontal)
                    }

                if seasons.count > 1 {
                    seasonPills
                }

                if let synopsis = anime.synopsis {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(showFullSynopsis ? nil : 3)
                        Button(showFullSynopsis ? "Moins" : "Plus") {
                            withAnimation(.easeInOut(duration: 0.2)) { showFullSynopsis.toggle() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.pink)
                    }
                    .padding(.horizontal)
                }

                if let progress = store.progress(series: anime) {
                    Button { resumer.resume(progress) } label: {
                        HStack {
                            if resumer.loading == progress.id {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(resumeTitle(progress)).lineLimit(1)
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .padding(.horizontal)
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
        .task {
            guard seasons.isEmpty else { return }
            seasons = (try? await AniverseAPI.shared.seasons(animeId: anime.id)) ?? []
            showExtras = extras.contains { $0.id == current.id }
        }
        .fullScreenCover(item: $playing) { AnimePlayerView(context: $0) }
        .background { Color.clear.presentingPlayer(resumer) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { store.toggleList(anime) } label: {
                    Image(systemName: store.isInList(anime) ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(store.isInList(anime) ? AnyShapeStyle(Theme.pink) : AnyShapeStyle(Color.white))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel(store.isInList(anime) ? "Retirer de ma liste" : "Ajouter à ma liste")
                Menu {
                    Section("\(current.title) · \(language.label)") {
                        Button {
                            episodeDownloads.enqueue(available, anime: current, language: language)
                        } label: {
                            Label("Télécharger la saison (\(available.count) ép.)", systemImage: "arrow.down.circle")
                        }
                        Button {
                            episodeDownloads.enqueue(unwatched, anime: current, language: language)
                        } label: {
                            Label("Télécharger les non vus (\(unwatched.count) ép.)", systemImage: "eye.slash")
                        }
                        .disabled(unwatched.isEmpty)
                    }
                    Section {
                        Button {
                            store.setWatched(true, animeId: current.id, episodes: available.map(\.number))
                        } label: {
                            Label("Marquer la saison comme vue", systemImage: "eye")
                        }
                        Button {
                            store.setWatched(false, animeId: current.id, episodes: available.map(\.number))
                        } label: {
                            Label("Marquer la saison comme non vue", systemImage: "eye.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .disabled(available.isEmpty)
            }
        }
    }

    private var headerImage: URL? {
        current.id == anime.id ? anime.banner ?? anime.cover : current.cover ?? anime.banner ?? anime.cover
    }

    /// TV seasons are numbered in watching order; films, OVA and specials go in their own tab.
    private static let mainTypes: Set<String> = ["TV", "TV SHORT", "ONA"]
    private func isMain(_ season: AnimeSeason) -> Bool { Self.mainTypes.contains((season.type ?? "TV").uppercased()) }
    private var mainSeasons: [AnimeSeason] { seasons.filter(isMain) }
    private var extras: [AnimeSeason] { seasons.filter { !isMain($0) } }

    private var seasonPills: some View {
        let showingExtras = showExtras || mainSeasons.isEmpty
        let list = showingExtras ? extras : mainSeasons
        return VStack(alignment: .leading, spacing: 12) {
            if !mainSeasons.isEmpty && !extras.isEmpty {
                HStack(spacing: 8) {
                    kindTab("Saisons", count: mainSeasons.count, selected: !showExtras) { showExtras = false }
                    kindTab("Films & OVA", count: extras.count, selected: showExtras) { showExtras = true }
                }
                .padding(.horizontal)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, season in
                            pill(season, label: showingExtras ? Self.extraLabel(season) : Self.seasonLabel(season.name, fallback: index + 1))
                                .id(season.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
                .onChange(of: showExtras) { _ in
                    withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
        }
    }

    private func kindTab(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.bold))
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(selected ? 0.25 : 0.1)))
            }
            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().strokeBorder(Color.white.opacity(selected ? 0.5 : 0.15)))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ season: AnimeSeason, label: String) -> some View {
        let selected = season.id == current.id
        return Button { select(season) } label: {
            HStack(spacing: 6) {
                if let icon = Self.icon(season.type) {
                    Image(systemName: icon).font(.caption.weight(.bold))
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: 240)
            .background {
                if selected {
                    Capsule().fill(Theme.gradient)
                } else {
                    Capsule().fill(Theme.surfaceHigh)
                }
            }
            .foregroundStyle(Color.white.opacity(selected ? 1 : 0.8))
        }
        .buttonStyle(.plain)
    }

    private static func icon(_ type: String?) -> String? {
        switch (type ?? "").uppercased() {
        case "MOVIE": return "film"
        case "OVA", "SPECIAL": return "sparkles"
        case "MUSIC": return "music.note"
        default: return nil
        }
    }

    /// Uses the number in the name when there is one ("Saison 3 Part 2" → "Saison 3 · Partie 2",
    /// "Final Season" → "Saison finale"), otherwise the position in watching order.
    private static func seasonLabel(_ name: String, fallback: Int) -> String {
        let lower = name.lowercased()
        var label = "Saison \(fallback)"
        if lower.contains("final season") || lower.contains("saison finale") {
            label = "Saison finale"
        } else if let range = lower.range(of: #"(saison|season)\s*\d+"#, options: .regularExpression) {
            label = "Saison " + lower[range].filter(\.isNumber)
        }
        if let range = lower.range(of: #"(part|partie|cour)\s*\d+"#, options: .regularExpression) {
            label += " · Partie " + lower[range].filter(\.isNumber)
        }
        return label
    }

    /// "Attack on Titan: No Regrets" → "No Regrets".
    private static func extraLabel(_ season: AnimeSeason) -> String {
        let name = season.name.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? season.name : name
    }

    private func row(_ episode: Episode) -> some View {
        HStack(spacing: 8) {
            Button {
                playing = PlayerContext(anime: current, series: anime, episodes: available, language: language, startEpisode: episode.number)
            } label: {
                HStack(spacing: 14) {
                    let watched = store.isWatched(animeId: current.id, episode: episode.number)
                    ZStack {
                        if watched {
                            Image(systemName: "checkmark").font(.headline.weight(.bold)).foregroundStyle(Theme.pink)
                        } else {
                            Text("\(episode.number)").font(.headline.monospacedDigit())
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceHigh))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Épisode \(episode.number)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(watched ? .secondary : .primary)
                        if let title = episode.title, title != "Épisode \(episode.number)" {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !watched, let partial = store.partial(animeId: current.id, language: language, episode: episode.number, duration: nil) {
                            ProgressView(value: min(max(partial, 0), 1))
                                .tint(Theme.pink)
                                .frame(maxWidth: 140)
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
        .contextMenu {
            if store.isWatched(animeId: current.id, episode: episode.number) {
                Button { store.setWatched(false, animeId: current.id, episodes: [episode.number]) } label: {
                    Label("Marquer comme non vu", systemImage: "eye.slash")
                }
            } else {
                Button { store.setWatched(true, animeId: current.id, episodes: [episode.number]) } label: {
                    Label("Marquer comme vu", systemImage: "eye")
                }
            }
            Button {
                store.setWatched(true, animeId: current.id, episodes: available.filter { $0.number <= episode.number }.map(\.number))
            } label: {
                Label("Marquer jusqu'ici comme vus", systemImage: "checkmark.circle")
            }
        }
    }

    private func resumeTitle(_ progress: WatchProgress) -> String {
        let season = progress.season.id == anime.id ? "" : "\(progress.season.title) · "
        if progress.isFinished { return "Continuer · \(season)après l'ép. \(progress.episode)" }
        return "Reprendre · \(season)Ép. \(progress.episode)"
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
            if (language == .sub ? current.subCount : current.dubCount) == 0 {
                language = Self.preferredLanguage(sub: current.subCount, dub: current.dubCount)
            }
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
                        DownloadProgressReader(progress: downloads.progress, id: id) { value in
                            let fraction = value?.fraction ?? 0
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                                Circle()
                                    .trim(from: 0, to: max(fraction, 0.02))
                                    .stroke(Theme.pink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 0.2), value: fraction)
                                Image(systemName: "stop.fill").font(.system(size: 9))
                            }
                            .frame(width: 26, height: 26)
                        }
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
