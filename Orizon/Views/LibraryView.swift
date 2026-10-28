import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    enum Tab: String, CaseIterable, Identifiable {
        case library = "Ma liste"
        case updates = "Nouveautés"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .library
    @State private var reader: ReaderContext?

    private let columns = [GridItem(.adaptive(minimum: 105, maximum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab == .updates && library.newChapterCount > 0 ? "\(tab.rawValue) (\(library.newChapterCount))" : tab.rawValue)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                switch tab {
                case .library: libraryGrid
                case .updates: updatesList
                }
            }
            .background(Theme.background)
            .navigationTitle("Bibliothèque")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if library.isCheckingUpdates {
                        ProgressView().tint(Theme.pink)
                    } else {
                        Button { Task { await library.checkForUpdates() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .navigationDestination(for: MangaSummary.self) { MangaDetailView(manga: $0) }
            .fullScreenCover(item: $reader) { ReaderView(context: $0) }
        }
    }

    @ViewBuilder
    private var libraryGrid: some View {
        if library.entries.isEmpty {
            emptyState(icon: "bookmark", text: "Ta liste est vide.\nAjoute des mangas depuis leur fiche avec le bouton « Ajouter ».")
        } else {
            ScrollView {
                if let error = library.lastUpdateError {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.entries) { entry in
                        NavigationLink(value: entry.manga) {
                            MangaCard(manga: entry.manga, badge: entry.newChapterIds.count, caption: caption(for: entry))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                let unread = entry.chapters.filter { !library.isRead($0.id, slug: entry.manga.slug) }
                                downloads.enqueue(unread, manga: entry.manga)
                            } label: {
                                Label("Télécharger les non lus", systemImage: "arrow.down.circle")
                            }
                            if !entry.newChapterIds.isEmpty {
                                Button { library.clearNew(slug: entry.manga.slug) } label: {
                                    Label("Effacer les nouveautés", systemImage: "checkmark")
                                }
                            }
                            Button(role: .destructive) { library.remove(entry.manga.slug) } label: {
                                Label("Retirer de ma liste", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
                .padding()
            }
            .refreshable { await library.checkForUpdates() }
        }
    }

    private func caption(for entry: LibraryEntry) -> String? {
        if let progress = library.progress(for: entry.manga.slug) {
            return "Ch. \(progress.chapterNumber) en cours"
        }
        if let latest = entry.chapters.first {
            return "\(entry.chapters.count) ch. · dernier \(latest.number)"
        }
        return nil
    }

    @ViewBuilder
    private var updatesList: some View {
        let items = library.newChapters
        if items.isEmpty {
            emptyState(icon: "sparkles", text: "Aucun nouveau chapitre.\nTire vers le bas pour vérifier.")
                .refreshable { await library.checkForUpdates() }
        } else {
            List {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        MangaCover(url: item.manga.cover, cornerRadius: 6)
                            .frame(width: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.manga.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(item.chapter.displayName)
                                .font(.footnote)
                                .foregroundStyle(Theme.pink)
                                .lineLimit(1)
                            if let date = item.chapter.date {
                                Text(date.relative).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if downloads.isDownloaded(item.chapter.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.pink)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let entry = library.entry(item.manga.slug) {
                            reader = ReaderContext(manga: item.manga, chapters: entry.chapters, startChapterId: item.chapter.id)
                        }
                    }
                    .swipeActions {
                        Button { downloads.enqueue([item.chapter], manga: item.manga) } label: {
                            Label("Télécharger", systemImage: "arrow.down")
                        }
                        .tint(Theme.purple)
                        Button { library.setRead(true, chapterIds: [item.chapter.id], slug: item.manga.slug) } label: {
                            Label("Lu", systemImage: "eye")
                        }
                        .tint(Theme.pink)
                    }
                    .listRowBackground(Theme.background)
                }
                Section {
                    Button("Tout télécharger") {
                        for group in Dictionary(grouping: items, by: { $0.manga.slug }).values {
                            if let manga = group.first?.manga {
                                downloads.enqueue(group.map(\.chapter), manga: manga)
                            }
                        }
                    }
                    Button("Tout marquer comme vu", role: .destructive) { library.clearAllNew() }
                }
                .listRowBackground(Theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await library.checkForUpdates() }
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
        }
    }
}
