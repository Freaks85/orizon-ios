import AVKit
import SwiftUI

struct PlayerContext: Identifiable {
    var anime: Anime
    /// Episodes available in `language`, oldest first.
    var episodes: [Episode]
    var language: AnimeLanguage
    var startEpisode: Int
    let id = UUID()
}

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    let anime: Anime
    let episodes: [Episode]
    let language: AnimeLanguage

    @Published private(set) var episode: Int
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var subtitle: String?
    @Published private(set) var segment: SkipSegment?
    var isScrubbing = false

    private var cues: [SubtitleCue] = []
    private var segments: [SkipSegment] = []
    private var malId: Int?
    private var started = false
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(context: PlayerContext) {
        anime = context.anime
        episodes = context.episodes
        language = context.language
        episode = context.startEpisode
        malId = context.anime.malId
    }

    var nextEpisode: Episode? { episodes.first { $0.number > episode } }

    func start() {
        guard !started else { return }
        started = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.playNext()
            }
        }
        play(episode)
    }

    func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    func play(_ number: Int) {
        loadTask?.cancel()
        episode = number
        error = nil
        isLoading = true
        subtitle = nil
        segment = nil
        cues = []
        segments = []
        currentTime = 0
        duration = 0
        player.replaceCurrentItem(with: nil)
        let anime = anime, language = language
        loadTask = Task {
            let api = AniverseAPI.shared
            do {
                let source: URL
                let subtitles: URL?
                if let local = EpisodeDownloads.shared.local(animeId: anime.id, language: language, number: number) {
                    source = local.video
                    subtitles = local.subtitles
                } else {
                    let stream = try await api.stream(animeId: anime.id, episode: number, language: language)
                    source = stream.source
                    // The VF stream carries the same full French subtitles: only show them in VOSTFR.
                    subtitles = language == .sub ? stream.subtitles : nil
                }
                guard !Task.isCancelled else { return }
                player.replaceCurrentItem(with: AVPlayerItem(url: source))
                player.play()
                isLoading = false

                if let url = subtitles {
                    let loaded = (try? await api.subtitles(url)) ?? []
                    guard !Task.isCancelled else { return }
                    cues = loaded
                }
                if malId == nil { malId = try? await api.malId(slug: anime.slug) }
                if let malId {
                    let duration = try? await player.currentItem?.asset.load(.duration)
                    var loaded = (try? await api.skipTimes(malId: malId, episode: number, length: duration?.seconds ?? 0)) ?? []
                    if loaded.isEmpty { loaded = (try? await api.segments(malId: malId, episode: number)) ?? [] }
                    guard !Task.isCancelled else { return }
                    segments = loaded
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                self.error = error.localizedDescription
            }
        }
    }

    func playNext() {
        if let next = nextEpisode { play(next.number) }
    }

    func togglePlay() {
        if player.rate == 0 { player.play() } else { player.pause() }
        isPlaying = player.rate != 0
    }

    func seek(to time: Double) {
        let target = min(max(time, 0), duration > 0 ? duration : time)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func skip(_ segment: SkipSegment) {
        if segment.isEnding, nextEpisode != nil { playNext() } else { seek(to: segment.end) }
    }

    private func tick(_ time: Double) {
        isPlaying = player.rate != 0
        if let total = player.currentItem?.duration.seconds, total.isFinite { duration = total }
        guard time.isFinite else { return }
        if !isScrubbing { currentTime = time }
        subtitle = cues.first { $0.start <= time && time < $0.end }?.text
        segment = segments.first { $0.start <= time && time < $0.end - 1 }
    }
}

/// Orizon's own player: full-screen video, subtitles, skip opening/ending, next episode and episode list.
struct AnimePlayerView: View {
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var showEpisodes = false
    @State private var hideTask: Task<Void, Never>?

    init(context: PlayerContext) {
        _model = StateObject(wrappedValue: PlayerModel(context: context))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: model.player).ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if let subtitle = model.subtitle {
                VStack {
                    Spacer()
                    Text(subtitle)
                        .font(.system(size: 19, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 1, y: 1)
                        .padding(.horizontal, 40)
                        .padding(.bottom, showControls ? 96 : 24)
                }
                .allowsHitTesting(false)
            }

            if model.isLoading {
                ProgressView().tint(.white).scaleEffect(1.4)
            } else if let error = model.error {
                ErrorView(message: error) { model.play(model.episode) }
            }

            if showControls {
                controls.transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let segment = model.segment {
                Button { model.skip(segment) } label: {
                    Label(skipLabel(segment), systemImage: "forward.end.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 24)
                .padding(.bottom, showControls ? 96 : 24)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            UIApplication.shared.isIdleTimerDisabled = true
            rotate(to: .landscape, lock: .landscape)
            model.start()
            scheduleHide()
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            rotate(to: .portrait, lock: AppDelegate.defaultOrientations)
        }
        .sheet(isPresented: $showEpisodes) { episodeList }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack(spacing: 14) {
                    roundButton("xmark") { dismiss() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.anime.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("Épisode \(model.episode) · \(model.language.label)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    roundButton("list.bullet") { showEpisodes = true }
                }

                Spacer()

                if model.error == nil {
                    HStack(spacing: 48) {
                        roundButton("gobackward.10", size: 24) { model.skip(by: -10) }
                        Button {
                            model.togglePlay()
                            scheduleHide()
                        } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 38))
                                .frame(width: 70, height: 70)
                        }
                        .buttonStyle(.plain)
                        roundButton("goforward.10", size: 24) { model.skip(by: 10) }
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Slider(value: $model.currentTime, in: 0...max(model.duration, 1)) { editing in
                        model.isScrubbing = editing
                        if !editing { model.seek(to: model.currentTime) }
                        scheduleHide()
                    }
                    .tint(Theme.pink)
                    HStack {
                        Text(Self.format(model.currentTime))
                        Spacer()
                        if model.nextEpisode != nil {
                            Button {
                                model.playNext()
                                scheduleHide()
                            } label: {
                                Label("Épisode suivant", systemImage: "forward.end.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        Text(Self.format(model.duration))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
        }
    }

    private var episodeList: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(model.episodes) { episode in
                    Button {
                        showEpisodes = false
                        model.play(episode.number)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Épisode \(episode.number)")
                                if let title = episode.title, title != "Épisode \(episode.number)" {
                                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if episode.number == model.episode {
                                Image(systemName: "play.fill").foregroundStyle(Theme.pink)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .id(episode.number)
                }
                .onAppear { proxy.scrollTo(model.episode, anchor: .center) }
            }
            .navigationTitle("Épisodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { showEpisodes = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func roundButton(_ icon: String, size: CGFloat = 17, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }

    private func skipLabel(_ segment: SkipSegment) -> String {
        if segment.isEnding, model.nextEpisode != nil { return "Épisode suivant" }
        switch segment.label.lowercased() {
        case "opening": return "Passer l'opening"
        case "ending": return "Passer l'ending"
        case "recap": return "Passer le résumé"
        default: return "Passer"
        }
    }

    private func toggleControls() {
        let show = !showControls
        withAnimation(.easeInOut(duration: 0.2)) { showControls = show }
        if show { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, model.isPlaying, !model.isScrubbing, !showEpisodes else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    /// iOS only rotates to orientations the app allows at that moment: lock them first, then ask.
    private func rotate(to orientations: UIInterfaceOrientationMask, lock: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = lock
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}
}
