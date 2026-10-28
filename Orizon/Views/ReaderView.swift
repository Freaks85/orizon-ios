import SwiftUI

/// Vertical (webtoon-style) reader. Reaching the end of a chapter loads the next one
/// right below it, so reading continues without leaving the scroll.
struct ReaderView: View {
    let context: ReaderContext

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var segments: [Segment] = []
    @State private var loadingNext = false
    @State private var error: String?
    @State private var showControls = true
    @State private var current: (chapterId: String, page: Int)?
    @State private var scrollTarget: String?

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

    /// Chapters in reading order (oldest first).
    private var ordered: [Chapter] {
        context.chapters.sorted { $0.numberValue < $1.numberValue }
    }

    private var items: [Item] {
        var result: [Item] = []
        for segment in segments {
            for (index, page) in segment.pages.enumerated() {
                result.append(.page(chapter: segment.chapter, index: index, count: segment.pages.count, page: page))
            }
            result.append(.divider(finished: segment.chapter, next: chapterAfter(segment.chapter)))
        }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if segments.isEmpty {
                if let error {
                    ErrorView(message: error) { Task { await start(at: context.startChapterId, page: context.startPage) } }
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
                        guard let target else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(target, anchor: .top)
                            scrollTarget = nil
                        }
                    }
                }
                .ignoresSafeArea(edges: showControls ? [] : .all)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
            }

            if showControls {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .preferredColorScheme(.dark)
        .task { await start(at: context.startChapterId, page: context.startPage) }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .page(let chapter, let index, let count, let page):
            ReaderPage(page: page)
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
                if let next, !segments.contains(where: { $0.chapter.id == next.id }) {
                    Task { await appendNext() }
                }
            }
        }
    }

    // MARK: - Controls

    private var currentChapter: Chapter? {
        guard let id = current?.chapterId else { return context.chapters.first { $0.id == context.startChapterId } }
        return context.chapters.first { $0.id == id }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.manga.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let chapter = currentChapter {
                        Text(chapter.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    if let chapter = currentChapter, let previous = chapterBefore(chapter) {
                        Task { await start(at: previous.id, page: 0) }
                    }
                } label: {
                    Image(systemName: "chevron.left.2").frame(width: 44, height: 44)
                }
                .disabled(currentChapter.flatMap(chapterBefore) == nil)

                Spacer()

                if let current, let segment = segments.first(where: { $0.chapter.id == current.chapterId }) {
                    Text("\(current.page + 1) / \(segment.pages.count)")
                        .font(.footnote.monospacedDigit().weight(.medium))
                }

                Spacer()

                Button {
                    if let chapter = currentChapter, let next = chapterAfter(chapter) {
                        Task { await start(at: next.id, page: 0) }
                    }
                } label: {
                    Image(systemName: "chevron.right.2").frame(width: 44, height: 44)
                }
                .disabled(currentChapter.flatMap(chapterAfter) == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.horizontal, 40)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Navigation between chapters

    private func chapterAfter(_ chapter: Chapter) -> Chapter? {
        let list = ordered
        guard let index = list.firstIndex(where: { $0.id == chapter.id }), index + 1 < list.count else { return nil }
        return list[index + 1]
    }

    private func chapterBefore(_ chapter: Chapter) -> Chapter? {
        let list = ordered
        guard let index = list.firstIndex(where: { $0.id == chapter.id }), index > 0 else { return nil }
        return list[index - 1]
    }

    private func loadPages(for chapter: Chapter) async throws -> [Page] {
        if let local = downloads.localPages(for: chapter.id) { return local }
        return try await AniverseAPI.shared.pages(slug: context.manga.slug, chapterId: chapter.id)
    }

    private func start(at chapterId: String, page: Int) async {
        guard let chapter = context.chapters.first(where: { $0.id == chapterId }) else { return }
        error = nil
        library.addIfNeeded(context.manga, chapters: context.chapters)
        do {
            let pages = try await loadPages(for: chapter)
            segments = [Segment(chapter: chapter, pages: pages)]
            current = (chapter.id, min(page, pages.count - 1))
            prefetch(pages, from: page)
            if page > 0 {
                scrollTarget = "\(chapter.id)#\(min(page, pages.count - 1))"
            } else {
                scrollTarget = "\(chapter.id)#0"
            }
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
            prefetch(pages, from: 0)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pageAppeared(chapter: Chapter, index: Int, count: Int) {
        current = (chapter.id, index)
        library.saveProgress(manga: context.manga, chapter: chapter, pageIndex: index, pageCount: count)

        if let segment = segments.first(where: { $0.chapter.id == chapter.id }) {
            prefetch(segment.pages, from: index + 1)
        }
        // Start loading the next chapter a few pages before the end, so it is ready in time.
        if index >= count - 3, segments.last?.chapter.id == chapter.id {
            Task { await appendNext() }
        }
    }

    private func prefetch(_ pages: [Page], from index: Int) {
        guard index < pages.count else { return }
        for page in pages[index..<min(index + 4, pages.count)] {
            Task.detached(priority: .utility) { _ = try? await ImagePipeline.shared.image(for: page.url) }
        }
    }
}

/// One page of the reader, sized from the page dimensions when known so the layout does not jump.
struct ReaderPage: View {
    let page: Page

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
                    .aspectRatio(page.aspectRatio ?? 0.7, contentMode: .fit)
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
            if let cached = ImagePipeline.shared.cached(page.url) {
                image = cached
                return
            }
            do {
                image = try await ImagePipeline.shared.image(for: page.url)
            } catch {
                failed = true
            }
        }
    }
}
