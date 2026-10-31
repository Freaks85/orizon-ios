import SwiftUI
import UIKit

/// The scrolling part of the reader, in UIKit: a collection view whose cells are recycled with their
/// images (memory stays flat however long the session), whose page heights are known before the
/// images arrive (no layout jumps), and whose position is read straight from the scroll view.
struct ReaderCollection: UIViewRepresentable {
    struct ScrollRequest: Equatable {
        /// Item to put at the top of the screen, and the point inside it (0…1).
        var itemId: String
        var fraction: Double
        let token = UUID()
    }

    let items: [ReaderView.Item]
    /// Bumped each time `items` is rebuilt (comparing the arrays on every render would cost more).
    let itemsVersion: Int
    /// Changes when what the end-of-chapter rows show changes (loading, error…).
    let dividerState: Int
    let scrollRequest: ScrollRequest?
    let divider: (_ finished: Chapter, _ next: Chapter?) -> ReaderDividerView
    /// Item at the top of the screen and the part of it already scrolled past (0…1), on every frame.
    let onScroll: (_ index: Int, _ fraction: Double) -> Void
    let onPageAppear: (_ chapter: Chapter, _ index: Int, _ count: Int) -> Void
    let onDividerAppear: (_ finished: Chapter, _ next: Chapter?) -> Void
    let onTap: () -> Void
    let onDragStart: () -> Void
    let onScrollRequestDone: () -> Void
    let onAttach: (UIScrollView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.update(parent: self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
        private(set) var parent: ReaderCollection
        private weak var collectionView: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        private var items: [ReaderView.Item] = []
        private var indexById: [String: Int] = [:]
        private var itemsVersion = -1
        private var dividerState = 0
        private var handledRequest: UUID?
        /// While restoring a position, the scroll must not be reported as reading.
        private var restoring = false
        /// Inside a SwiftUI update: applying a snapshot can scroll, and reporting it then would
        /// change SwiftUI state in the middle of the update.
        private var updating = false
        /// Page shapes learned from the decoded images, for pages the site gave no size for.
        private var aspects: [URL: Double] = [:]

        static let dividerHeight: CGFloat = 230

        init(parent: ReaderCollection) {
            self.parent = parent
        }

        func makeCollectionView() -> UICollectionView {
            let layout = ReaderLayout()
            layout.minimumLineSpacing = 0
            layout.minimumInteritemSpacing = 0
            layout.sectionInset = .zero

            let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
            collectionView.backgroundColor = .black
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.showsVerticalScrollIndicator = false
            collectionView.alwaysBounceVertical = true
            collectionView.delegate = self
            collectionView.register(ReaderPageCell.self, forCellWithReuseIdentifier: ReaderPageCell.reuseId)
            collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "divider")

            dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
                guard let self, let index = self.indexById[id] else { return UICollectionViewCell() }
                switch self.items[index] {
                case .page(_, _, _, let page):
                    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ReaderPageCell.reuseId, for: indexPath) as! ReaderPageCell
                    cell.configure(page: page) { [weak self] url, size in
                        // Not inside the cell configuration / layout pass that showed the image.
                        DispatchQueue.main.async { self?.pageLoaded(url, size: size) }
                    }
                    return cell
                case .divider(let finished, let next):
                    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "divider", for: indexPath)
                    cell.contentConfiguration = UIHostingConfiguration { self.parent.divider(finished, next) }
                        .margins(.all, 0)
                    return cell
                }
            }

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            collectionView.addGestureRecognizer(tap)

            self.collectionView = collectionView
            parent.onAttach(collectionView)
            return collectionView
        }

        func update(parent: ReaderCollection) {
            self.parent = parent
            guard collectionView != nil else { return }
            updating = true
            defer { updating = false }

            if parent.itemsVersion != itemsVersion {
                itemsVersion = parent.itemsVersion
                dividerState = parent.dividerState
                items = parent.items
                indexById = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(items.map(\.id))
                dataSource.apply(snapshot, animatingDifferences: false)
            } else if parent.dividerState != dividerState {
                dividerState = parent.dividerState
                var snapshot = dataSource.snapshot()
                let dividers = items.compactMap { item -> String? in
                    if case .divider = item { return item.id }
                    return nil
                }
                snapshot.reconfigureItems(dividers)
                dataSource.apply(snapshot, animatingDifferences: false)
            }

            if let request = parent.scrollRequest, request.token != handledRequest {
                handledRequest = request.token
                restoring = true
                // After the snapshot is laid out (and the view has its size on first display).
                DispatchQueue.main.async { [weak self] in self?.perform(request, attempt: 0) }
            }
        }

        private func perform(_ request: ScrollRequest, attempt: Int) {
            guard let collectionView else { return }
            collectionView.layoutIfNeeded()
            if collectionView.bounds.height == 0, attempt < 20 {
                DispatchQueue.main.async { [weak self] in self?.perform(request, attempt: attempt + 1) }
                return
            }
            if let index = indexById[request.itemId],
               let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame {
                let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
                let y = frame.minY + CGFloat(request.fraction) * frame.height
                collectionView.setContentOffset(CGPoint(x: 0, y: min(max(y, 0), maxY)), animated: false)
            }
            restoring = false
            parent.onScrollRequestDone()
            reportPosition()
        }

        // MARK: Layout

        private func height(of index: Int, width: CGFloat) -> CGFloat {
            switch items[index] {
            case .page(_, _, _, let page):
                let aspect = aspects[page.url] ?? page.aspectRatio ?? 0.7
                return (width / CGFloat(aspect)).rounded()
            case .divider:
                return Self.dividerHeight
            }
        }

        func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = collectionView.bounds.width
            guard indexPath.item < items.count, width > 0 else { return CGSize(width: max(width, 1), height: 1) }
            return CGSize(width: width, height: height(of: indexPath.item, width: width))
        }

        /// A decoded page whose shape differs from the one used for the layout (no size from the site):
        /// resize its row, keeping what is on screen in place when the row is above it.
        private func pageLoaded(_ url: URL, size: CGSize) {
            guard size.width > 0, size.height > 0, let collectionView else { return }
            let aspect = Double(size.width / size.height)
            guard let index = items.firstIndex(where: {
                if case .page(_, _, _, let page) = $0 { return page.url == url }
                return false
            }) else { return }
            let width = collectionView.bounds.width
            let old = height(of: index, width: width)
            aspects[url] = aspect
            let new = height(of: index, width: width)
            guard abs(new - old) >= 1 else { return }
            let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let frame, frame.maxY <= collectionView.contentOffset.y {
                collectionView.contentOffset.y += new - old
            }
        }

        // MARK: Scrolling

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportPosition()
        }

        private func reportPosition() {
            guard !restoring, !updating, let collectionView else { return }
            let point = CGPoint(x: collectionView.bounds.midX, y: collectionView.contentOffset.y + 1)
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame,
                  frame.height > 0 else { return }
            let fraction = Double(min(max((point.y - frame.minY) / frame.height, 0), 1))
            parent.onScroll(indexPath.item, fraction)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onDragStart()
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            guard indexPath.item < items.count else { return }
            let item = items[indexPath.item]
            // Out of the collection view's layout pass before touching SwiftUI state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch item {
                case .page(let chapter, let index, let count, _):
                    self.parent.onPageAppear(chapter, index, count)
                case .divider(let finished, let next):
                    self.parent.onDividerAppear(finished, next)
                }
            }
        }

        // MARK: Tap

        @objc private func tapped() {
            parent.onTap()
        }

        /// Taps on buttons (end of chapter, reload a page) are theirs, not a show/hide of the controls.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let collectionView else { return true }
            if touch.view is UIControl { return false }
            if let indexPath = collectionView.indexPathForItem(at: touch.location(in: collectionView)),
               indexPath.item < items.count, case .divider = items[indexPath.item] {
                return false
            }
            return true
        }
    }
}

/// Re-lays out the rows when the width changes (rotation, iPad split view).
private final class ReaderLayout: UICollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

/// One page: its slices (see `SlicedImage`) in image views, filled from the cache when the page was
/// decoded ahead of time, else loaded. The images go with the cell when it is reused.
final class ReaderPageCell: UICollectionViewCell {
    static let reuseId = "page"

    private var imageViews: [UIImageView] = []
    private var image: SlicedImage?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var page: Page?
    private var task: Task<Void, Never>?
    private var onLoaded: ((URL, CGSize) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        spinner.color = UIColor(Theme.pink)
        spinner.hidesWhenStopped = true
        contentView.addSubview(spinner)

        var config = UIButton.Configuration.gray()
        config.title = "Recharger la page"
        config.image = UIImage(systemName: "arrow.clockwise")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        retryButton.configuration = config
        retryButton.isHidden = true
        retryButton.addAction(UIAction { [weak self] _ in self?.load() }, for: .touchUpInside)
        contentView.addSubview(retryButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(page: Page, onLoaded: @escaping (URL, CGSize) -> Void) {
        self.onLoaded = onLoaded
        guard page != self.page else { return }
        task?.cancel()
        self.page = page
        show(nil)
        // Decoded ahead of time: shown in this very frame, no placeholder.
        if let cached = ImagePipeline.shared.cachedPage(page.url) {
            show(cached)
        } else {
            load()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Let go of the bitmaps: the pipeline's cache decides what stays in memory.
        task?.cancel()
        task = nil
        page = nil
        show(nil)
    }

    private func load() {
        guard let page else { return }
        task?.cancel()
        retryButton.isHidden = true
        spinner.startAnimating()
        task = Task { [weak self] in
            do {
                let loaded = try await ImagePipeline.shared.page(for: page.url)
                guard !Task.isCancelled, let self, self.page == page else { return }
                self.show(loaded)
            } catch {
                guard !Task.isCancelled, let self, self.page == page else { return }
                self.spinner.stopAnimating()
                self.retryButton.isHidden = false
            }
        }
    }

    private func show(_ image: SlicedImage?) {
        self.image = image
        guard let image else {
            for view in imageViews { view.image = nil }
            retryButton.isHidden = true
            return
        }
        spinner.stopAnimating()
        retryButton.isHidden = true
        while imageViews.count < image.slices.count {
            let view = UIImageView()
            view.contentMode = .scaleToFill
            contentView.insertSubview(view, at: 0)
            imageViews.append(view)
        }
        for (index, view) in imageViews.enumerated() {
            view.image = index < image.slices.count ? image.slices[index] : nil
            view.isHidden = index >= image.slices.count
        }
        setNeedsLayout()
        if let page { onLoaded?(page.url, image.size) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retryButton.sizeToFit()
        retryButton.center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let image, image.size.width > 0 else { return }
        // Slices share the page's width: each one's height follows from its own pixel height.
        let scale = bounds.width / image.size.width
        var y: CGFloat = 0
        for (index, slice) in image.slices.enumerated() where index < imageViews.count {
            let height = index == image.slices.count - 1 ? bounds.height - y : (slice.size.height * slice.scale * scale).rounded()
            imageViews[index].frame = CGRect(x: 0, y: y, width: bounds.width, height: max(height, 0))
            y += height
        }
    }
}

/// The end of a chapter, between it and the next one.
struct ReaderDividerView: View {
    let finished: Chapter
    let next: Chapter?
    let nextLocked: Bool
    let loadingNext: Bool
    let nextLoaded: Bool
    let error: String?
    let loadNext: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Fin du chapitre \(finished.number)")
                .font(.subheadline.weight(.semibold))
            if let next {
                if nextLocked {
                    Label("Le chapitre \(next.number) est premium", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                } else if loadingNext {
                    ProgressView().tint(Theme.pink)
                    Text("Chargement du chapitre \(next.number)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !nextLoaded {
                    Button("Chapitre \(next.number)", action: loadNext)
                        .buttonStyle(PillButtonStyle())
                        .frame(width: 200)
                }
            } else {
                Text("Tu es à jour ! 🎉")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Fermer", action: close)
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .frame(width: 160)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
