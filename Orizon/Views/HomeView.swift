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
    @State private var reader: ReaderContext?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !model.popular.isEmpty {
                        FeaturedCarousel(mangas: Array(model.popular.prefix(8)))
                    }

                    if !library.continueReading.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Reprendre la lecture")
                            ContinueReadingRow(items: Array(library.continueReading.prefix(12)))
                        }
                    }

                    section("Sorties récentes", items: model.latest) {
                        PagedGridScreen(title: "Sorties récentes") { try await AniverseAPI.shared.latest(page: $0) }
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
                .padding(.vertical)
            }
            .background(Theme.background)
            .refreshable { await model.load() }
            .navigationTitle("Aniverse")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: MangaSummary.self) { MangaDetailView(manga: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { if model.latest.isEmpty { await model.load() } }
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

struct FeaturedCarousel: View {
    let mangas: [MangaSummary]

    var body: some View {
        TabView {
            ForEach(mangas) { manga in
                NavigationLink(value: manga) {
                    ZStack(alignment: .bottomLeading) {
                        RemoteImage(url: manga.cover)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .blur(radius: 18)
                            .overlay(Color.black.opacity(0.35))
                            .clipped()
                        HStack(alignment: .bottom, spacing: 14) {
                            MangaCover(url: manga.cover, cornerRadius: 10)
                                .frame(width: 105)
                                .shadow(radius: 10)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("POPULAIRE")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(Theme.pink)
                                Text(manga.title)
                                    .font(.title3.weight(.bold))
                                    .lineLimit(3)
                                    .foregroundStyle(.white)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: 210)
    }
}

struct ContinueReadingRow: View {
    let items: [ReadingProgress]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items, id: \.manga.slug) { item in
                    NavigationLink(value: item.manga) {
                        VStack(alignment: .leading, spacing: 6) {
                            MangaCover(url: item.manga.cover)
                                .overlay(alignment: .bottom) {
                                    GeometryReader { geo in
                                        let progress = item.pageCount > 0 ? Double(item.pageIndex + 1) / Double(item.pageCount) : 0
                                        Capsule()
                                            .fill(Theme.gradient)
                                            .frame(width: geo.size.width * progress, height: 4)
                                            .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                    .padding(6)
                                }
                            Text(item.manga.title)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                            Text("Chapitre \(item.chapterNumber)")
                                .font(.caption2)
                                .foregroundStyle(Theme.pink)
                        }
                        .frame(width: 118)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }
}
