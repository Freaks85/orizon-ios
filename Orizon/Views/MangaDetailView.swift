import SwiftUI

struct MangaDetailView: View {
    let manga: MangaSummary

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    @State private var details: MangaDetails?
    @State private var chapters: [Chapter] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var expanded = false
    @State private var newestFirst = true
    @State private var reader: ReaderContext?

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error, chapters.isEmpty {
                ErrorView(message: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            } else if isLoading && chapters.isEmpty {
                ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
                    .listRowBackground(Color.clear)
            }

            if !chapters.isEmpty {
                Section {
                    ForEach(sortedChapters) { chapter in
                        ChapterRow(manga: summary, chapter: chapter)
                            .contentShape(Rectangle())
                            .onTapGesture { open(chapter) }
                            .listRowBackground(Theme.background)
                            .swipeActions(edge: .trailing) {
                                downloadSwipe(chapter)
                            }
                            .swipeActions(edge: .leading) {
                                readSwipe(chapter)
                            }
                            .contextMenu { chapterMenu(chapter) }
                    }
                } header: {
                    HStack {
                        Text("\(chapters.count) chapitres")
                        Spacer()
                        Button {
                            newestFirst.toggle()
                        } label: {
                            Label(newestFirst ? "Plus récents" : "Plus anciens", systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        downloads.enqueue(chapters.filter { !library.isRead($0.id, slug: manga.slug) }, manga: summary)
                    } label: { Label("Télécharger les non lus", systemImage: "arrow.down.circle") }
                    Button {
                        downloads.enqueue(chapters, manga: summary)
                    } label: { Label("Tout télécharger", systemImage: "arrow.down.to.line.circle") }
                    Divider()
                    Button {
                        library.setRead(true, chapterIds: chapters.map(\.id), slug: manga.slug)
                    } label: { Label("Tout marquer comme lu", systemImage: "eye") }
                    Button {
                        library.setRead(false, chapterIds: chapters.map(\.id), slug: manga.slug)
                    } label: { Label("Tout marquer comme non lu", systemImage: "eye.slash") }
                    if let url = URL(string: "https://aniverse.fr/manga/\(manga.slug)") {
                        Divider()
                        ShareLink(item: url) { Label("Partager", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(chapters.isEmpty)
            }
        }
        .refreshable { await load() }
        .task { if details == nil { await load() } }
        .fullScreenCover(item: $reader) { ReaderView(context: $0) }
    }

    private var summary: MangaSummary {
        var s = details?.summary ?? manga
        if s.cover == nil { s.cover = manga.cover }
        return s
    }

    private var sortedChapters: [Chapter] {
        newestFirst ? chapters : chapters.reversed()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: details?.banner ?? summary.cover)
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                    .blur(radius: details?.banner == nil ? 24 : 0)
                    .clipped()
                    .overlay(
                        LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
                    )

                HStack(alignment: .bottom, spacing: 14) {
                    MangaCover(url: summary.cover, cornerRadius: 10)
                        .frame(width: 115)
                        .shadow(color: .black.opacity(0.5), radius: 12)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title)
                            .font(.title3.weight(.bold))
                            .lineLimit(3)
                        if let details {
                            if !details.authors.isEmpty {
                                Text(details.authors.joined(separator: ", "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(details.status == "En cours" ? Color.green : Theme.pink)
                                    .frame(width: 7, height: 7)
                                Text(details.status).font(.caption.weight(.medium))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .offset(y: 40)
            }
            .padding(.bottom, 40)

            actionButtons.padding(.horizontal)

            if let details {
                if !details.genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(details.genres, id: \.self) { genre in
                                Text(genre)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.surfaceHigh))
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if !details.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 4)
                        Button(expanded ? "Moins" : "Plus") {
                            withAnimation { expanded.toggle() }
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.pink)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                if let chapter = continueChapter {
                    let progress = library.progress(for: manga.slug)
                    let page = progress?.chapterId == chapter.id ? (progress?.pageIndex ?? 0) : 0
                    reader = ReaderContext(manga: summary, chapters: chapters, startChapterId: chapter.id, startPage: page)
                }
            } label: {
                Label(continueLabel, systemImage: "book.fill")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(continueChapter == nil)

            Button {
                library.toggle(summary, chapters: chapters)
            } label: {
                Label(library.contains(manga.slug) ? "Dans ma liste" : "Ajouter",
                      systemImage: library.contains(manga.slug) ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(PillButtonStyle(prominent: false))
        }
    }

    /// The chapter in progress, else the first unread one (oldest first), else the first chapter.
    private var continueChapter: Chapter? {
        if let progress = library.progress(for: manga.slug),
           let chapter = chapters.first(where: { $0.id == progress.chapterId }) {
            if progress.pageIndex < progress.pageCount - 1 { return chapter }
            if let index = chapters.firstIndex(of: chapter), index > 0 { return chapters[index - 1] }
            return chapter
        }
        return chapters.reversed().first { !library.isRead($0.id, slug: manga.slug) } ?? chapters.last
    }

    private var continueLabel: String {
        guard let chapter = continueChapter else { return "Lire" }
        if library.progress(for: manga.slug) != nil || chapters.contains(where: { library.isRead($0.id, slug: manga.slug) }) {
            return "Reprendre ch. \(chapter.number)"
        }
        return "Commencer"
    }

    // MARK: - Chapter actions

    private func open(_ chapter: Chapter) {
        guard !chapter.isPremium || downloads.isDownloaded(chapter.id) else { return }
        let progress = library.progress(for: manga.slug)
        let page = progress?.chapterId == chapter.id ? (progress?.pageIndex ?? 0) : 0
        reader = ReaderContext(manga: summary, chapters: chapters, startChapterId: chapter.id, startPage: page)
    }

    @ViewBuilder
    private func downloadSwipe(_ chapter: Chapter) -> some View {
        if downloads.isDownloaded(chapter.id) {
            Button(role: .destructive) { downloads.delete(chapter.id) } label: {
                Label("Supprimer", systemImage: "trash")
            }
        } else if downloads.job(for: chapter.id) != nil {
            Button { downloads.cancel(chapter.id) } label: {
                Label("Annuler", systemImage: "xmark")
            }
        } else if !chapter.isPremium {
            Button { downloads.enqueue([chapter], manga: summary) } label: {
                Label("Télécharger", systemImage: "arrow.down")
            }
            .tint(Theme.purple)
        }
    }

    @ViewBuilder
    private func readSwipe(_ chapter: Chapter) -> some View {
        let read = library.isRead(chapter.id, slug: manga.slug)
        Button {
            library.setRead(!read, chapterIds: [chapter.id], slug: manga.slug)
        } label: {
            Label(read ? "Non lu" : "Lu", systemImage: read ? "eye.slash" : "eye")
        }
        .tint(Theme.pink)
    }

    @ViewBuilder
    private func chapterMenu(_ chapter: Chapter) -> some View {
        let read = library.isRead(chapter.id, slug: manga.slug)
        Button {
            library.setRead(!read, chapterIds: [chapter.id], slug: manga.slug)
        } label: { Label(read ? "Marquer comme non lu" : "Marquer comme lu", systemImage: read ? "eye.slash" : "eye") }
        Button {
            let older = chapters.filter { $0.numberValue <= chapter.numberValue }.map(\.id)
            library.setRead(true, chapterIds: older, slug: manga.slug)
        } label: { Label("Marquer les précédents comme lus", systemImage: "eye.circle") }
        Divider()
        if downloads.isDownloaded(chapter.id) {
            Button(role: .destructive) { downloads.delete(chapter.id) } label: { Label("Supprimer le téléchargement", systemImage: "trash") }
        } else if !chapter.isPremium {
            Button { downloads.enqueue([chapter], manga: summary) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
            Button {
                let next = chapters.filter { $0.numberValue >= chapter.numberValue }.sorted { $0.numberValue < $1.numberValue }.prefix(10)
                downloads.enqueue(Array(next), manga: summary)
            } label: { Label("Télécharger les 10 suivants", systemImage: "arrow.down.to.line") }
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        error = nil
        do {
            let (details, chapters) = try await AniverseAPI.shared.manga(slug: manga.slug)
            self.details = details
            self.chapters = chapters
            if library.contains(manga.slug) {
                library.merge(chapters: chapters, for: details.summary)
            }
        } catch {
            self.error = error.localizedDescription
            // Offline fallback: chapters cached in the library.
            if chapters.isEmpty, let entry = library.entry(manga.slug) {
                chapters = entry.chapters
            }
        }
        isLoading = false
    }
}

struct ChapterRow: View {
    let manga: MangaSummary
    let chapter: Chapter

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        let read = library.isRead(chapter.id, slug: manga.slug)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if library.isNew(chapter.id, slug: manga.slug) {
                        Circle().fill(Theme.gradient).frame(width: 8, height: 8)
                    }
                    if chapter.isPremium {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(chapter.displayName)
                        .font(.subheadline.weight(read ? .regular : .semibold))
                        .foregroundStyle(read ? .secondary : .primary)
                        .lineLimit(1)
                }
                if let date = chapter.date {
                    Text(date.relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            downloadIndicator
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        if downloads.isDownloaded(chapter.id) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.pink)
        } else if let job = downloads.job(for: chapter.id) {
            switch job.state {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .running:
                ProgressView(value: job.progress)
                    .progressViewStyle(.circular)
                    .tint(Theme.pink)
                    .frame(width: 22, height: 22)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else if !chapter.isPremium {
            Button {
                downloads.enqueue([chapter], manga: manga)
            } label: {
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }
}
