import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ImagePipeline.cacheLimitKey) private var cacheLimitMB = ImagePipeline.defaultCacheLimitMB
    @AppStorage("autoDeleteReadDownloads") private var autoDeleteRead = false

    @State private var cacheSize: Int64 = 0
    @State private var confirm: Confirmation?
    @State private var message: String?

    enum Confirmation: Identifiable {
        case deleteDownloads, clearHistory
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Téléchargements", value: downloads.totalBytes.fileSize)
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

                Section("Nettoyage") {
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
                        Label("Supprimer tous les téléchargements", systemImage: "trash")
                    }
                    Button(role: .destructive) { confirm = .clearHistory } label: {
                        Label("Effacer l'historique de lecture", systemImage: "clock.arrow.circlepath")
                    }
                }

                Section {
                    Toggle(isOn: $autoDeleteRead) {
                        Label("Supprimer un chapitre téléchargé une fois lu", systemImage: "wand.and.stars")
                    }
                    .tint(Theme.purple)
                } header: {
                    Text("Automatique")
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
                case nil:
                    EmptyView()
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .onChange(of: cacheLimitMB) { _ in
                Task.detached(priority: .utility) {
                    ImagePipeline.shared.trimDisk()
                    await MainActor.run { refreshSizes() }
                }
            }
            .task { refreshSizes() }
        }
        .preferredColorScheme(.dark)
    }

    private var confirmTitle: String {
        switch confirm {
        case .deleteDownloads: return "Supprimer tous les téléchargements ?"
        case .clearHistory: return "Effacer l'historique de lecture ?"
        case nil: return ""
        }
    }

    private func refreshSizes() {
        cacheSize = ImagePipeline.shared.diskUsage
    }
}
