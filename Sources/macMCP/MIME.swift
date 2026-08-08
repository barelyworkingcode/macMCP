import Foundation
import UniformTypeIdentifiers

/// A small RFC 822/2045 reader, just enough to pull attachments out of a raw
/// message.
///
/// It exists because Mail refuses to hand attachments over any other way:
/// `save` on a `mail attachment` is blocked by Mail's own sandbox (-10004,
/// "The sender does not have permission to write to the specified path") for
/// every destination including `~/Downloads`, and the `MIME type` property of
/// `mail attachment` raises "AppleEvent handler failed" on any message that
/// actually has one. What does work is `source`, so the bytes are fetched as
/// raw RFC 822 and decoded here, where nothing is sandboxed.
///
/// Everything runs on `[UInt8]` rather than `Data` because the parser slices
/// constantly and `Data` slices keep their parent's index base, which makes
/// off-by-one bugs easy to write and hard to see.
enum MIME {
    struct Part {
        var contentType = "text/plain"
        var parameters: [String: String] = [:]
        var disposition: String?
        var dispositionParameters: [String: String] = [:]
        var encoding = "7bit"
        var contentID: String?
        var body: [UInt8] = []
        var parts: [Part] = []

        var isMultipart: Bool { contentType.hasPrefix("multipart/") }

        /// RFC 2183 filename, falling back to the RFC 2045 `name` parameter
        /// that older senders use instead.
        var filename: String? {
            dispositionParameters["filename"] ?? parameters["name"]
        }

        var decodedBody: Data { MIME.decodeBody(body, encoding: encoding) }
    }

    struct Attachment {
        let name: String
        let mimeType: String
        let data: Data
        /// Inline parts (a signature image, a logo) are attachments as far as
        /// MIME is concerned but rarely what a caller asked for, so they are
        /// flagged rather than dropped.
        let inline: Bool
        let contentID: String?
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Part {
        parse(bytes: [UInt8](data))
    }

    static func parse(bytes: [UInt8]) -> Part {
        var part = Part()
        let split = splitHeadersAndBody(bytes)
        let headers = parseHeaders(Array(bytes[split.headers]))
        part.body = Array(bytes[split.body])

        if let ctype = headers["content-type"] {
            let parsed = parseValueWithParameters(ctype)
            part.contentType = parsed.value.lowercased()
            part.parameters = parsed.parameters
        }
        if let disp = headers["content-disposition"] {
            let parsed = parseValueWithParameters(disp)
            part.disposition = parsed.value.lowercased()
            part.dispositionParameters = parsed.parameters
        }
        if let enc = headers["content-transfer-encoding"] {
            part.encoding = enc.trimmingCharacters(in: .whitespaces).lowercased()
        }
        part.contentID = headers["content-id"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))

        if part.isMultipart, let boundary = part.parameters["boundary"], !boundary.isEmpty {
            part.parts = splitMultipart(part.body, boundary: boundary).map { parse(bytes: $0) }
        }
        return part
    }

    /// Flattens the part tree into the things a caller would call attachments:
    /// anything with a filename, plus anything explicitly dispositioned as one.
    /// The body parts of the message — text/plain and text/html with no
    /// filename — are skipped.
    static func attachments(of root: Part) -> [Attachment] {
        var out: [Attachment] = []
        var counter = 0
        func walk(_ part: Part) {
            if part.isMultipart {
                part.parts.forEach(walk)
                return
            }
            let disposition = part.disposition ?? ""
            let named = part.filename
            let isBodyPart = named == nil && disposition != "attachment"
                && (part.contentType == "text/plain" || part.contentType == "text/html")
            if isBodyPart { return }
            if named == nil && disposition != "attachment" && part.contentID == nil { return }

            counter += 1
            let mimeType = part.contentType.isEmpty ? "application/octet-stream" : part.contentType
            let name = named ?? "attachment-\(counter)\(defaultExtension(for: mimeType))"
            out.append(Attachment(
                name: name,
                mimeType: mimeType,
                data: part.decodedBody,
                inline: disposition == "inline" || (disposition.isEmpty && part.contentID != nil),
                contentID: part.contentID
            ))
        }
        walk(root)
        return out
    }

    // MARK: - Header handling

    /// Returns the header block and body ranges, split at the first empty line.
    /// A message with no blank line at all is all headers — that is what a
    /// truncated fetch looks like, and treating it as a body would produce a
    /// bogus attachment.
    private static func splitHeadersAndBody(_ bytes: [UInt8]) -> (headers: Range<Int>, body: Range<Int>) {
        var i = 0
        while i < bytes.count {
            guard let lineEnd = index(of: 0x0A, in: bytes, from: i) else { break }
            // An empty line is "\n" or "\r\n" -- nothing before the newline.
            let contentEnd = (lineEnd > i && bytes[lineEnd - 1] == 0x0D) ? lineEnd - 1 : lineEnd
            if contentEnd == i {
                return (0..<i, (lineEnd + 1)..<bytes.count)
            }
            i = lineEnd + 1
        }
        return (0..<bytes.count, bytes.count..<bytes.count)
    }

    /// Unfolds continuation lines and lowercases names. Later duplicates lose
    /// to the first, which is what mail readers do for Content-Type.
    private static func parseHeaders(_ bytes: [UInt8]) -> [String: String] {
        let text = decodeString(bytes, charset: "utf-8")
        var headers: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func flush() {
            if let name = currentName, headers[name] == nil {
                headers[name] = currentValue.trimmingCharacters(in: .whitespaces)
            }
            currentName = nil
            currentValue = ""
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            currentName = String(line[line.startIndex..<colon]).lowercased()
            currentValue = String(line[line.index(after: colon)...])
        }
        flush()
        return headers
    }

    /// Splits `value; key=val; key2="val 2"` into its value and parameters,
    /// resolving RFC 2231 continuations/charsets and RFC 2047 words.
    private static func parseValueWithParameters(_ raw: String) -> (value: String, parameters: [String: String]) {
        let tokens = splitOutsideQuotes(raw, separator: ";")
        guard let first = tokens.first else { return ("", [:]) }
        var rawParams: [String: String] = [:]
        for token in tokens.dropFirst() {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(token[token.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            rawParams[key] = value
        }
        return (first.trimmingCharacters(in: .whitespaces), resolveParameters(rawParams))
    }

    /// Folds `name*0`, `name*1*`, `name*` back into `name`. Segments are
    /// concatenated in numeric order; any extended segment (`*` suffix) carries
    /// its own charset and is percent-decoded.
    private static func resolveParameters(_ raw: [String: String]) -> [String: String] {
        var segments: [String: [(index: Int, value: String, extended: Bool)]] = [:]
        for (key, value) in raw {
            var base = key
            var index = 0
            var extended = false
            if base.hasSuffix("*") {
                extended = true
                base = String(base.dropLast())
            }
            if let star = base.lastIndex(of: "*"), let n = Int(base[base.index(after: star)...]) {
                index = n
                base = String(base[base.startIndex..<star])
            }
            segments[base, default: []].append((index, value, extended))
        }

        var out: [String: String] = [:]
        for (base, parts) in segments {
            let ordered = parts.sorted { $0.index < $1.index }
            var value = ""
            var charset = "utf-8"
            for (offset, part) in ordered.enumerated() {
                if part.extended {
                    var text = part.value
                    // Only the first segment carries `charset'language'`.
                    if offset == 0 {
                        let bits = text.components(separatedBy: "'")
                        if bits.count >= 3 {
                            if !bits[0].isEmpty { charset = bits[0].lowercased() }
                            text = bits.dropFirst(2).joined(separator: "'")
                        }
                    }
                    value += percentDecode(text, charset: charset)
                } else {
                    value += part.value
                }
            }
            out[base] = decodeEncodedWords(value)
        }
        return out
    }

    // MARK: - Multipart

    /// Returns each part's bytes, delimited by `--boundary` lines. The preamble
    /// before the first delimiter and the epilogue after the closing one are
    /// discarded, per RFC 2046.
    private static func splitMultipart(_ bytes: [UInt8], boundary: String) -> [[UInt8]] {
        let marker = [UInt8]("--\(boundary)".utf8)
        var delimiters: [(start: Int, afterLine: Int, isClose: Bool)] = []
        var search = 0
        while search < bytes.count {
            guard let hit = index(of: marker, in: bytes, from: search) else { break }
            let atLineStart = hit == 0 || bytes[hit - 1] == 0x0A
            if atLineStart {
                let lineEnd = index(of: 0x0A, in: bytes, from: hit) ?? bytes.count
                let tail = Array(bytes[(hit + marker.count)..<min(lineEnd, bytes.count)])
                let trimmed = tail.filter { $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }
                // Anything other than "" or "--" after the marker means this
                // was a longer boundary that merely starts the same way.
                if trimmed.isEmpty || trimmed == [0x2D, 0x2D] {
                    delimiters.append((hit, min(lineEnd + 1, bytes.count), trimmed.count == 2))
                }
            }
            search = hit + marker.count
        }

        var out: [[UInt8]] = []
        for (i, delimiter) in delimiters.enumerated() {
            if delimiter.isClose { break }
            let start = delimiter.afterLine
            var end = i + 1 < delimiters.count ? delimiters[i + 1].start : bytes.count
            // The CRLF before the next delimiter belongs to the delimiter.
            if end > start && bytes[end - 1] == 0x0A { end -= 1 }
            if end > start && bytes[end - 1] == 0x0D { end -= 1 }
            if end > start { out.append(Array(bytes[start..<end])) }
        }
        return out
    }

    // MARK: - Decoding

    private static func decodeBody(_ bytes: [UInt8], encoding: String) -> Data {
        switch encoding {
        case "base64":
            let text = String(decoding: bytes, as: UTF8.self)
            return Data(base64Encoded: text, options: .ignoreUnknownCharacters) ?? Data(bytes)
        case "quoted-printable":
            return decodeQuotedPrintable(bytes)
        default:
            return Data(bytes)
        }
    }

    private static func decodeQuotedPrintable(_ bytes: [UInt8]) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x3D else {  // '='
                out.append(bytes[i])
                i += 1
                continue
            }
            if i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 2; continue }
            if i + 2 < bytes.count && bytes[i + 1] == 0x0D && bytes[i + 2] == 0x0A { i += 3; continue }
            if i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return Data(out)
    }

    /// RFC 2047 `=?charset?B?...?=` / `=?charset?Q?...?=` words, as they appear
    /// in filenames and subjects.
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = ""
        var rest = Substring(s)
        while let start = rest.range(of: "=?") {
            out += rest[rest.startIndex..<start.lowerBound]
            let afterStart = rest[start.upperBound...]
            guard let end = afterStart.range(of: "?=") else {
                out += rest[start.lowerBound...]
                return out
            }
            let word = afterStart[afterStart.startIndex..<end.lowerBound]
            let fields = word.components(separatedBy: "?")
            if fields.count == 3 {
                let charset = fields[0].lowercased()
                let payload = fields[2]
                let bytes: [UInt8]
                switch fields[1].lowercased() {
                case "b":
                    bytes = [UInt8](Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data())
                case "q":
                    // In encoded words '_' stands for a space.
                    bytes = [UInt8](decodeQuotedPrintable([UInt8](payload.replacingOccurrences(of: "_", with: " ").utf8)))
                default:
                    bytes = [UInt8](payload.utf8)
                }
                out += decodeString(bytes, charset: charset)
            } else {
                out += "=?" + word + "?="
            }
            rest = afterStart[end.upperBound...]
        }
        out += rest
        return out
    }

    private static func percentDecode(_ s: String, charset: String) -> String {
        var bytes: [UInt8] = []
        var chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x25, i + 2 < chars.count,  // '%'
               let hi = hexValue(chars[i + 1]), let lo = hexValue(chars[i + 2]) {
                bytes.append(hi << 4 | lo)
                i += 3
            } else {
                bytes.append(chars[i])
                i += 1
            }
        }
        chars = []
        return decodeString(bytes, charset: charset)
    }

    private static func decodeString(_ bytes: [UInt8], charset: String) -> String {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii", "": encoding = .utf8
        case "iso-8859-1", "latin1", "latin-1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16", "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        default: encoding = .utf8
        }
        let data = Data(bytes)
        if let s = String(data: data, encoding: encoding) { return s }
        // Mail sources routinely mix declared and actual charsets; latin1 maps
        // every byte, so it never fails and never loses data.
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Small helpers

    /// Mail's `MIME type` property on `mail attachment` is broken (it raises
    /// "AppleEvent handler failed" on every message that has an attachment), so
    /// the type is inferred from the extension instead.
    static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    private static func defaultExtension(for mimeType: String) -> String {
        guard let type = UTType(mimeType: mimeType),
              let ext = type.preferredFilenameExtension else { return "" }
        return "." + ext
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private static func index(of byte: UInt8, in bytes: [UInt8], from: Int) -> Int? {
        var i = from
        while i < bytes.count {
            if bytes[i] == byte { return i }
            i += 1
        }
        return nil
    }

    private static func index(of needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        let first = needle[0]
        var i = from
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == first {
                var match = true
                var j = 1
                while j < needle.count {
                    if bytes[i + j] != needle[j] { match = false; break }
                    j += 1
                }
                if match { return i }
            }
            i += 1
        }
        return nil
    }

    private static func splitOutsideQuotes(_ s: String, separator: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            switch ch {
            case "\\" where inQuotes: current.append(ch); escaped = true
            case "\"": inQuotes.toggle(); current.append(ch)
            case separator where !inQuotes: out.append(current); current = ""
            default: current.append(ch)
            }
        }
        out.append(current)
        return out
    }
}
