import SwiftUI

@main
struct OrizonApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var downloads = DownloadManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
                .tint(Theme.pink)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await library.checkForUpdates() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Accueil", systemImage: "house.fill") }
            SearchView()
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
            LibraryView()
                .tabItem { Label("Bibliothèque", systemImage: "books.vertical.fill") }
                .badge(library.newChapterCount)
            DownloadsView()
                .tabItem { Label("Téléchargements", systemImage: "arrow.down.circle.fill") }
                .badge(downloads.jobs.count)
        }
        .background(Theme.background)
    }
}
