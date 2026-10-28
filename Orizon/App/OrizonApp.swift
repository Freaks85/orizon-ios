import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let defaultOrientations: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    /// Narrowed to landscape while the video player is open.
    static var orientationLock = defaultOrientations

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

@main
struct OrizonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()
    @StateObject private var downloads = DownloadManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(downloads)
                .environmentObject(EpisodeDownloads.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.pink)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await library.checkForUpdates() }
            case .background:
                library.flush()
            default:
                break
            }
        }
    }
}

enum AppTab: Hashable, CaseIterable {
    case home, search, library, downloads

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .search: return "magnifyingglass"
        case .library: return "books.vertical.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .home: return "Accueil"
        case .search: return "Recherche"
        case .library: return "Bibliothèque"
        case .downloads: return "Téléchargements"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var episodeDownloads: EpisodeDownloads
    @State private var tab: AppTab = .home
    @State private var homeMode: HomeMode = .manga

    var body: some View {
        TabView(selection: $tab) {
            Group {
                if homeMode == .manga {
                    HomeView(mode: $homeMode)
                } else {
                    AnimeHomeView(mode: $homeMode)
                }
            }
            .tag(AppTab.home).toolbar(.hidden, for: .tabBar)
            SearchView().tag(AppTab.search).toolbar(.hidden, for: .tabBar)
            LibraryView().tag(AppTab.library).toolbar(.hidden, for: .tabBar)
            DownloadsView().tag(AppTab.downloads).toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: $tab, badges: [
                .library: library.newChapterCount,
                .downloads: downloads.jobs.count + episodeDownloads.jobs.count
            ])
        }
        .background(Theme.background)
    }
}

/// Floating pill-shaped tab bar, in the style of aniverse.fr's mobile navigation.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var badges: [AppTab: Int]
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    if selection != tab {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                    }
                } label: {
                    ZStack {
                        if selection == tab {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .matchedGeometryEffect(id: "tab", in: highlight)
                        }
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selection == tab ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.55)))
                            .overlay(alignment: .topTrailing) {
                                if let count = badges[tab], count > 0 {
                                    Text(count > 99 ? "99+" : "\(count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.purple))
                                        .offset(x: 12, y: -8)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.background.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
    }
}
