import SwiftUI
import UIKit
import CryptoKit

/// Loads images from the network or local files, with a memory cache and a disk cache.
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private let diskDirectory: URL
    private let session: URLSession
    private var inFlight: [URL: Task<UIImage, Error>] = [:]
    private let lock = NSLock()

    init() {
        // Webtoon strips are big (800 x 15000 px ≈ 48 MB decoded), so keep the cache bounded.
        memory.totalCostLimit = 200 * 1024 * 1024
        diskDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["Referer": "https://aniverse.fr/"]
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> UIImage {
        if let image = cached(url) { return image }

        let task: Task<UIImage, Error> = synchronized {
            if let existing = inFlight[url] { return existing }
            let created = Task.detached(priority: .userInitiated) { [self] () async throws -> UIImage in
                let data = try await self.data(for: url)
                guard let image = UIImage(data: data) else { throw APIError.parsing("l'image") }
                let decoded = image.preparingForDisplay() ?? image
                let cost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4)
                self.memory.setObject(decoded, forKey: url as NSURL, cost: cost)
                return decoded
            }
            inFlight[url] = created
            return created
        }
        defer { synchronized { inFlight[url] = nil } }
        return try await task.value
    }

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

    func clearDisk() {
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }
}

/// An image view backed by `ImagePipeline`.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

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
                image = try await ImagePipeline.shared.image(for: url)
            } catch {
                failed = true
            }
        }
    }
}
