import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// A decoded reader page cut into horizontal slices. Webtoon strips can be 800 × 15000 px:
/// handing such a bitmap to the GPU in one piece stalls scrolling, small slices do not.
final class SlicedImage: @unchecked Sendable {
    let slices: [UIImage]
    let size: CGSize
    let cost: Int

    init(slices: [UIImage], size: CGSize, cost: Int) {
        self.slices = slices
        self.size = size
        self.cost = cost
    }
}

/// Shares one loading task between everyone asking for the same key, and cancels it once
/// nobody waits for it any more (e.g. cells scrolled off screen before their image arrived).
final class TaskCoalescer<Value: Sendable>: @unchecked Sendable {
    private final class Entry {
        let task: Task<Value, Error>
        var waiters = 0
        init(task: Task<Value, Error>) { self.task = task }
    }

    private final class Waiter {
        var released = false
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func value(for key: String, priority: TaskPriority, make: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let waiter = Waiter()
        let entry: Entry = synchronized {
            let entry = entries[key] ?? Entry(task: Task.detached(priority: priority, operation: make))
            entries[key] = entry
            entry.waiters += 1
            return entry
        }
        return try await withTaskCancellationHandler {
            defer { release(key, entry, waiter) }
            return try await entry.task.value
        } onCancel: {
            release(key, entry, waiter)
        }
    }

    private func release(_ key: String, _ entry: Entry, _ waiter: Waiter) {
        synchronized {
            guard !waiter.released else { return }
            waiter.released = true
            entry.waiters -= 1
            guard entry.waiters == 0 else { return }
            if entries[key] === entry { entries[key] = nil }
            // No-op once finished: the result is already in the memory cache.
            entry.task.cancel()
        }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Loads images from the network or local files, with memory caches and a bounded disk cache.
final class ImagePipeline {
    static let shared = ImagePipeline()

    /// Covers, banners, thumbnails, decoded at the size they are shown (see `key(for:fitting:mode:)`).
    private let memory = NSCache<NSString, UIImage>()
    /// Reader pages (full resolution, sliced).
    private let pages = NSCache<NSURL, SlicedImage>()
    private let diskDirectory: URL
    private let session: URLSession
    private let inFlightImages = TaskCoalescer<UIImage>()
    private let inFlightPages = TaskCoalescer<SlicedImage>()

    static let cacheLimitKey = "imageCacheLimitMB"
    static let defaultCacheLimitMB = 500

    init() {
        memory.totalCostLimit = 60 * 1024 * 1024
        pages.totalCostLimit = 180 * 1024 * 1024
        diskDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        // The pipeline has its own disk cache: don't keep a second copy in URLCache.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Referer": "https://aniverse.fr/"]
        session = URLSession(configuration: config)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.clearMemory()
        }

        Task.detached(priority: .background) { [weak self] in
            self?.trimDisk()
        }
    }

    // MARK: - Small images (covers, banners)

    /// Cache key of `url` shown in a `size` (points) box. Sizes are rounded up to 64 px steps,
    /// so a view that moves by a few points keeps hitting the same entry.
    static func key(for url: URL, fitting size: CGSize, mode: ContentMode, scale: CGFloat) -> String {
        func bucket(_ value: CGFloat) -> Int { Int((value * scale / 64).rounded(.up)) * 64 }
        return "\(url.absoluteString)#\(bucket(size.width))x\(bucket(size.height))\(mode == .fill ? "f" : "s")"
    }

    func cached(_ url: URL, fitting size: CGSize, mode: ContentMode, scale: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(for: url, fitting: size, mode: mode, scale: scale) as NSString)
    }

    /// Decodes `url` at the pixel size needed to show it in `size` points: a 30 pt thumbnail
    /// costs a few KB of memory instead of the megabytes of a full cover.
    func image(for url: URL, fitting size: CGSize, mode: ContentMode, scale: CGFloat) async throws -> UIImage {
        let key = Self.key(for: url, fitting: size, mode: mode, scale: scale)
        if let image = memory.object(forKey: key as NSString) { return image }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return try await inFlightImages.value(for: key, priority: .userInitiated) { [self] in
            let data = try await self.data(for: url)
            try Task.checkCancellation()
            guard let image = Self.downsample(data, fitting: target, fill: mode == .fill) else {
                throw APIError.parsing("l'image")
            }
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            self.memory.setObject(image, forKey: key as NSString, cost: cost)
            return image
        }
    }

    // MARK: - Reader pages

    func cachedPage(_ url: URL) -> SlicedImage? {
        pages.object(forKey: url as NSURL)
    }

    func page(for url: URL) async throws -> SlicedImage {
        if let page = cachedPage(url) { return page }
        return try await inFlightPages.value(for: url.absoluteString, priority: .userInitiated) { [self] in
            let data = try await self.data(for: url)
            try Task.checkCancellation()
            guard let page = Self.decodeSliced(data) else { throw APIError.parsing("la page") }
            self.pages.setObject(page, forKey: url as NSURL, cost: page.cost)
            return page
        }
    }

    /// Downloads (or reads from disk) without decoding: used to prefetch upcoming pages.
    func prefetch(_ url: URL) async {
        _ = try? await data(for: url)
    }

    // MARK: - Decoding

    /// The longest side, in pixels, at which the image covers (`fill`) or fits in `target`.
    /// Read from the header only, before decoding anything; never more than the original size.
    private static func pixelSize(of source: CGImageSource, fitting target: CGSize, fill: Bool) -> CGFloat {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              width > 0, height > 0, target.width > 0, target.height > 0 else {
            return max(target.width, target.height, 1000)
        }
        // A rotated (EXIF) image swaps its sides once displayed.
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let (w, h) = orientation >= 5 ? (height, width) : (width, height)
        let ratios = (target.width / w, target.height / h)
        let ratio = min(fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1), 1)
        return max(w, h) * ratio
    }

    private static func downsample(_ data: Data, fitting target: CGSize, fill: Bool) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let maxPixelSize = pixelSize(of: source, fitting: target, fill: fill).rounded(.up)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func decodeSliced(_ data: Data) -> SlicedImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let full = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }

        let width = full.width
        let height = full.height
        let cost = width * height * 4
        let sliceHeight = 1600
        guard height > sliceHeight * 3 / 2 else {
            return SlicedImage(slices: [UIImage(cgImage: full)], size: CGSize(width: width, height: height), cost: cost)
        }
        var slices: [UIImage] = []
        var y = 0
        while y < height {
            let h = min(sliceHeight, height - y)
            if let piece = full.cropping(to: CGRect(x: 0, y: y, width: width, height: h)) {
                slices.append(UIImage(cgImage: piece))
            }
            y += h
        }
        return SlicedImage(slices: slices, size: CGSize(width: width, height: height), cost: cost)
    }

    // MARK: - Disk cache

    private func data(for url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        let file = diskDirectory.appendingPathComponent(Self.key(for: url))
        if let data = try? Data(contentsOf: file) {
            // Mark as recently used, so trimming removes the oldest files first.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.http(http.statusCode, url)
        }
        try? data.write(to: file)
        return data
    }

    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var diskUsage: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static var cacheLimitBytes: Int64 {
        let mb = UserDefaults.standard.integer(forKey: cacheLimitKey)
        return Int64(mb > 0 ? mb : defaultCacheLimitMB) * 1024 * 1024
    }

    /// Deletes the least recently used files until the cache fits under the limit.
    func trimDisk(limit: Int64 = ImagePipeline.cacheLimitBytes) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    func clearMemory() {
        memory.removeAllObjects()
        pages.removeAllObjects()
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        clearMemory()
    }
}

/// An image view backed by `ImagePipeline`. It fills the space it is offered (use it in an
/// `.overlay` or a framed container) and decodes the image at that size.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, image: UIImage)?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Straight from the memory cache on the first frame (no placeholder flash when
            // scrolling back); a previous size of the same image while the new one decodes.
            let image = url.flatMap { ImagePipeline.shared.cached($0, fitting: size, mode: contentMode, scale: displayScale) }
                ?? (loaded?.url == url ? loaded?.image : nil)
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: size.width, height: size.height)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .overlay {
                            if failed {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }
            .frame(width: size.width, height: size.height)
            .task(id: url.map { ImagePipeline.key(for: $0, fitting: size, mode: contentMode, scale: displayScale) }) {
                failed = false
                guard let url, size.width > 0, size.height > 0 else { return }
                do {
                    let image = try await ImagePipeline.shared.image(for: url, fitting: size, mode: contentMode, scale: displayScale)
                    loaded = (url, image)
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
        }
    }
}
