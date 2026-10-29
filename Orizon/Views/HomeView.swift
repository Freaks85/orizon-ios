import SwiftUI

struct ReaderContext: Identifiable {
    let manga: MangaSummary
    /// Chapters sorted newest first, as shown in the details screen.
    let chapters: [Chapter]
    let startChapterId: String
    let startPage: Int
    let startOffset: Double
    /// Chapters oldest first, and each one's position in it: computed once when the reader opens,
    /// the reader looks up the previous/next chapter on every page change.
    let readingOrder: [Chapter]
    private let positions: [String: Int]

    var id: String { startChapterId }

    init(manga: MangaSummary, chapters: [Chapter], startChapterId: String, startPage: Int = 0, startOffset: Double = 0) {
        self.manga = manga
        self.chapters = chapters
        self.startChapterId = startChapterId
        self.startPage = startPage
        self.startOffset = startOffset
        // numberValue parses a string: parse each number once, not once per comparison.
        readingOrder = chapters.map { ($0, $0.numberValue) }.sorted { $0.1 < $1.1 }.map { $0.0 }
        positions = Dictionary(readingOrder.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func chapter(_ id: String) -> Chapter? {
        positions[id].map { readingOrder[$0] }
    }

    func chapter(after chapter: Chapter) -> Chapter? {
        guard let index = positions[chapter.id], index + 1 < readingOrder.count else { return nil }
        return readingOrder[index + 1]
    }

    func chapter(before chapter: Chapter) -> Chapter? {
        guard let index = positions[chapter.id], index > 0 else { return nil }
        return readingOrder[index - 1]
    }
}

@MainActor
final class HomeModel: ObservableObject {
    @Published var popular: [MangaSummary] = []
    @Published var error: String?

    func load() async {
        error = nil
        do {
            popular = try await AniverseAPI.shared.search(sort: .popularity, page: 1).items
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HomeView: View {
    @Binding var mode: HomeMode
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = HomeModel()
    @StateObject private var releases = PagedLoader<MangaSummary> { try await AniverseAPI.shared.latest(page: $0) }
    @State private var showSettings = false
    @State private var reader: ReaderContext?
    @State private var openingChapter: String?
    @State private var openError: String?

    private let releaseColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 34) {
                    if !model.popular.isEmpty {
                        HeroCarousel(mangas: Array(model.popular.prefix(8)))
                    } else {
                        Color.clear.frame(height: 110)
                    }

                    if !library.continueReading.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Historique")
                            HistoryRow(items: Array(library.continueReading.prefix(15)))
                        }
                    }

                    if !model.popular.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Populaires") {
                                NavigationLink {
                                    PagedGridScreen(title: "Populaires") { try await AniverseAPI.shared.search(sort: .popularity, page: $0) }
                                } label: {
                                    Text("Tout voir").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.pink)
                                }
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(Array(model.popular.prefix(20).enumerated()), id: \.element.id) { index, manga in
                                        TrendCard(manga: manga, rank: index + 1)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    genresRow

                    releasesSection

                    if let error = model.error, model.popular.isEmpty, releases.items.isEmpty {
                        ErrorView(message: error) { Task { await reload() } }
                    }
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
            .task {
                if model.popular.isEmpty { await model.load() }
                if releases.items.isEmpty { await releases.loadMore() }
            }
        }
    }

    private func reload() async {
        releases.reset { try await AniverseAPI.shared.latest(page: $0) }
        async let popular: Void = model.load()
        async let latest: Void = releases.loadMore()
        _ = await (popular, latest)
    }

    private var releasesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Sorties récentes")
                Text("Triés par date de sortie du dernier chapitre.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            LazyVGrid(columns: releaseColumns, alignment: .leading, spacing: 26) {
                ForEach(releases.items) { manga in
                    ReleaseCard(manga: manga) { open($0, of: manga) }
                        .task { await releases.loadMoreIfNeeded(current: manga) }
                }
            }
            .padding(.horizontal)

            if releases.isLoading {
                ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
            } else if let error = releases.error {
                ErrorView(message: error) { Task { await releases.loadMore() } }
            }
        }
    }

    private var genresRow: some View {
        VStack(alignment: .leading, spacing: 14) {
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
}

/// All recently updated mangas as release cards, with infinite scrolling.
struct ReleasesScreen: View {
    @StateObject private var loader = PagedLoader<MangaSummary> { try await AniverseAPI.shared.latest(page: $0) }
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
            Image("LogoMark")
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
/// Tapping a card goes straight back into the reader, at the saved chapter and page.
struct HistoryRow: View {
    let items: [ReadingProgress]
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @State private var reader: ReaderContext?
    @State private var opening: String?
    @State private var error: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items, id: \.manga.slug) { item in
                    Button { resume(item) } label: {
                        HistoryCard(item: item)
                            .overlay {
                                if opening == item.manga.slug {
                                    ProgressView().tint(Theme.pink)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        NavigationLink(value: item.manga) {
                            Label("Voir la fiche du manga", systemImage: "info.circle")
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .fullScreenCover(item: $reader) { ReaderView(context: $0) }
        .alert("Impossible de reprendre la lecture", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func resume(_ item: ReadingProgress) {
        guard opening == nil else { return }
        let slug = item.manga.slug
        // Chapters known locally (library, downloads) open instantly, even offline.
        var chapters = library.entry(slug)?.chapters ?? []
        if !chapters.contains(where: { $0.id == item.chapterId }) {
            chapters = downloads.downloaded.values.filter { $0.manga.slug == slug }.map(\.chapter)
        }
        if chapters.contains(where: { $0.id == item.chapterId }) {
            reader = ReaderContext(manga: item.manga, chapters: chapters, startChapterId: item.chapterId, startPage: item.pageIndex, startOffset: item.pageOffset ?? 0)
            return
        }
        opening = slug
        Task {
            defer { opening = nil }
            do {
                let fresh = try await AniverseAPI.shared.chapters(slug: slug)
                reader = ReaderContext(manga: item.manga, chapters: fresh, startChapterId: item.chapterId, startPage: item.pageIndex, startOffset: item.pageOffset ?? 0)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct HistoryCard: View {
    let item: ReadingProgress
    @EnvironmentObject private var library: LibraryStore

    private var progress: Double {
        item.pageCount > 0 ? Double(item.pageIndex + 1) / Double(item.pageCount) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .frame(height: 120)
                .overlay { RemoteImage(url: item.manga.banner ?? item.manga.cover) }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let status = item.manga.status {
                        StatusBadge(status: status).padding(8)
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

            HStack {
                Text("Chapitre \(item.chapterNumber)")
                Spacer()
                Text("Page \(item.pageIndex + 1) sur \(item.pageCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(item.manga.title)
                .font(.system(size: 19, weight: .heavy))
                .fontWidth(.condensed)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Progression de lecture")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Ch. \(item.chapterNumber)")
                        .fontWeight(.semibold)
                }
                .font(.caption)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Theme.gradient).frame(width: max(6, geo.size.width * progress))
                    }
                }
                .frame(height: 6)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        }
        .frame(width: 200)
    }
}
