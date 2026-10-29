import SwiftUI

struct DownloadsView: View {
    var mode: HomeMode = .manga
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var episodes: EpisodeDownloads
    @State private var reader: ReaderContext?
    @State private var player: PlayerContext?
    @State private var confirmDeleteAll = false
    @State private var deletedMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if mode == .manga && !downloads.jobs.isEmpty {
                    Section {
                        ForEach(downloads.jobs) { job in
                            JobRow(job: job, progress: downloads.progress)
                                .swipeActions {
                                    Button(role: .destructive) { downloads.cancel(job.id) } label: {
                                        Label("Annuler", systemImage: "xmark")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("En cours (\(downloads.jobs.count))")
                            Spacer()
                            if downloads.jobs.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
                                Button("Réessayer") { downloads.retryFailed() }
                            }
                            Button("Tout annuler", role: .destructive) { downloads.cancelAll() }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                    .listRowBackground(Theme.surface)
                }

                if mode == .anime && !episodes.jobs.isEmpty {
                    Section {
                        ForEach(episodes.jobs) { job in
                            EpisodeJobRow(job: job, progress: episodes.progress)
                                .swipeActions {
                                    Button(role: .destructive) { episodes.cancel(job.id) } label: {
                                        Label("Annuler", systemImage: "xmark")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Épisodes en cours (\(episodes.jobs.count))")
                            Spacer()
                            if episodes.jobs.contains(where: { $0.error != nil }) {
                                Button("Réessayer") { episodes.retryFailed() }
                            }
                            Button("Tout annuler", role: .destructive) { episodes.cancelAll() }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                    .listRowBackground(Theme.surface)
                }

                ForEach(mode == .anime ? episodes.byAnime : []) { group in
                    Section {
                        ForEach(group.episodes) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Épisode \(item.episode.number) · \(item.language.label)")
                                        .font(.subheadline)
                                    Text(item.byteCount.fileSize)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Theme.gradient)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let sameVersion = group.episodes.filter { $0.language == item.language }.map(\.episode)
                                player = PlayerContext(anime: group.anime, series: group.anime, episodes: sameVersion, language: item.language, startEpisode: item.episode.number)
                            }
                            .swipeActions {
                                Button(role: .destructive) { episodes.delete(item.id) } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 10) {
                            MangaCover(url: group.anime.cover, cornerRadius: 4).frame(width: 28)
                            Text(group.anime.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Menu {
                                Button(role: .destructive) { episodes.deleteAll(animeId: group.anime.id) } label: {
                                    Label("Tout supprimer", systemImage: "trash")
                                }
                            } label: { Image(systemName: "ellipsis") }
                        }
                        .textCase(nil)
                        .foregroundStyle(.primary)
                    }
                    .listRowBackground(Theme.surface)
                }

                ForEach(mode == .manga ? downloads.downloadedByManga : []) { group in
                    Section {
                        ForEach(group.chapters) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.chapter.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(library.isRead(item.chapter.id, slug: group.manga.slug) ? .secondary : .primary)
                                    Text("\(item.pages.count) pages · \(item.byteCount.fileSize)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let chapters = library.entry(group.manga.slug)?.chapters ?? group.chapters.map(\.chapter)
                                reader = ReaderContext(manga: group.manga, chapters: chapters, startChapterId: item.chapter.id)
                            }
                            .swipeActions {
                                Button(role: .destructive) { downloads.delete(item.chapter.id) } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack(spacing: 10) {
                            MangaCover(url: group.manga.cover, cornerRadius: 4).frame(width: 28)
                            Text(group.manga.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Menu {
                                Button(role: .destructive) { downloads.deleteAll(slug: group.manga.slug) } label: {
                                    Label("Tout supprimer", systemImage: "trash")
                                }
                            } label: { Image(systemName: "ellipsis") }
                        }
                        .textCase(nil)
                        .foregroundStyle(.primary)
                    }
                    .listRowBackground(Theme.surface)
                }

                if isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.gradient)
                        Text(mode == .manga
                             ? "Aucun chapitre téléchargé.\nGlisse un chapitre vers la gauche ou utilise le menu « … » d'un manga."
                             : "Aucun épisode téléchargé.\nTouche la flèche d'un épisode ou celle en haut de la fiche d'un animé.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.insetGrouped)
            .fullScreenCover(item: $player) { AnimePlayerView(context: $0) }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Téléchargements")
            .toolbar {
                if totalBytes > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(totalBytes.fileSize).font(.caption).foregroundStyle(.secondary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if mode == .manga {
                            Button {
                                let count = downloads.deleteRead { library.isRead($0.chapter.id, slug: $0.manga.slug) }
                                deletedMessage = count == 0 ? "Aucun chapitre lu à supprimer." : "\(count) chapitre(s) lu(s) supprimé(s)."
                            } label: {
                                Label("Supprimer les chapitres lus", systemImage: "eye.slash")
                            }
                            }
                            Button(role: .destructive) { confirmDeleteAll = true } label: {
                                Label("Tout supprimer", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .confirmationDialog("Supprimer tous les téléchargements ?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Tout supprimer (\(totalBytes.fileSize))", role: .destructive) {
                    if mode == .manga { downloads.deleteEverything() } else { episodes.deleteEverything() }
                }
            }
            .alert(deletedMessage ?? "", isPresented: Binding(get: { deletedMessage != nil }, set: { if !$0 { deletedMessage = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .fullScreenCover(item: $reader) { ReaderView(context: $0) }
        }
    }

    private var isEmpty: Bool {
        mode == .manga ? downloads.jobs.isEmpty && downloads.downloaded.isEmpty : episodes.jobs.isEmpty && episodes.downloaded.isEmpty
    }

    private var totalBytes: Int64 { mode == .manga ? downloads.totalBytes : episodes.totalBytes }
}

struct JobRow: View {
    let job: DownloadJob
    @ObservedObject var progress: DownloadProgress

    var body: some View {
        HStack(spacing: 12) {
            MangaCover(url: job.manga.cover, cornerRadius: 4).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.manga.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(job.chapter.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch job.state {
                case .queued:
                    Text("En attente").font(.caption2).foregroundStyle(.tertiary)
                case .running:
                    let value = progress.values[job.id]
                    ProgressView(value: value?.fraction ?? 0)
                        .tint(Theme.pink)
                    Text(value.map { $0.total > 0 ? "\($0.done) / \($0.total) pages" : "Préparation…" } ?? "Préparation…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }
}

struct EpisodeJobRow: View {
    let job: EpisodeDownloads.Job
    @ObservedObject var progress: DownloadProgress

    var body: some View {
        HStack(spacing: 12) {
            MangaCover(url: job.anime.cover, cornerRadius: 4).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.anime.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text("Épisode \(job.episode.number) · \(job.language.label)").font(.caption).foregroundStyle(.secondary)
                if let error = job.error {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                } else if let fraction = progress.values[job.id]?.fraction, fraction > 0 {
                    ProgressView(value: fraction).tint(Theme.pink)
                    Text("\(Int(fraction * 100)) %").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("En attente").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
