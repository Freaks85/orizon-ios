import Foundation

/// Helpers to read data out of a Next.js App Router page.
///
/// The server-rendered HTML embeds the React Server Components "flight" payload as
/// `self.__next_f.push([1,"..."])` script chunks. Once concatenated, the flight text is a
/// series of rows `<hex id>:<json>\n`, where large values can be moved to their own row and
/// referenced as `"$@<hex id>"`.
struct Flight {
    let bytes: [UInt8]

    init(html: String) {
        self.init(data: Data(html.utf8))
    }

    init(data: Data) {
        let source = [UInt8](data)
        let assembled = Flight.assemble(source)
        bytes = assembled.isEmpty ? source : assembled
    }

    /// Works on the raw UTF-8 bytes: walking a page of several hundred KB as Swift `Character`s
    /// (grapheme clusters) is many times slower. Quotes and backslashes are ASCII, so they can
    /// never appear inside a multi-byte character.
    private static func assemble(_ html: [UInt8]) -> [UInt8] {
        let marker = Array("self.__next_f.push([1,\"".utf8)
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var result: [UInt8] = []
        var from = 0
        while let found = firstOffset(of: marker, in: html, from: from) {
            // The JS string literal starts at the opening quote (last byte of the marker).
            let literalStart = found + marker.count - 1
            var i = found + marker.count
            var escaped = false
            while i < html.count {
                let c = html[i]
                if escaped {
                    escaped = false
                } else if c == backslash {
                    escaped = true
                } else if c == quote {
                    break
                }
                i += 1
            }
            guard i < html.count else { break }
            if let decoded = try? JSONSerialization.jsonObject(with: Data(html[literalStart...i]), options: .fragmentsAllowed) as? String {
                result.append(contentsOf: decoded.utf8)
            }
            from = i + 1
        }
        return result
    }

    private static func firstOffset(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        let first = needle[0]
        var i = start
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var match = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - JSON extraction

    /// Parses the balanced JSON object/array starting at `start`.
    func json(at start: Int) -> Any? {
        guard start < bytes.count else { return nil }
        let open = bytes[start]
        guard open == UInt8(ascii: "{") || open == UInt8(ascii: "[") else { return nil }
        var depth = 0
        var inString = false
        var i = start
        while i < bytes.count {
            let c = bytes[i]
            if inString {
                if c == UInt8(ascii: "\\") {
                    i += 1
                } else if c == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                depth += 1
            } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 {
                    let data = Data(bytes[start...i])
                    return try? JSONSerialization.jsonObject(with: data)
                }
            }
            i += 1
        }
        return nil
    }

    /// Offsets right after each occurrence of `"key":`.
    func valueOffsets(forKey key: String) -> [Int] {
        offsets(of: Array("\"\(key)\":".utf8))
    }

    /// First JSON value for `key` that passes `accept`.
    func first(key: String, where accept: (Any) -> Bool) -> Any? {
        for offset in valueOffsets(forKey: key) {
            if let value = json(at: offset), accept(value) {
                return value
            }
        }
        return nil
    }

    /// Resolves a `"$@<id>"` reference found as the string value of `key`.
    func reference(forKey key: String) -> Any? {
        for offset in valueOffsets(forKey: key) {
            guard offset + 3 < bytes.count,
                  bytes[offset] == UInt8(ascii: "\""),
                  bytes[offset + 1] == UInt8(ascii: "$"),
                  bytes[offset + 2] == UInt8(ascii: "@") else { continue }
            var end = offset + 3
            while end < bytes.count, bytes[end] != UInt8(ascii: "\"") { end += 1 }
            let id = Array(bytes[(offset + 3)..<end])
            if let value = row(id) { return value }
        }
        return nil
    }

    private func row(_ id: [UInt8]) -> Any? {
        let needle = [UInt8(ascii: "\n")] + id + [UInt8(ascii: ":")]
        if let at = offsets(of: needle).first {
            return json(at: at)
        }
        // The row may be the very first one in the payload.
        let head = id + [UInt8(ascii: ":")]
        if bytes.starts(with: head) {
            return json(at: head.count)
        }
        return nil
    }

    private func offsets(of needle: [UInt8]) -> [Int] {
        guard !needle.isEmpty, bytes.count >= needle.count else { return [] }
        var result: [Int] = []
        let first = needle[0]
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == first {
                var match = true
                for j in 1..<needle.count where bytes[i + j] != needle[j] {
                    match = false
                    break
                }
                if match {
                    result.append(i + needle.count)
                    i += needle.count
                    continue
                }
            }
            i += 1
        }
        return result
    }
}
