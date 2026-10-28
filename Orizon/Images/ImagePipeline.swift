import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// A decoded reader page cut into horizontal slices. Webtoon strips can be 800 × 15000 px:
/// handing such a bitmap to the GPU in one piece stalls scrolling, small slices do not.
final class SlicedImage {
    let slices: [UIImage]
    let size: CGSize
    let cost: Int

    init(slices: [UIImage], size: CGSize, cost: Int) {
        self.slices = slices
        self.size = size
        self.cost = cost
    }
}

/// Loads images from the network or local files, with memory caches and a bounded disk cache.
final class ImagePipeline {
    static let shared = ImagePipeline()

    /// Covers, banners, thumbnails (downsampled).
    private let memory = NSCache<NSURL, UIImage>()
    /// Reader pages (full resolution, sliced).
    private let pages = NSCache<NSURL, SlicedImage>()
    private let diskDirectory: URL
    private let session: URLSession
    private var inFlightImages: [URL: Task<UIImage, Error>] = [:]
    private var inFlightPages: [URL: Task<SlicedImage, Error>] = [:]
    private let lock = NSLock()

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

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL, maxPixelSize: CGFloat = 1000) async throws -> UIImage {
        if let image = cached(url) { return image }

        let task: Task<UIImage, Error> = synchronized {
            if let existing = inFlightImages[url] { return existing }
            let created = Task.detached(priority: .userInitiated) { [self] () async throws -> UIImage in
                let data = try await self.data(for: url)
                guard let image = Self.downsample(data, maxPixelSize: maxPixelSize) else {
                    throw APIError.parsing("l'image")
                }
                let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
                self.memory.setObject(image, forKey: url as NSURL, cost: cost)
                return image
            }
            inFlightImages[url] = created
            return created
        }
        defer { synchronized { inFlightImages[url] = nil } }
        return try await task.value
    }

    // MARK: - Reader pages

    func cachedPage(_ url: URL) -> SlicedImage? {
        pages.object(forKey: url as NSURL)
    }

    func page(for url: URL) async throws -> SlicedImage {
        if let page = cachedPage(url) { return page }

        let task: Task<SlicedImage, Error> = synchronized {
            if let existing = inFlightPages[url] { return existing }
            let created = Task.detached(priority: .userInitiated) { [self] () async throws -> SlicedImage in
                let data = try await self.data(for: url)
                guard let page = Self.decodeSliced(data) else { throw APIError.parsing("la page") }
                self.pages.setObject(page, forKey: url as NSURL, cost: page.cost)
                return page
            }
            inFlightPages[url] = created
            return created
        }
        defer { synchronized { inFlightPages[url] = nil } }
        return try await task.value
    }

    /// Downloads (or reads from disk) without decoding: used to prefetch upcoming pages.
    func prefetch(_ url: URL) async {
        _ = try? await data(for: url)
    }

    // MARK: - Decoding

    private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
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

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

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

/// An image view backed by `ImagePipeline`.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var maxPixelSize: CGFloat = 1000

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
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
        .task(id: url) {
            failed = false
            guard let url else { return }
            if let cached = ImagePipeline.shared.cached(url) {
                image = cached
                return
            }
            image = nil
            do {
                image = try await ImagePipeline.shared.image(for: url, maxPixelSize: maxPixelSize)
            } catch {
                failed = true
            }
        }
    }
}
