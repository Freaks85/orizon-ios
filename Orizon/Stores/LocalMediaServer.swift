import Foundation
import Network

/// AVPlayer does not play an HLS playlist from a file URL, only over HTTP: this tiny server
/// serves the downloaded episodes on the loopback interface (http://127.0.0.1:<port>/…).
final class LocalMediaServer: @unchecked Sendable {
    static let shared = LocalMediaServer()

    private let queue = DispatchQueue(label: "orizon.local-media-server")
    // Only touched on `queue`.
    private var listener: NWListener?
    private var root: URL?

    /// HTTP URL of `file`, which must live under `root`.
    func url(for file: URL, root: URL) async throws -> URL {
        let port = try await start(root: root)
        let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
        guard let url = URL(string: "http://127.0.0.1:\(port)\(relative.hasPrefix("/") ? relative : "/" + relative)") else {
            throw APIError.parsing("l'épisode téléchargé")
        }
        return url
    }

    private func start(root: URL) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async {
                self.root = root
                if let listener = self.listener, listener.state == .ready, let port = listener.port?.rawValue {
                    continuation.resume(returning: port)
                    return
                }
                self.listener?.cancel()
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredInterfaceType = .loopback
                    parameters.acceptLocalOnly = true
                    let listener = try NWListener(using: parameters)
                    var resumed = false
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        switch state {
                        case .ready:
                            if !resumed, let port = listener?.port?.rawValue {
                                resumed = true
                                continuation.resume(returning: port)
                            }
                        case .failed(let error):
                            self?.listener = nil
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: error)
                            }
                        case .cancelled:
                            if !resumed {
                                resumed = true
                                continuation.resume(throwing: CancellationError())
                            }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = lines.first?.components(separatedBy: " ") ?? []
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD", let root,
              let path = request[1].components(separatedBy: "?").first?.removingPercentEncoding,
              !path.contains(".."),
              let data = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)
        else {
            send(connection, status: "404 Not Found", headers: [:], body: Data())
            return
        }

        var status = "200 OK"
        var body = data
        var headers = ["Content-Type": Self.mimeType(path), "Accept-Ranges": "bytes"]
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let range = Self.byteRange(rangeLine, size: data.count) {
            status = "206 Partial Content"
            body = data.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
        }
        send(connection, status: status, headers: headers, body: body, sendBody: request[0] == "GET")
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data, sendBody: Bool = true) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + (sendBody ? body : Data()), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }

    /// "Range: bytes=0-99", "bytes=100-" or "bytes=-50" → byte range within `size`.
    static func byteRange(_ header: String, size: Int) -> Range<Int>? {
        guard size > 0, let spec = header.split(separator: "=", maxSplits: 1).dropFirst().first else { return nil }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard bounds.count == 2 else { return nil }
        let start: Int
        let end: Int
        if let first = bounds[0] {
            start = first
            end = min(bounds[1] ?? size - 1, size - 1)
        } else if let suffix = bounds[1] {
            start = max(size - suffix, 0)
            end = size - 1
        } else {
            return nil
        }
        guard start <= end, start < size else { return nil }
        return start..<(end + 1)
    }
}
