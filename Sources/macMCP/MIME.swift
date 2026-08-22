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
        /// Where this part sits in the message: 1-based component numbers,
        /// outermost first, joined with "." -- `2`, `1.2`, `1.1.3`. The root of
        /// a `multipart/*` message carries "" because the message as a whole is
        /// not a part; a message that is a single part carries "1".
        ///
        /// This is not a label. It is **Mail's own identifier for the part**:
        /// `mail attachment.id` returns exactly this string, which is what makes
        /// it the thing to reconcile Mail's attachment list against. Measured on
        /// Mail 16 against four fixture messages -- `2`, `3`, `4` for three
        /// attachments of a flat `multipart/mixed`, and `1.2` for an inline
        /// image inside a `multipart/related` that is itself part 1 of a
        /// `multipart/mixed`, in a message four levels deep. It is the same
        /// numbering IMAP `BODYSTRUCTURE` uses.
        ///
        /// Everything else a part carries is a *description* of it and can be
        /// rendered two ways by two readers -- which is the whole of the
        /// attachment-namespace bug: Mail mangles a non-ASCII filename to
        /// Latin-1 mojibake, sanitises a "/" out of one, invents "Mail
        /// Attachment" for a part that has none, and reports `da"ta.csv` where
        /// the header says `da\"ta.csv`. The position does not depend on any of
        /// that.
        var path = ""
        /// Set on a `multipart/*` part whose children were **not** read, because
        /// a limit stopped the parse there. Its `body` is still the unread
        /// bytes; `parts` is empty because nothing was read, not because there
        /// is nothing in it. `MIME.Report` carries the same fact for the message
        /// as a whole, which is what reaches a caller.
        var unparsed = false

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
        /// `Part.path` -- the part's position in the message, and the only
        /// handle on it that two readers cannot render differently. See the doc
        /// comment there.
        let path: String
    }

    // MARK: - Limits

    /// How deep a `multipart/*` tree is descended before the reader stops and
    /// says so.
    ///
    /// Real messages need a handful of levels. `multipart/mixed` over
    /// `multipart/alternative` over `text/plain` -- the ordinary message with an
    /// attachment -- is 3, and the deepest shape in normal circulation,
    /// `multipart/signed` over `multipart/mixed` over `multipart/related` over
    /// `multipart/alternative` over `text/html`, is 5. Forwarded chains add
    /// none: this reader descends into `multipart/*` only and never opens a
    /// `message/rfc822` part, so a mail forwarded twenty times is still 5. The
    /// deepest thing in the testMail fixture's Maildir is 3. 32 is therefore
    /// about six times the deepest shape a human can produce.
    ///
    /// The cap is **not** a stack guard. `parseReporting` is iterative and its
    /// stack usage does not vary with depth, which is the point: a depth counter
    /// threaded through recursion leaves the crash one forgotten call site away.
    /// What the cap bounds is *work* -- every level holds its own copy of the
    /// bytes beneath it, so an uncapped descent is O(depth x size) in memory
    /// even with no stack left to exhaust.
    ///
    /// It replaces unbounded recursion, which was reachable from
    /// `mail_get_email` and `mail_save_attachment` and is sender-controlled: a
    /// 929 KB message nested ~13,000 deep exhausted the 8 MB main-thread stack
    /// and killed macmcp with SIGSEGV -- no response, no error, and all 46 tools
    /// gone with it, the process being one synchronous stdin loop. Measured:
    /// depth 12,000 parsed, depth 13,000 exited 139.
    static let maxDepth = 32

    /// How many parts one message may yield, across the whole tree.
    ///
    /// A digest or a bulk forward runs to dozens of parts; hundreds is already
    /// unusual. The ceiling is here because part count is sender-controlled too,
    /// and costs more than depth: the cheapest a part can be is a delimiter line
    /// and one byte, eight bytes in all, so a 70 MB body is nearly nine million
    /// of them -- each a `Part` with its own dictionaries, and each one
    /// `attachments(of:)` would hand to a caller as a JSON object.
    static let maxParts = 10_000

    /// How much of one part's header block is read.
    ///
    /// RFC 5322 puts no ceiling on a header block, and a message with **no**
    /// blank line in it -- which is what a truncated fetch looks like, and is
    /// deliberately treated as all headers -- makes the whole message one.
    /// Decoding 70 MB of "headers" into strings costs several times that for a
    /// result no consumer can use: everything this reader wants from a header
    /// block (`Content-Type`, `Content-Disposition`,
    /// `Content-Transfer-Encoding`, `Content-ID`) is in its first few hundred
    /// bytes. 256 KB is some 2,000 times an ordinary header block.
    static let maxHeaderBytes = 256 * 1024

    /// What a parse read, and what it stopped short of.
    ///
    /// A limit that is not reported is a lie. A message whose attachments sit
    /// below `maxDepth` comes back with a *shorter* attachment list, and a
    /// shorter list is indistinguishable from a message that simply has fewer
    /// attachments -- the same confident wrong answer `SourceFidelity` and
    /// `scan_complete` exist to prevent next door. So this is reported whether
    /// or not anything went wrong, and `parsed_complete` is a fact that can go
    /// either way rather than a field that only appears on failure.
    struct Report {
        /// Parts read, including the root.
        var parts = 0
        /// Deepest level reached. The root is 1.
        var depth = 0
        /// `multipart/*` parts whose children were not read.
        var unparsedMultiparts = 0
        var depthLimited = false
        var partLimited = false
        var headerLimited = false

        /// Whether every part of the message was read.
        var complete: Bool { !depthLimited && !partLimited && !headerLimited }

        var note: String? {
            guard !complete else { return nil }
            var sentences: [String] = []
            if depthLimited {
                sentences.append("This message nests multipart parts more than \(MIME.maxDepth) levels deep, so \(unparsedMultiparts) part(s) were left unread rather than descended into, and anything inside them — an attachment, a body — is not in this result. Real messages nest a handful of levels; a message shaped like this one is malformed or hostile.")
            }
            if partLimited {
                sentences.append("This message declares more than \(MIME.maxParts) parts and reading stopped there, so parts beyond that are not in this result.")
            }
            if headerLimited {
                sentences.append("At least one part carries more than \(MIME.maxHeaderBytes) bytes of headers and only the first \(MIME.maxHeaderBytes) were read, so a header declared past that point was not seen.")
            }
            return sentences.joined(separator: " ")
        }

        var dict: [String: Any] {
            var out: [String: Any] = [
                "parsed_complete": complete,
                "parts": parts,
                "depth": depth
            ]
            if !complete {
                out["unparsed_parts"] = unparsedMultiparts
                out["max_depth"] = MIME.maxDepth
                out["max_parts"] = MIME.maxParts
            }
            if let note { out["note"] = note }
            return out
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data) -> Part {
        parse(bytes: [UInt8](data))
    }

    static func parse(bytes: [UInt8]) -> Part {
        parseReporting(bytes: bytes).part
    }

    static func parseReporting(_ data: Data) -> (part: Part, report: Report) {
        parseReporting(bytes: [UInt8](data))
    }

    /// Parses a whole message, and says what it could not read.
    ///
    /// Iterative, over an explicit work list, rather than recursive. That is not
    /// a style preference: the recursion this replaces had no depth bound at
    /// all, and bounding it with a counter threaded through the call would have
    /// left every later multipart walk to remember the same thing. Here there is
    /// one descent and one place the limits are applied.
    ///
    /// Parts are built into a flat arena and the tree is assembled bottom-up at
    /// the end. That is sound because a child is always appended after its
    /// parent and so always has a higher index, which a breadth-first work list
    /// guarantees and a depth-first one would not.
    static func parseReporting(bytes: [UInt8]) -> (part: Part, report: Report) {
        var report = Report()
        var nodes: [(part: Part, children: [Int])] = []
        var pending: [(index: Int, depth: Int, path: String)] = []

        func addNode(_ raw: [UInt8], depth: Int, path: String) -> Int? {
            guard report.parts < maxParts else {
                report.partLimited = true
                return nil
            }
            report.parts += 1
            report.depth = max(report.depth, depth)
            var part = parseOne(raw, report: &report)
            part.path = path
            nodes.append((part, []))
            pending.append((nodes.count - 1, depth, path))
            return nodes.count - 1
        }

        // The root is the message, not a part of it, so it has no number of its
        // own -- its children are 1, 2, 3. A message that is a *single* part is
        // part 1, which is fixed up below once it is known not to be multipart.
        _ = addNode(bytes, depth: 1, path: "")

        var cursor = 0
        while cursor < pending.count {
            let (index, depth, path) = pending[cursor]
            cursor += 1
            guard nodes[index].part.isMultipart,
                  let boundary = nodes[index].part.parameters["boundary"],
                  !boundary.isEmpty else { continue }

            if depth >= maxDepth {
                report.depthLimited = true
                report.unparsedMultiparts += 1
                // Kept, not dropped: the part is still in the tree with its own
                // bytes, it is only not descended into. Nothing here invents a
                // structure it could not read.
                nodes[index].part.unparsed = true
                continue
            }

            // One more than the remaining budget, so a message that runs past
            // the ceiling is seen to run past it rather than landing on it.
            let budget = maxParts - report.parts
            let pieces = splitMultipart(nodes[index].part.body, boundary: boundary, limit: budget + 1)
            var readAll = true
            for (offset, piece) in pieces.enumerated() {
                let childPath = path.isEmpty ? "\(offset + 1)" : "\(path).\(offset + 1)"
                guard let child = addNode(piece, depth: depth + 1, path: childPath) else {
                    readAll = false
                    break
                }
                nodes[index].children.append(child)
            }
            if readAll {
                // A multipart part's own bytes *are* the parts below it, which
                // are now held separately. Keeping both is what makes a parse
                // cost O(depth x size) in memory rather than O(size).
                nodes[index].part.body = []
            } else {
                report.unparsedMultiparts += 1
                nodes[index].part.unparsed = true
            }
        }

        guard !nodes.isEmpty else { return (Part(), report) }
        // A message with no `multipart/*` at the top *is* part 1, which is what
        // IMAP numbers it and what Mail reports for an attachment that is the
        // whole message.
        if !nodes[0].part.isMultipart { nodes[0].part.path = "1" }
        for i in stride(from: nodes.count - 1, through: 0, by: -1) where !nodes[i].children.isEmpty {
            nodes[i].part.parts = nodes[i].children.map { nodes[$0].part }
        }
        return (nodes[0].part, report)
    }

    /// One part: its headers, its body, and the fields read off the headers.
    /// Descending into a `multipart/*` body is `parseReporting`'s job, which is
    /// what keeps the descent in one place.
    private static func parseOne(_ bytes: [UInt8], report: inout Report) -> Part {
        var part = Part()
        let split = splitHeadersAndBody(bytes)

        var headerEnd = min(split.headers.upperBound, split.headers.lowerBound + maxHeaderBytes)
        if headerEnd < split.headers.upperBound {
            report.headerLimited = true
            // Cut at a line boundary. Half a header line is not a header, and
            // `parseHeaders` gives the first occurrence of a name the field, so
            // a truncated one would win over a later real one.
            while headerEnd > split.headers.lowerBound && bytes[headerEnd - 1] != 0x0A { headerEnd -= 1 }
        }
        let headers = parseHeaders(Array(bytes[split.headers.lowerBound..<headerEnd]))
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
        return part
    }

    /// Flattens the part tree into the things a caller would call attachments:
    /// anything with a filename, plus anything explicitly dispositioned as one.
    /// The body parts of the message — text/plain and text/html with no
    /// filename — are skipped.
    ///
    /// Iterative for the same reason the parse is: this walk used to recurse
    /// over a tree whose depth the sender chose, which made it a second way to
    /// reach the same SIGSEGV. `parseReporting` now bounds the depth, and this
    /// no longer depends on that being true.
    static func attachments(of root: Part) -> [Attachment] {
        var out: [Attachment] = []
        var counter = 0
        // Children are pushed reversed so the stack yields them left to right,
        // which is the order the recursive walk produced and the order
        // `mail_save_attachment`'s `index` argument refers to.
        var stack: [Part] = [root]
        while let part = stack.popLast() {
            if part.isMultipart {
                stack.append(contentsOf: part.parts.reversed())
                continue
            }
            let disposition = part.disposition ?? ""
            let named = part.filename
            let isBodyPart = named == nil && disposition != "attachment"
                && (part.contentType == "text/plain" || part.contentType == "text/html")
            if isBodyPart { continue }
            if named == nil && disposition != "attachment" && part.contentID == nil { continue }

            counter += 1
            let mimeType = part.contentType.isEmpty ? "application/octet-stream" : part.contentType
            let name = named ?? "attachment-\(counter)\(defaultExtension(for: mimeType))"
            out.append(Attachment(
                name: name,
                mimeType: mimeType,
                data: part.decodedBody,
                inline: disposition == "inline" || (disposition.isEmpty && part.contentID != nil),
                contentID: part.contentID,
                path: part.path
            ))
        }
        return out
    }

    /// Whether a `multipart/*` message ends with the delimiter that closes it,
    /// or nil when the question does not apply — the message is not multipart,
    /// or declares no usable boundary.
    ///
    /// RFC 2046 requires a multipart body to end `--<boundary>--`. It is
    /// therefore a **structural** end-of-message marker, independent of any
    /// byte count, and it is the one check available on a message whose size
    /// can only be confirmed in units Mail does not name (see
    /// `MailService.SourceFidelity.completeBasis`). A message truncated
    /// anywhere before the last part's end does not have it, whatever its
    /// bytes add up to.
    ///
    /// The delimiter is looked for at the start of a line anywhere in the tail,
    /// not only at the very end. RFC 2046 §5.1.1 permits an epilogue after the
    /// close-delimiter, and requiring the delimiter to be the last thing in the
    /// message read a legal message as truncated — which cost the caller
    /// `mail_save_attachment` entirely, rather than costing them the stronger
    /// reading of it. A close-delimiter at a line start *is* where the multipart
    /// ends, wherever it sits, so finding it there is the question being asked.
    /// Requiring a line start still stops a body whose last line happens to end
    /// in those characters from standing in for it.
    ///
    /// The scan is bounded: an epilogue is a trailing note, not a payload, and
    /// on a 70 MB message a whole-buffer walk to answer a tail question is work
    /// nobody asked for. A close-delimiter further back than this is not
    /// distinguishable from a message that never had one.
    static func multipartIsTerminated(_ data: Data) -> Bool? {
        let bytes = [UInt8](data)
        guard let boundary = topLevelBoundary(bytes) else { return nil }
        let needle = [UInt8]("--\(boundary)--".utf8)
        guard bytes.count >= needle.count else { return false }
        let floor = max(0, bytes.count - maxEpilogueScan)
        var start = bytes.count - needle.count
        while start >= floor {
            var matched = true
            for i in 0..<needle.count where bytes[start + i] != needle[i] {
                matched = false
                break
            }
            // At the start of a line, or at the start of the message.
            if matched, start == 0 || bytes[start - 1] == 0x0A || bytes[start - 1] == 0x0D {
                return true
            }
            start -= 1
        }
        return false
    }

    /// How far back from the end `multipartIsTerminated` looks for the
    /// close-delimiter. Generous against any real epilogue, which is a trailing
    /// note; bounded so the check stays a tail question on a large message.
    static let maxEpilogueScan = 1 << 20

    /// The `boundary` parameter of the message's own `Content-Type`, when it is
    /// a `multipart/*`. Reads the header block only.
    private static func topLevelBoundary(_ bytes: [UInt8]) -> String? {
        let split = splitHeadersAndBody(bytes)
        let headerBytes = Array(bytes[headerScan(split.headers, in: bytes)])
        let headers = parseHeaders(headerBytes)
        guard let raw = headers["content-type"] else { return nil }
        let parsed = parseValueWithParameters(raw)
        guard parsed.value.lowercased().hasPrefix("multipart/") else { return nil }
        guard let boundary = parsed.parameters["boundary"], !boundary.isEmpty else { return nil }
        return boundary
    }

    /// The header range, capped the same way `parseOne` caps it: a message with
    /// no blank line in it is all headers on purpose, and reading megabytes of
    /// them to find one parameter is work nobody asked for.
    private static func headerScan(_ range: Range<Int>, in bytes: [UInt8]) -> Range<Int> {
        guard range.count > maxHeaderBytes else { return range }
        var cut = range.lowerBound + maxHeaderBytes
        while cut > range.lowerBound, bytes[cut - 1] != 0x0A { cut -= 1 }
        return range.lowerBound..<cut
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
            let value = String(token[token.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            rawParams[key] = unquote(value)
        }
        return (first.trimmingCharacters(in: .whitespaces), resolveParameters(rawParams))
    }

    /// Undoes an RFC 2045 quoted-string: the surrounding quotes **and** the
    /// backslash of every quoted-pair inside them.
    ///
    /// Stripping the quotes alone is what shipped, and it is wrong for exactly
    /// the character the quotes exist to carry. A part headed
    /// `Content-Type: image/png; name="da\"ta.csv"` came out as `da\"ta.csv`
    /// with the backslash still in it, while Mail -- which unquotes properly --
    /// reported `da"ta.csv`. Reconciling the two lists by name then saw two
    /// different names for one part and emitted it twice, once with the type the
    /// message declares and once with a type guessed from the ".csv" the
    /// backslash was not hiding: `text/csv` for a part the message calls
    /// `image/png`, which is verbatim the wrong answer `mime_type_source`
    /// exists to prevent.
    ///
    /// `splitOutsideQuotes` already tracks escapes when it decides where a
    /// parameter ends, so the token arriving here is well-formed; only the
    /// unescaping was missing.
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var out = ""
        var escaped = false
        for ch in raw.dropFirst().dropLast() {
            if escaped {
                out.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            out.append(ch)
        }
        // A trailing backslash inside the quotes escaped nothing; keep it
        // rather than swallowing a character of the sender's filename.
        if escaped { out.append("\\") }
        return out
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
    ///
    /// `limit` caps the parts produced. Without it a body of nothing but bare
    /// `--B` lines yields one part per four bytes -- 17 million of them for a
    /// 70 MB message -- and the delimiter list alone is collected in full before
    /// a single part is built. The caller passes its remaining part budget plus
    /// one, so a message that runs past the ceiling is seen to run past it.
    ///
    /// The scan cannot stall: `marker` is `--` plus a non-empty boundary, so
    /// every iteration advances `search` by at least three bytes.
    private static func splitMultipart(_ bytes: [UInt8], boundary: String, limit: Int) -> [[UInt8]] {
        guard limit > 0 else { return [] }
        let marker = [UInt8]("--\(boundary)".utf8)
        var delimiters: [(start: Int, afterLine: Int, isClose: Bool)] = []
        var search = 0
        while search < bytes.count && delimiters.count <= limit {
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
