import SwiftUI

/// Vertical (webtoon-style) reader. Reaching the end of a chapter loads the next one
/// right below it, so reading continues without leaving the scroll.
struct ReaderView: View {
    let context: ReaderContext

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoDeleteReadDownloads") private var autoDeleteRead = false

    @State private var segments: [Segment] = []
    @State private var loadingNext = false
    @State private var error: String?
    @State private var showControls = true
    @State private var showChapterPicker = false
    @State private var showDetails = false
    @State private var current: (chapterId: String, page: Int)?
    @State private var scrollTarget: String?
    /// Position inside the target page (0…1) to restore once the list shows that page.
    @State private var restoreFraction: Double = 0
    @State private var tracker = ScrollTracker()
    @State private var items: [Item] = []

    /// Reading position, updated on every scroll frame without touching SwiftUI state.
    /// It is written to the library only from time to time (see `commitProgress`):
    /// publishing the library while scrolling re-renders the whole app and stutters.
    final class ScrollTracker {
        var chapter: Chapter?
        var page = -1
        var count = 0
        var offset: Double = 0
        var dirty = false
        /// The UIScrollView behind the SwiftUI List: the position is read from it directly
        /// (SwiftUI geometry is not updated while UIKit scrolls the list's cells).
        weak var scrollView: UIScrollView?
        var observation: NSKeyValueObservation?
    }

    struct Segment: Identifiable {
        let chapter: Chapter
        let pages: [Page]
        var id: String { chapter.id }
    }

    enum Item: Identifiable {
        case page(chapter: Chapter, index: Int, count: Int, page: Page)
        case divider(finished: Chapter, next: Chapter?)

        var id: String {
            switch self {
            case .page(let chapter, let index, _, _): return "\(chapter.id)#\(index)"
            case .divider(let finished, _): return "end-\(finished.id)"
            }
        }
    }

    /// The flat list of rows, rebuilt only when chapters are added (not on every render).
    private func rebuildItems() {
        var result: [Item] = []
        for segment in segments {
            for (index, page) in segment.pages.enumerated() {
                result.append(.page(chapter: segment.chapter, index: index, count: segment.pages.count, page: page))
            }
            result.append(.divider(finished: segment.chapter, next: chapterAfter(segment.chapter)))
        }
        items = result
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if segments.isEmpty {
                if let error {
                    ErrorView(message: error) { Task { await start(at: context.startChapterId, page: context.startPage, offset: context.startOffset) } }
                } else {
                    ProgressView().tint(Theme.pink)
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(items) { item in
                            row(item)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.black)
                                .id(item.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                    .onChange(of: scrollTarget) { target in
                        scroll(proxy, to: target)
                    }
                    // The list is created in the same update that sets the first target,
                    // so onChange does not fire for it: handle it on appear.
                    .onAppear { scroll(proxy, to: scrollTarget) }
                }
                // Always full screen: the controls float above the pages without moving them.
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
            }

            if showControls {
                controls
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showChapterPicker) { chapterPicker }
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                MangaDetailView(manga: context.manga)
                    .navigationDestination(for: MangaSummary.self) { MangaDetailView(manga: $0) }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { showDetails = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .statusBarHidden(!showControls)
        .preferredColorScheme(.dark)
        .task { await start(at: context.startChapterId, page: context.startPage, offset: context.startOffset) }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in commitProgress() }
        .onChange(of: scenePhase) { phase in
            if phase != .active { commitProgress() }
        }
        .onDisappear { commitProgress() }
    }

    /// Scrolls to the saved page, then puts the saved point inside it exactly at the top
    /// of the screen using the list's real layout (List.scrollTo only aligns item tops).
    private func scroll(_ proxy: ScrollViewProxy, to target: String?) {
        guard let target else { return }
        let fraction = restoreFraction
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            proxy.scrollTo(target, anchor: .top)
        }
        // Again once real row heights are known, then place the exact point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            proxy.scrollTo(target, anchor: .top)
            DispatchQueue.main.async {
                if let scrollView = tracker.scrollView,
                   let index = items.firstIndex(where: { $0.id == target }),
                   let frame = Self.rowFrame(index, in: scrollView) {
                    let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                    let y = frame.minY + CGFloat(fraction) * frame.height
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(max(y, 0), maxY)), animated: false)
                }
                restoreFraction = 0
                scrollTarget = nil
            }
        }
    }

    /// Frame of row `index` in the list's content coordinates.
    private static func rowFrame(_ index: Int, in scrollView: UIScrollView) -> CGRect? {
        if let collection = scrollView as? UICollectionView,
           collection.numberOfSections > 0, index < collection.numberOfItems(inSection: 0) {
            return collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        }
        if let table = scrollView as? UITableView,
           table.numberOfSections > 0, index < table.numberOfRows(inSection: 0) {
            return table.rectForRow(at: IndexPath(row: index, section: 0))
        }
        return nil
    }

    /// Row under a point of the list's content, with its frame.
    private static func hitRow(at point: CGPoint, in scrollView: UIScrollView) -> (Int, CGRect)? {
        if let collection = scrollView as? UICollectionView,
           let indexPath = collection.indexPathForItem(at: point),
           let frame = collection.layoutAttributesForItem(at: indexPath)?.frame {
            return (indexPath.item, frame)
        }
        if let table = scrollView as? UITableView, let indexPath = table.indexPathForRow(at: point) {
            return (indexPath.row, table.rectForRow(at: indexPath))
        }
        return nil
    }

    private func attach(_ scrollView: UIScrollView) {
        guard tracker.scrollView !== scrollView else { return }
        tracker.scrollView = scrollView
        tracker.observation = scrollView.observe(\.contentOffset, options: [.new]) { scrollView, _ in
            DispatchQueue.main.async { positionChanged(in: scrollView) }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .page(let chapter, let index, let count, let page):
            ReaderPage(page: page)
                .background(ScrollViewLocator { attach($0) })
                .onAppear { pageAppeared(chapter: chapter, index: index, count: count) }
        case .divider(let finished, let next):
            VStack(spacing: 10) {
                Text("Fin du chapitre \(finished.number)")
                    .font(.subheadline.weight(.semibold))
                if let next {
                    if next.isPremium && !downloads.isDownloaded(next.id) {
                        Label("Le chapitre \(next.number) est premium", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    } else if loadingNext {
                        ProgressView().tint(Theme.pink)
                        Text("Chargement du chapitre \(next.number)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if !segments.contains(where: { $0.chapter.id == next.id }) {
                        Button("Chapitre \(next.number)") { Task { await appendNext() } }
                            .buttonStyle(PillButtonStyle())
                            .frame(width: 200)
                    }
                } else {
                    Text("Tu es à jour ! 🎉")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Fermer") { dismiss() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .frame(width: 160)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(Theme.background)
            .onAppear {
                // Reaching the end marker means the chapter was read to the end.
                commitProgress()
                library.setRead(true, chapterIds: [finished.id], slug: context.manga.slug)
                if autoDeleteRead, downloads.isDownloaded(finished.id) {
                    downloads.delete(finished.id)
                }
                if let next, !segments.contains(where: { $0.chapter.id == next.id }) {
                    Task { await appendNext() }
                }
            }
        }
    }

    // MARK: - Controls

    private var currentChapter: Chapter? {
        context.chapter(current?.chapterId ?? context.startChapterId)
    }

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .font(.headline)
                    .frame(width: 40, height: 40)
            }
            Button { showDetails = true } label: {
                HStack(spacing: 10) {
                    MangaCover(url: context.manga.cover, cornerRadius: 6)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.manga.title)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        if let chapter = currentChapter {
                            Text(chapter.displayName)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 6)
            if let current, let segment = segments.first(where: { $0.chapter.id == current.chapterId }) {
                Text("\(current.page + 1) / \(segment.pages.count)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            roundButton(icon: downloadIcon) {
                if let chapter = currentChapter, !downloads.isDownloaded(chapter.id) {
                    downloads.enqueue([chapter], manga: context.manga)
                }
            }

            HStack(spacing: 0) {
                let previous = currentChapter.flatMap(chapterBefore)
                Button {
                    if let previous { Task { await start(at: previous.id, page: 0, offset: 0) } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Préc.")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(previous == nil)
                .opacity(previous == nil ? 0.35 : 1)

                Button { showChapterPicker = true } label: {
                    HStack(spacing: 4) {
                        Text("Ch. \(currentChapter?.number ?? "?")")
                            .fontWeight(.bold)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                }

                let next = currentChapter.flatMap(chapterAfter)
                Button {
                    if let next { Task { await start(at: next.id, page: 0, offset: 0) } }
                } label: {
                    HStack(spacing: 4) {
                        Text(next.map { "Ch. \($0.number)" } ?? "Fin")
                        Image(systemName: "chevron.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(next == nil)
                .opacity(next == nil ? 0.35 : 1)
            }
            .font(.subheadline.weight(.medium))
            .frame(height: 52)
            .padding(.horizontal, 6)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))

            roundButton(icon: readIcon) {
                if let chapter = currentChapter {
                    let read = library.isRead(chapter.id, slug: context.manga.slug)
                    library.setRead(!read, chapterIds: [chapter.id], slug: context.manga.slug)
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(.bottom, 4)
    }

    private var downloadIcon: String {
        guard let chapter = currentChapter else { return "arrow.down" }
        if downloads.isDownloaded(chapter.id) { return "checkmark" }
        if downloads.job(for: chapter.id) != nil { return "clock" }
        return "arrow.down"
    }

    private var readIcon: String {
        guard let chapter = currentChapter else { return "eye" }
        return library.isRead(chapter.id, slug: context.manga.slug) ? "eye.fill" : "eye"
    }

    private func roundButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.black.opacity(0.88)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
        }
    }

    private var chapterPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chapitres")
                        .font(.system(size: 26, weight: .heavy))
                        .fontWidth(.condensed)
                    Text("\(context.chapters.count) chapitres publiés · \(context.manga.title)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { showChapterPicker = false } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(context.chapters) { chapter in
                            Button {
                                showChapterPicker = false
                                Task { await start(at: chapter.id, page: 0, offset: 0) }
                            } label: {
                                ChapterCard(
                                    chapter: chapter,
                                    isCurrent: chapter.id == currentChapter?.id,
                                    isRead: library.isRead(chapter.id, slug: context.manga.slug),
                                    isDownloaded: downloads.isDownloaded(chapter.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(chapter.isPremium && !downloads.isDownloaded(chapter.id))
                            .id(chapter.id)
                        }
                    }
                    .padding(16)
                }
                .onAppear {
                    if let id = currentChapter?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .background(Theme.background)
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Navigation between chapters

    private func chapterAfter(_ chapter: Chapter) -> Chapter? { context.chapter(after: chapter) }

    private func chapterBefore(_ chapter: Chapter) -> Chapter? { context.chapter(before: chapter) }

    private func loadPages(for chapter: Chapter) async throws -> [Page] {
        if let local = downloads.localPages(for: chapter.id) { return local }
        return try await AniverseAPI.shared.pages(slug: context.manga.slug, chapterId: chapter.id)
    }

    private func start(at chapterId: String, page: Int, offset: Double) async {
        guard let chapter = context.chapter(chapterId) else { return }
        error = nil
        library.addIfNeeded(context.manga, chapters: context.chapters)
        do {
            let pages = try await loadPages(for: chapter)
            let index = max(0, min(page, pages.count - 1))
            commitProgress()
            tracker = ScrollTracker()
            segments = [Segment(chapter: chapter, pages: pages)]
            rebuildItems()
            current = (chapter.id, index)
            prefetch(pages, from: index)
            restoreFraction = offset
            scrollTarget = "\(chapter.id)#\(index)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func appendNext() async {
        guard !loadingNext, let last = segments.last?.chapter, let next = chapterAfter(last) else { return }
        guard !next.isPremium || downloads.isDownloaded(next.id) else { return }
        loadingNext = true
        error = nil
        defer { loadingNext = false }
        do {
            let pages = try await loadPages(for: next)
            guard !segments.contains(where: { $0.chapter.id == next.id }) else { return }
            segments.append(Segment(chapter: next, pages: pages))
            rebuildItems()
            prefetch(pages, from: 0)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Called while scrolling: the page at the top of the screen is the one being read,
    /// and the part of it already above the top is the position inside that page.
    private func positionChanged(in scrollView: UIScrollView) {
        guard scrollTarget == nil else { return }
        let point = CGPoint(x: scrollView.bounds.midX, y: scrollView.contentOffset.y + 1)
        guard let hit = Self.hitRow(at: point, in: scrollView) else { return }
        let (row, frame) = hit
        guard frame.height > 0, row < items.count,
              case .page(let chapter, let index, let count, _) = items[row] else { return }
        let offset = Double(min(max((point.y - frame.minY) / frame.height, 0), 1))

        let chapterChanged = tracker.chapter?.id != chapter.id
        if chapterChanged || tracker.page != index {
            current = (chapter.id, index)   // only state change: the page counter
        }
        if chapterChanged, tracker.chapter != nil {
            commitProgress()                // keep the finished chapter's last position
        }
        tracker.chapter = chapter
        tracker.page = index
        tracker.count = count
        tracker.offset = offset
        tracker.dirty = true
        if chapterChanged { commitProgress() }
    }

    /// Writes the buffered reading position to the library.
    private func commitProgress() {
        guard tracker.dirty, let chapter = tracker.chapter else { return }
        tracker.dirty = false
        library.saveProgress(manga: context.manga, chapter: chapter, pageIndex: tracker.page,
                             pageCount: tracker.count, offset: tracker.offset)
    }

    private func pageAppeared(chapter: Chapter, index: Int, count: Int) {
        if let segment = segments.first(where: { $0.chapter.id == chapter.id }) {
            prefetch(segment.pages, from: index + 1)
        }
        // Start loading the next chapter a few pages before the end, so it is ready in time.
        if index >= count - 3, segments.last?.chapter.id == chapter.id {
            Task { await appendNext() }
        }
    }

    /// Downloads the next pages ahead of time and decodes the very next one.
    private func prefetch(_ pages: [Page], from index: Int) {
        guard index < pages.count else { return }
        let upcoming = Array(pages[index..<min(index + 5, pages.count)])
        Task.detached(priority: .utility) {
            if let first = upcoming.first { _ = try? await ImagePipeline.shared.page(for: first.url) }
            for page in upcoming.dropFirst() { await ImagePipeline.shared.prefetch(page.url) }
        }
    }
}

/// One page of the reader, sized from the page dimensions when known so the layout does not jump.
/// Tall pages are drawn as a stack of slices (see `SlicedImage`) for smooth scrolling.
struct ReaderPage: View {
    let page: Page

    /// Only held while the page is on screen: SwiftUI keeps the state of every row the reader has
    /// shown, and a decoded webtoon strip weighs tens of MB. Kept for good, a long reading session
    /// grows until iOS kills the app. Scrolling back gets it from the pipeline's cache.
    @State private var image: SlicedImage?
    /// Shape of the decoded page, so the placeholder keeps its height once the image is released.
    @State private var loadedAspectRatio: Double?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                VStack(spacing: 0) {
                    ForEach(image.slices.indices, id: \.self) { index in
                        Image(uiImage: image.slices[index])
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                    }
                }
            } else {
                Color.black
                    .aspectRatio(loadedAspectRatio ?? page.aspectRatio ?? 0.7, contentMode: .fit)
                    .overlay {
                        if failed {
                            Button {
                                attempt += 1
                            } label: {
                                Label("Recharger la page", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .frame(width: 220)
                        } else {
                            ProgressView().tint(Theme.pink)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: "\(page.url.absoluteString)#\(attempt)") {
            failed = false
            do {
                let loaded: SlicedImage
                if let cached = ImagePipeline.shared.cachedPage(page.url) {
                    loaded = cached
                } else {
                    loaded = try await ImagePipeline.shared.page(for: page.url)
                }
                guard !Task.isCancelled else { return }
                if loaded.size.height > 0 { loadedAspectRatio = Double(loaded.size.width / loaded.size.height) }
                image = loaded
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .onDisappear { image = nil }
    }
}

/// Chapter card for the reader's chapter picker, in the style of aniverse.fr.
struct ChapterCard: View {
    let chapter: Chapter
    let isCurrent: Bool
    let isRead: Bool
    let isDownloaded: Bool

    var body: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 112, height: 84)
                .overlay {
                    if let thumbnail = chapter.thumbnail {
                        RemoteImage(url: thumbnail)
                    } else {
                        ZStack {
                            Theme.surfaceHigh
                            Text(chapter.number)
                                .font(.title2.weight(.heavy))
                                .foregroundStyle(Theme.gradient)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Chapitre \(chapter.number)")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isCurrent {
                        Text("Lecture en cours")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.purple.opacity(0.35)))
                    } else if isRead {
                        Label("Lu", systemImage: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if chapter.isPremium {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.yellow)
                    } else if chapter.isNew {
                        Text("NOUVEAU")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.gradient))
                    }
                }
                if let title = chapter.title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let date = chapter.date {
                    Text(date.relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isCurrent ? Theme.purple.opacity(0.18) : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isCurrent ? Theme.pink.opacity(0.6) : Color.white.opacity(0.05))
        )
        .opacity(isRead && !isCurrent ? 0.45 : 1)
        .foregroundStyle(.white)
    }
}

/// Finds the UIScrollView that hosts a SwiftUI view (here: the List of the reader).
struct ScrollViewLocator: UIViewRepresentable {
    let onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView.superview
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    onFound(scrollView)
                    return
                }
                current = view.superview
            }
        }
    }
}
