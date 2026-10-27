import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = ImagePipeline.shared.diskUsage

    var body: some View {
        NavigationStack {
            List {
                Section("Stockage") {
                    LabeledContent("Téléchargements", value: downloads.totalBytes.fileSize)
                    LabeledContent("Cache des images", value: cacheSize.fileSize)
                    Button("Vider le cache des images", role: .destructive) {
                        ImagePipeline.shared.clearDisk()
                        cacheSize = ImagePipeline.shared.diskUsage
                    }
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
        }
        .preferredColorScheme(.dark)
    }
}
