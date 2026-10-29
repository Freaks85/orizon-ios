import SwiftUI

enum SettingsKeys {
    static let animeLanguage = "animeDefaultLanguage"
    static let animeAutoNext = "animeAutoNext"
    static let animeAutoSkip = "animeAutoSkip"
    static let autoDeleteWatched = "autoDeleteWatchedEpisodes"
}

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var episodes: EpisodeDownloads
    @EnvironmentObject private var animeStore: AnimeStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ImagePipeline.cacheLimitKey) private var cacheLimitMB = ImagePipeline.defaultCacheLimitMB
    @AppStorage("autoDeleteReadDownloads") private var autoDeleteRead = false
    @AppStorage(SettingsKeys.animeLanguage) private var animeLanguage = AnimeLanguage.sub.rawValue
    @AppStorage(SettingsKeys.animeAutoNext) private var animeAutoNext = true
    @AppStorage(SettingsKeys.animeAutoSkip) private var animeAutoSkip = false
    @AppStorage(SettingsKeys.autoDeleteWatched) private var autoDeleteWatched = false

    @State private var cacheSize: Int64 = 0
    @State private var confirm: Confirmation?
    @State private var message: String?

    enum Confirmation: Identifiable {
        case deleteDownloads, clearHistory, deleteEpisodes, clearAnimeHistory
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Chapitres téléchargés", value: downloads.totalBytes.fileSize)
                    LabeledContent("Épisodes téléchargés", value: episodes.totalBytes.fileSize)
                    LabeledContent("Cache des images", value: cacheSize.fileSize)
                    Picker("Taille max. du cache", selection: $cacheLimitMB) {
                        Text("250 Mo").tag(250)
                        Text("500 Mo").tag(500)
                        Text("1 Go").tag(1000)
                        Text("2 Go").tag(2000)
                    }
                } header: {
                    Text("Stockage")
                } footer: {
                    Text("Le cache garde les pages déjà vues pour les réafficher vite. Au-delà de la taille max., les images les plus anciennes sont supprimées automatiquement.")
                }

                Section("Nettoyage des mangas") {
                    Button {
                        ImagePipeline.shared.clearDisk()
                        URLCache.shared.removeAllCachedResponses()
                        refreshSizes()
                        message = "Cache vidé."
                    } label: {
                        Label("Vider le cache des images", systemImage: "photo.stack")
                    }
                    Button {
                        let count = downloads.deleteRead { library.isRead($0.chapter.id, slug: $0.manga.slug) }
                        message = count == 0 ? "Aucun chapitre lu à supprimer." : "\(count) chapitre(s) lu(s) supprimé(s)."
                    } label: {
                        Label("Supprimer les chapitres lus téléchargés", systemImage: "eye.slash")
                    }
                    Button {
                        downloads.removeOrphanFolders()
                        ImagePipeline.shared.clearMemory()
                        message = "Fichiers inutiles supprimés."
                    } label: {
                        Label("Nettoyer les fichiers inutiles", systemImage: "sparkles")
                    }
                    Button(role: .destructive) { confirm = .deleteDownloads } label: {
                        Label("Supprimer tous les chapitres téléchargés", systemImage: "trash")
                    }
                    Button(role: .destructive) { confirm = .clearHistory } label: {
                        Label("Effacer l'historique de lecture", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section {
                    Picker(selection: $animeLanguage) {
                        ForEach(AnimeLanguage.allCases) { Text($0.label).tag($0.rawValue) }
                    } label: {
                        Label("Version par défaut", systemImage: "captions.bubble")
                    }
                    Toggle(isOn: $animeAutoNext) {
                        Label("Épisode suivant automatique", systemImage: "forward.end")
                    }
                    .tint(Theme.purple)
                    Toggle(isOn: $animeAutoSkip) {
                        Label("Passer opening, ending et résumé", systemImage: "forward.frame")
                    }
                    .tint(Theme.purple)
                    Toggle(isOn: $autoDeleteWatched) {
                        Label("Supprimer un épisode téléchargé une fois vu", systemImage: "wand.and.stars")
                    }
                    .tint(Theme.purple)
                } header: {
                    Text("Animés")
                } footer: {
                    Text("Les timings d'opening, d'ending et de résumé viennent d'AniSkip et peuvent manquer sur certains épisodes. Un épisode compte comme vu à partir de 90 %.")
                }

                Section("Nettoyage des animés") {
                    Button {
                        let count = episodes.deleteWatched { animeStore.isWatched(animeId: $0.anime.id, episode: $0.episode.number) }
                        message = count == 0 ? "Aucun épisode vu à supprimer." : "\(count) épisode(s) vu(s) supprimé(s)."
                    } label: {
                        Label("Supprimer les épisodes vus téléchargés", systemImage: "eye.slash")
                    }
                    Button(role: .destructive) { confirm = .deleteEpisodes } label: {
                        Label("Supprimer tous les épisodes téléchargés", systemImage: "trash")
                    }
                    Button(role: .destructive) { confirm = .clearAnimeHistory } label: {
                        Label("Effacer l'historique des animés", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section {
                    Toggle(isOn: $autoDeleteRead) {
                        Label("Supprimer un chapitre téléchargé une fois lu", systemImage: "wand.and.stars")
                    }
                    .tint(Theme.purple)
                } header: {
                    Text("Mangas")
                } footer: {
                    Text("Libère de la place au fur et à mesure : un chapitre téléchargé est supprimé quand tu arrives à sa fin.")
                }

                Section("À propos") {
                    LabeledContent("Source", value: "aniverse.fr")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                switch confirm {
                case .deleteDownloads:
                    Button("Tout supprimer (\(downloads.totalBytes.fileSize))", role: .destructive) { downloads.deleteEverything() }
                case .clearHistory:
                    Button("Effacer l'historique", role: .destructive) { library.clearHistory() }
                case .deleteEpisodes:
                    Button("Tout supprimer (\(episodes.totalBytes.fileSize))", role: .destructive) { episodes.deleteEverything() }
                case .clearAnimeHistory:
                    Button("Effacer l'historique", role: .destructive) { animeStore.clearHistory() }
                case nil:
                    EmptyView()
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .onChange(of: cacheLimitMB) { _ in
                Task { @MainActor in
                    await Task.detached(priority: .utility) { ImagePipeline.shared.trimDisk() }.value
                    refreshSizes()
                }
            }
            .task { refreshSizes() }
        }
        .preferredColorScheme(.dark)
    }

    private var confirmTitle: String {
        switch confirm {
        case .deleteDownloads: return "Supprimer tous les chapitres téléchargés ?"
        case .clearHistory: return "Effacer l'historique de lecture ?"
        case .deleteEpisodes: return "Supprimer tous les épisodes téléchargés ?"
        case .clearAnimeHistory: return "Effacer l'historique des animés ?"
        case nil: return ""
        }
    }

    /// Adding up thousands of cached files takes a while: not on the main thread.
    private func refreshSizes() {
        Task { @MainActor in
            cacheSize = await Task.detached(priority: .utility) { ImagePipeline.shared.diskUsage }.value
        }
    }
}
