import AVKit
import SwiftUI

enum HomeMode: CaseIterable {
    case manga, anime

    var label: String { self == .manga ? "Manga" : "Animé" }
}

/// Manga / Animé switch shown at the top of the home screen.
struct HomeModeSwitch: View {
    @Binding var mode: HomeMode
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HomeMode.allCases, id: \.self) { item in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { mode = item }
                } label: {
                    Text(item.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(mode == item ? 1 : 0.6))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if mode == item {
                                Capsule().fill(Theme.gradient).matchedGeometryEffect(id: "mode", in: highlight)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

struct AnimeHomeView: View {
    @Binding var mode: HomeMode
    @StateObject private var popular = PagedLoader<Anime> { try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0) }
    @StateObject private var newest = PagedLoader<Anime> { try await AniverseAPI.shared.animeSearch(sort: .newest, page: $0) }
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !popular.items.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Populaires")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(popular.items.prefix(20)) { anime in
                                        NavigationLink(value: anime) { AnimeCard(anime: anime).frame(width: 140) }
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Nouveautés")
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(newest.items) { anime in
                                NavigationLink(value: anime) { AnimeCard(anime: anime) }
                                    .buttonStyle(.plain)
                                    .task { await newest.loadMoreIfNeeded(current: anime) }
                            }
                        }
                        .padding(.horizontal)

                        if newest.isLoading {
                            ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
                        } else if let error = newest.error ?? popular.error {
                            ErrorView(message: error) { Task { await reload() } }
                        }
                    }
                }
                .padding(.vertical)
                .padding(.bottom, 30)
            }
            .background(Theme.background)
            .refreshable { await reload() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Logo() }
                ToolbarItem(placement: .principal) { HomeModeSwitch(mode: $mode) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                }
            }
            .navigationDestination(for: Anime.self) { AnimeDetailView(anime: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task {
                if popular.items.isEmpty { await popular.loadMore() }
                if newest.items.isEmpty { await newest.loadMore() }
            }
        }
    }

    private func reload() async {
        popular.reset { try await AniverseAPI.shared.animeSearch(sort: .popularity, page: $0) }
        newest.reset { try await AniverseAPI.shared.animeSearch(sort: .newest, page: $0) }
        async let a: Void = popular.loadMore()
        async let b: Void = newest.loadMore()
        _ = await (a, b)
    }
}

struct AnimeCard: View {
    let anime: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MangaCover(url: anime.cover)
                .overlay(alignment: .topLeading) {
                    if let status = anime.status {
                        StatusBadge(status: status).padding(6)
                    }
                }
            Text(anime.title)
                .font(.footnote.weight(.bold))
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
            Text(anime.versions)
                .font(.caption2)
                .foregroundStyle(Theme.pink)
                .lineLimit(1)
        }
    }
}

struct AnimeDetailView: View {
    let anime: Anime
    @State private var episodes: [Episode] = []
    @State private var subCount: Int
    @State private var dubCount: Int
    @State private var language: AnimeLanguage
    @State private var error: String?
    @State private var opening: Int?
    @State private var playError: String?

    init(anime: Anime) {
        self.anime = anime
        _subCount = State(initialValue: anime.subCount)
        _dubCount = State(initialValue: anime.dubCount)
        _language = State(initialValue: anime.subCount == 0 && anime.dubCount > 0 ? .dub : .sub)
    }

    private var available: [Episode] {
        let count = language == .sub ? subCount : dubCount
        return episodes.filter { $0.number <= count }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Color.clear
                    .frame(height: 260)
                    .overlay { RemoteImage(url: anime.banner ?? anime.cover) }
                    .clipped()
                    .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 12) {
                    Text(anime.title)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    let tags = [anime.format, anime.status].compactMap { $0 }
                    if !tags.isEmpty {
                        Text(tags.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let synopsis = anime.synopsis {
                        Text(synopsis)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Picker("Version", selection: $language) {
                        ForEach(AnimeLanguage.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 6)
                    Text("Épisodes")
                        .font(.system(size: 22, weight: .heavy))
                        .fontWidth(.condensed)
                }
                .padding(.horizontal)

                ForEach(available) { episode in
                    Button { play(episode) } label: { row(episode) }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                }

                if let error {
                    ErrorView(message: error) { Task { await load() } }
                } else if episodes.isEmpty {
                    ProgressView().tint(Theme.pink).frame(maxWidth: .infinity).padding()
                } else if available.isEmpty {
                    Text("Aucun épisode en \(language.label).")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { if episodes.isEmpty { await load() } }
        .alert("Impossible de lancer l'épisode", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
    }

    private func row(_ episode: Episode) -> some View {
        HStack(spacing: 14) {
            Text("\(episode.number)")
                .font(.headline.monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceHigh))
            VStack(alignment: .leading, spacing: 2) {
                Text("Épisode \(episode.number)")
                    .font(.subheadline.weight(.semibold))
                if let title = episode.title, title != "Épisode \(episode.number)" {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if opening == episode.number {
                ProgressView().tint(Theme.pink)
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.gradient)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .contentShape(Rectangle())
    }

    private func load() async {
        error = nil
        do {
            async let list = AniverseAPI.shared.episodes(animeId: anime.id)
            async let counts = AniverseAPI.shared.episodeCounts(animeId: anime.id)
            episodes = try await list
            if let counts = try? await counts {
                subCount = counts.sub
                dubCount = counts.dub
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(_ episode: Episode) {
        guard opening == nil else { return }
        opening = episode.number
        let language = language
        Task {
            defer { opening = nil }
            do {
                let api = AniverseAPI.shared
                let stream = try await api.stream(animeId: anime.id, episode: episode.number, language: language)
                // The VF stream carries the same full French subtitles: only show them in VOSTFR.
                var cues: [SubtitleCue] = []
                if language == .sub, let url = stream.subtitles {
                    cues = (try? await api.subtitles(url)) ?? []
                }
                await MainActor.run { AnimePlayerController.present(url: stream.source, cues: cues) }
            } catch {
                playError = error.localizedDescription
            }
        }
    }
}

/// Native full-screen player with subtitles drawn from the site's WebVTT track.
final class AnimePlayerController: AVPlayerViewController {
    private var cues: [SubtitleCue] = []
    private let subtitleLabel = UILabel()
    private var timeObserver: Any?

    static func present(url: URL, cues: [SubtitleCue]) {
        let controller = AnimePlayerController()
        controller.cues = cues
        controller.player = AVPlayer(url: url)
        controller.modalPresentationStyle = .fullScreen
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard var top = window?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true) { controller.player?.play() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        guard let overlay = contentOverlayView else { return }
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitleLabel.shadowColor = .black
        subtitleLabel.shadowOffset = CGSize(width: 1, height: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            subtitleLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            subtitleLabel.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -28)
        ])

        guard !cues.isEmpty else { return }
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = time.seconds
                self.subtitleLabel.text = self.cues.first { $0.start <= now && now < $0.end }?.text
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}
