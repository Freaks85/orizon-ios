import SwiftUI

struct ReaderContext: Identifiable {
    var manga: MangaSummary
    /// Chapters sorted newest first, as shown in the details screen.
    var chapters: [Chapter]
    var startChapterId: String
    var startPage: Int = 0

    var id: String { startChapterId }
}

@MainActor
final class HomeModel: ObservableObject {
    @Published var latest: [MangaSummary] = []
    @Published var popular: [MangaSummary] = []
    @Published var newest: [MangaSummary] = []
    @Published var error: String?
    @Published var isLoading = false

    func load() async {
        isLoading = true
        error = nil
        async let latestResult = AniverseAPI.shared.latest(page: 1)
        async let popularResult = AniverseAPI.shared.search(sort: .popularity, page: 1)
        async let newestResult = AniverseAPI.shared.search(sort: .newest, page: 1)
        do {
            let (l, p, n) = try await (latestResult, popularResult, newestResult)
            latest = l.items
            popular = p.items
            newest = n.items
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = HomeModel()
    @State private var showSettings = false
    @State private var reader: ReaderContext?
    @State private var openingChapter: String?
    @State private var openError: String?

    private let releaseColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !model.popular.isEmpty {
                        HeroCarousel(mangas: Array(model.popular.prefix(8)))
                    } else {
                        Color.clear.frame(height: 100)
                    }

                    if !library.continueReading.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Historique")
                            HistoryRow(items: Array(library.continueReading.prefix(15)))
                        }
                    }

                    genresRow

                    if !model.latest.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                SectionHeader(title: "Sorties récentes") {
                                    NavigationLink {
                                        ReleasesScreen()
                                    } label: {
                                        Text("Tout voir").font(.subheadline).foregroundStyle(Theme.pink)
                                    }
                                }
                                Text("Triés par date de sortie du dernier chapitre.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            LazyVGrid(columns: releaseColumns, spacing: 22) {
                                ForEach(model.latest.prefix(10)) { manga in
                                    ReleaseCard(manga: manga) { open($0, of: manga) }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    section("Populaires", items: model.popular) {
                        PagedGridScreen(title: "Populaires") { try await AniverseAPI.shared.search(sort: .popularity, page: $0) }
                    }
                    section("Nouveautés", items: model.newest) {
                        PagedGridScreen(title: "Nouveautés") { try await AniverseAPI.shared.search(sort: .newest, page: $0) }
                    }

                    if model.isLoading && model.latest.isEmpty {
                        ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding(40)
                    } else if let error = model.error, model.latest.isEmpty {
                        ErrorView(message: error) { Task { await model.load() } }
                    }
                }
                .padding(.bottom)
            }
            .ignoresSafeArea(edges: .top)
            .background(Theme.background)
            .refreshable { await model.load() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo() }
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
            .navigationDestination(for: MangaSummary.self) { MangaDetailView(manga: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $reader) { ReaderView(context: $0) }
            .overlay {
                if openingChapter != nil {
                    ProgressView("Ouverture du chapitre…")
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                }
            }
            .alert("Impossible d'ouvrir le chapitre", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(openError ?? "")
            }
            .task { if model.latest.isEmpty { await model.load() } }
        }
    }

    private var genresRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Genres")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(GenreInfo.all) { genre in
                        NavigationLink {
                            PagedGridScreen(title: genre.name) { try await AniverseAPI.shared.latest(page: $0, genre: genre.id) }
                        } label: {
                            GenreCard(genre: genre)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Opens a chapter straight from a release card: the reader needs the full chapter list.
    private func open(_ chapter: Chapter, of manga: MangaSummary) {
        guard openingChapter == nil else { return }
        openingChapter = chapter.id
        Task {
            defer { openingChapter = nil }
            do {
                let chapters = try await AniverseAPI.shared.chapters(slug: manga.slug)
                if library.contains(manga.slug) { library.merge(chapters: chapters, for: manga) }
                reader = ReaderContext(manga: manga, chapters: chapters, startChapterId: chapter.id)
            } catch {
                openError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func section<Destination: View>(_ title: String, items: [MangaSummary], @ViewBuilder destination: @escaping () -> Destination) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title) {
                    NavigationLink {
                        destination()
                    } label: {
                        Text("Tout voir").font(.subheadline).foregroundStyle(Theme.pink)
                    }
                }
                MangaRow(mangas: items)
            }
        }
    }
}

/// All recently updated mangas as release cards, with infinite scrolling.
struct ReleasesScreen: View {
    @StateObject private var loader = PagedLoader { try await AniverseAPI.shared.latest(page: $0) }
    @EnvironmentObject private var library: LibraryStore
    @State private var reader: ReaderContext?
    @State private var opening = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(loader.items) { manga in
                    ReleaseCard(manga: manga) { chapter in
                        guard !opening else { return }
                        opening = true
                        Task {
                            defer { opening = false }
                            if let chapters = try? await AniverseAPI.shared.chapters(slug: manga.slug) {
                                reader = ReaderContext(manga: manga, chapters: chapters, startChapterId: chapter.id)
                            }
                        }
                    }
                    .task { await loader.loadMoreIfNeeded(current: manga) }
                }
            }
            .padding()
            if loader.isLoading {
                ProgressView().tint(Theme.pink).padding()
            } else if let error = loader.error {
                ErrorView(message: error) { Task { await loader.loadMore() } }
            }
        }
        .background(Theme.background)
        .navigationTitle("Sorties récentes")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if opening { ProgressView().tint(Theme.pink) } }
        .fullScreenCover(item: $reader) { ReaderView(context: $0) }
        .task { if loader.items.isEmpty { await loader.loadMore() } }
    }
}

struct Logo: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.pages.fill")
                .foregroundStyle(Theme.gradient)
            Text("Orizon")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.4), radius: 6)
    }
}

/// Full-width featured mangas, in the style of aniverse.fr's home page.
struct HeroCarousel: View {
    let mangas: [MangaSummary]
    @State private var selection = 0

    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $selection) {
                ForEach(Array(mangas.enumerated()), id: \.element.id) { index, manga in
                    HeroPage(manga: manga).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 560)

            HStack(spacing: 7) {
                ForEach(mangas.indices, id: \.self) { index in
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
            if Task.isCancelled || mangas.isEmpty { return }
            withAnimation { selection = (selection + 1) % mangas.count }
        }
    }
}

struct HeroPage: View {
    let manga: MangaSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay { RemoteImage(url: manga.cover ?? manga.banner) }
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
                Text(manga.title)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.6), radius: 8)

                let tags = [manga.kind, manga.status].compactMap { $0 }
                if !tags.isEmpty {
                    Text(tags.joined(separator: " · "))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35)))
                        .foregroundStyle(.white)
                }

                if let synopsis = manga.synopsis {
                    Text(synopsis)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }

                NavigationLink(value: manga) {
                    Label("Voir le manga", systemImage: "play.fill")
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

/// "Historique": the mangas being read, most recent first.
struct HistoryRow: View {
    let items: [ReadingProgress]
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items, id: \.manga.slug) { item in
                    NavigationLink(value: item.manga) {
                        VStack(alignment: .leading, spacing: 6) {
                            MangaCover(url: item.manga.cover, cornerRadius: 16)
                                .overlay(alignment: .topLeading) {
                                    if let status = item.manga.status {
                                        Text(status)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(status == "En cours" ? Color.green : Theme.pink)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(.black.opacity(0.65)))
                                            .padding(8)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        withAnimation { library.removeProgress(item.manga.slug) }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 28, height: 28)
                                            .background(Circle().fill(.black.opacity(0.6)))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(8)
                                }
                                .overlay(alignment: .bottom) {
                                    GeometryReader { geo in
                                        let progress = item.pageCount > 0 ? Double(item.pageIndex + 1) / Double(item.pageCount) : 0
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.white.opacity(0.2))
                                            Capsule().fill(Theme.gradient).frame(width: geo.size.width * progress)
                                        }
                                        .frame(height: 4)
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                    .padding(10)
                                }
                            Text(item.manga.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("Chapitre \(item.chapterNumber) · \(item.updatedAt.relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 165)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}
