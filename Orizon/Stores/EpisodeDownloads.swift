import CommonCrypto
import Foundation
import UIKit

struct DownloadedEpisode: Codable, Hashable, Identifiable {
    var anime: Anime
    var episode: Episode
    var language: AnimeLanguage
    var byteCount: Int64
    var downloadedAt: Date
    var hasSubtitles: Bool

    var id: String { EpisodeDownloads.key(anime.id, language, episode.number) }
}

/// Offline episodes: the HLS segments are fetched in parallel, decrypted (AES-128) and stored with
/// a local playlist under Documents/AnimeDownloads/<id>/, so the player reads them without network.
@MainActor
final class EpisodeDownloads: ObservableObject {
    static let shared = EpisodeDownloads()

    struct Job: Identifiable, Hashable {
        var anime: Anime
        var episode: Episode
        var language: AnimeLanguage
        var error: String?

        var id: String { EpisodeDownloads.key(anime.id, language, episode.number) }
    }

    struct Group: Identifiable {
        var anime: Anime
        var episodes: [DownloadedEpisode]
        var id: String { anime.id }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var downloaded: [String: DownloadedEpisode] = [:]
    /// Segments done per running episode (published apart, see `DownloadProgress`).
    let progress = DownloadProgress()

    private let maxConcurrentSegments = 6
    private var running: [String: Task<Void, Never>] = [:]
    private let indexName = "anime-downloads.json"

    /// Kept apart from the manga downloads folder, whose cleanup removes the folders it does not know.
    let root: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnimeDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Episodes weigh hundreds of MB each: keep them out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
        return dir
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    init() {
        downloaded = Persistence.load([String: DownloadedEpisode].self, from: indexName) ?? [:]
    }

    nonisolated static func key(_ animeId: String, _ language: AnimeLanguage, _ number: Int) -> String {
        "\(animeId)-\(language.rawValue)-\(number)"
    }

    // MARK: - Queries

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    func local(animeId: String, language: AnimeLanguage, number: Int) -> (video: URL, subtitles: URL?)? {
        let id = Self.key(animeId, language, number)
        guard let item = downloaded[id] else { return nil }
        let dir = folder(id)
        return (dir.appendingPathComponent("index.m3u8"), item.hasSubtitles ? dir.appendingPathComponent("subtitles.vtt") : nil)
    }

    var byAnime: [Group] {
        Dictionary(grouping: downloaded.values, by: { $0.anime.id })
            .compactMap { _, items in
                guard let anime = items.first?.anime else { return nil }
                let sorted = items.sorted { ($0.language.rawValue, $0.episode.number) < ($1.language.rawValue, $1.episode.number) }
                return Group(anime: anime, episodes: sorted)
            }
            .sorted { $0.anime.title.localizedCaseInsensitiveCompare($1.anime.title) == .orderedAscending }
    }

    var totalBytes: Int64 { downloaded.values.reduce(0) { $0 + $1.byteCount } }

    // MARK: - Actions

    func enqueue(_ episodes: [Episode], anime: Anime, language: AnimeLanguage) {
        for episode in episodes.sorted(by: { $0.number < $1.number }) {
            let id = Self.key(anime.id, language, episode.number)
            guard downloaded[id] == nil else { continue }
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].error = nil
                continue
            }
            jobs.append(Job(anime: anime, episode: episode, language: language))
        }
        pump()
    }

    func cancel(_ id: String) {
        running[id]?.cancel()
        running[id] = nil
        progress.remove(id)
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(id))
        pump()
    }

    func cancelAll() {
        for id in jobs.map(\.id) { cancel(id) }
    }

    func retryFailed() {
        for index in jobs.indices { jobs[index].error = nil }
        pump()
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        downloaded[id] = nil
        saveIndex()
    }

    func deleteAll(animeId: String) {
        for item in downloaded.values where item.anime.id == animeId { delete(item.id) }
    }

    /// Deletes the downloaded episodes for which `isWatched` returns true. Returns how many.
    @discardableResult
    func deleteWatched(where isWatched: (DownloadedEpisode) -> Bool) -> Int {
        let watched = downloaded.values.filter(isWatched)
        for item in watched { delete(item.id) }
        return watched.count
    }

    func deleteEverything() {
        cancelAll()
        downloaded.removeAll()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saveIndex()
    }

    // MARK: - Queue

    /// One episode at a time: its segments already download in parallel.
    private func pump() {
        guard running.isEmpty, let next = jobs.first(where: { $0.error == nil }) else { return }
        running[next.id] = Task { [weak self] in await self?.download(next) }
    }

    private func download(_ job: Job) async {
        let id = job.id
        let dir = folder(id)
        // Lets the download carry on for a short while when the app goes to the background.
        let background = UIApplication.shared.beginBackgroundTask(withName: id)
        defer {
            UIApplication.shared.endBackgroundTask(background)
            running[id] = nil
            progress.remove(id)
            pump()
        }
        let session = self.session
        do {
            let stream = try await AniverseAPI.shared.stream(animeId: job.anime.id, episode: job.episode.number, language: job.language)
            let playlist = try await HLSPlaylist.load(stream.source, session: session)
            let key = try await playlist.keyURL.asyncMap { try await DownloadManager.fetch($0, session: session) }

            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let total = playlist.segments.count
            var bytes: Int64 = 0
            var done = 0
            try await withThrowingTaskGroup(of: Int64.self) { group in
                var next = 0
                while next < min(maxConcurrentSegments, total) {
                    group.addTask(operation: Self.segmentTask(index: next, playlist: playlist, key: key, folder: dir, session: session))
                    next += 1
                }
                while let size = try await group.next() {
                    try Task.checkCancellation()
                    bytes += size
                    done += 1
                    progress.set(id, done: done, total: total)
                    if next < total {
                        group.addTask(operation: Self.segmentTask(index: next, playlist: playlist, key: key, folder: dir, session: session))
                        next += 1
                    }
                }
            }
            try playlist.localText().write(to: dir.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)

            var hasSubtitles = false
            if job.language == .sub, let url = stream.subtitles,
               let data = try? await DownloadManager.fetch(url, session: session) {
                hasSubtitles = (try? data.write(to: dir.appendingPathComponent("subtitles.vtt"), options: .atomic)) != nil
            }

            downloaded[id] = DownloadedEpisode(anime: job.anime, episode: job.episode, language: job.language,
                                               byteCount: bytes, downloadedAt: Date(), hasSubtitles: hasSubtitles)
            jobs.removeAll { $0.id == id }
            saveIndex()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            guard !(error is CancellationError), !Task.isCancelled else { return }
            if let index = jobs.firstIndex(where: { $0.id == id }) {
                jobs[index].error = error.localizedDescription
            }
        }
    }

    private nonisolated static func segmentTask(index: Int, playlist: HLSPlaylist, key: Data?, folder: URL, session: URLSession) -> @Sendable () async throws -> Int64 {
        return {
            var data = try await DownloadManager.fetch(playlist.segments[index].url, session: session)
            if let key {
                data = try decrypt(data, key: key, iv: playlist.iv ?? sequenceIV(playlist.mediaSequence + index))
            }
            try data.write(to: folder.appendingPathComponent(HLSPlaylist.localName(index)), options: .atomic)
            return Int64(data.count)
        }
    }

    /// Without an IV attribute, HLS uses the segment's media sequence number (big-endian, 16 bytes).
    nonisolated static func sequenceIV(_ number: Int) -> Data {
        Data(repeating: 0, count: 8) + withUnsafeBytes(of: UInt64(number).bigEndian) { Data($0) }
    }

    nonisolated static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var length = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, outputCount, &length)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw APIError.parsing("un segment vidéo") }
        output.count = length
        return output
    }

    private func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    private func saveIndex() {
        let snapshot = downloaded
        let name = indexName
        Task.detached(priority: .utility) { Persistence.save(snapshot, to: name) }
    }
}

/// The media playlist of an HLS stream (best variant of the master playlist).
struct HLSPlaylist: Sendable {
    struct Segment: Sendable {
        var duration: String
        var url: URL
    }

    var targetDuration: String
    var mediaSequence: Int
    var keyURL: URL?
    var iv: Data?
    var segments: [Segment]

    static func load(_ url: URL, session: URLSession) async throws -> HLSPlaylist {
        var url = url
        var text = String(decoding: try await DownloadManager.fetch(url, session: session), as: UTF8.self)
        if text.contains("#EXT-X-STREAM-INF") {
            let lines = text.components(separatedBy: .newlines)
            var best: (bandwidth: Int, url: URL)?
            for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0
                guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                      let variant = URL(string: uri.trimmingCharacters(in: .whitespaces), relativeTo: url)?.absoluteURL
                else { continue }
                if bandwidth >= (best?.bandwidth ?? -1) { best = (bandwidth, variant) }
            }
            guard let best else { throw APIError.parsing("la playlist vidéo") }
            url = best.url
            text = String(decoding: try await DownloadManager.fetch(url, session: session), as: UTF8.self)
        }
        return try parse(text, base: url)
    }

    // shortcut: a single #EXT-X-KEY for the whole playlist (what Aniverse serves); key rotation would need one key per segment.
    static func parse(_ text: String, base: URL) throws -> HLSPlaylist {
        var playlist = HLSPlaylist(targetDuration: "10", mediaSequence: 0, keyURL: nil, iv: nil, segments: [])
        var duration: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let value = line.value(after: "#EXT-X-TARGETDURATION:") {
                playlist.targetDuration = value
            } else if let value = line.value(after: "#EXT-X-MEDIA-SEQUENCE:") {
                playlist.mediaSequence = Int(value) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                switch attribute("METHOD", in: line) {
                case "AES-128":
                    guard let uri = attribute("URI", in: line), let keyURL = URL(string: uri, relativeTo: base)?.absoluteURL else {
                        throw APIError.parsing("la clé de la vidéo")
                    }
                    playlist.keyURL = keyURL
                    playlist.iv = attribute("IV", in: line).flatMap(hexData)
                case "NONE", nil:
                    break
                default:
                    throw APIError.parsing("le chiffrement de la vidéo")
                }
            } else if let value = line.value(after: "#EXTINF:") {
                duration = String(value.prefix { $0 != "," })
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL {
                playlist.segments.append(Segment(duration: duration ?? playlist.targetDuration, url: url))
                duration = nil
            }
        }
        guard !playlist.segments.isEmpty else { throw APIError.parsing("la playlist vidéo") }
        return playlist
    }

    /// Same timeline, decrypted local segments.
    func localText() -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:VOD",
                     "#EXT-X-TARGETDURATION:\(targetDuration)", "#EXT-X-MEDIA-SEQUENCE:0"]
        for (index, segment) in segments.enumerated() {
            lines.append("#EXTINF:\(segment.duration),")
            lines.append(Self.localName(index))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func localName(_ index: Int) -> String { String(format: "%04d.ts", index) }

    static func attribute(_ name: String, in line: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "[:,]\(name)=(\"[^\"]*\"|[^,]*)")
        guard let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return line[range].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func hexData(_ hex: String) -> Data? {
        let digits = Array(hex.lowercased().hasPrefix("0x") ? hex.dropFirst(2) : Substring(hex))
        guard digits.count == 32 else { return nil }
        var data = Data()
        for i in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(digits[i...i + 1]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
