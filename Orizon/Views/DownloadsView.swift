import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @State private var reader: ReaderContext?

    var body: some View {
        NavigationStack {
            List {
                if !downloads.jobs.isEmpty {
                    Section {
                        ForEach(downloads.jobs) { job in
                            JobRow(job: job)
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

                ForEach(downloads.downloadedByManga) { group in
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

                if downloads.jobs.isEmpty && downloads.downloaded.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.gradient)
                        Text("Aucun téléchargement.\nGlisse un chapitre vers la gauche ou utilise le menu « … » d'un manga.")
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
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Téléchargements")
            .toolbar {
                if !downloads.downloaded.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(downloads.totalBytes.fileSize).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .fullScreenCover(item: $reader) { ReaderView(context: $0) }
        }
    }
}

struct JobRow: View {
    let job: DownloadJob

    var body: some View {
        HStack(spacing: 12) {
            MangaCover(url: job.manga.cover, cornerRadius: 4).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.manga.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(job.chapter.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch job.state {
                case .queued:
                    Text("En attente").font(.caption2).foregroundStyle(.tertiary)
                case .running(let done, let total):
                    ProgressView(value: job.progress)
                        .tint(Theme.pink)
                    Text(total > 0 ? "\(done) / \(total) pages" : "Préparation…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .failed(let message):
                    Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }
}
