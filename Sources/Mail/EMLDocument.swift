import Foundation
import UniformTypeIdentifiers

/// A complete RFC 822 / MIME message read from a .eml file (Save As output, or a file from any other mail app).
/// The part tree is a `BodyPart` numbered exactly like IMAP BODYSTRUCTURE ("1", "1.2", …), so the viewer uses the
/// same display-part and attachment rules as messages from the server. Parsing is pure Foundation and bounded.
struct EMLDocument {
    /// The standard type for .eml files (registered by Apple Mail; other apps use the same extension).
    static let type: UTType = UTType("com.apple.mail.email") ?? UTType(filenameExtension: "eml") ?? .data

    static let maxSize = 64 * 1024 * 1024
    static let maxDepth = 20
    static let maxParts = 500

    let headers: [String: String]
    let structure: BodyPart
    /// Raw (still transfer-encoded) bytes per leaf part id.
    let parts: [String: Data]

    var subject: String { headers["subject"] ?? "" }
    var from: EmailAddress { MIME.parseAddresses(headers["from"] ?? "").first ?? EmailAddress(name: "", email: "") }
    var to: String { headers["to"] ?? "" }
    var cc: String { headers["cc"] ?? "" }
    var date: Date? { headers["date"].flatMap(Self.parseDate) }

    enum ParseError: Error, LocalizedError {
        case tooLarge, notAMessage
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This message file is larger than 64 MB."
            case .notAMessage: return "This file isn't an email message."
            }
        }
    }

    static func parse(_ data: Data) throws -> EMLDocument {
        guard data.count <= maxSize else { throw ParseError.tooLarge }
        // One copy of the whole file into bytes; every level below works on slices of it (C-29), so a
        // deeply nested multipart never copies its whole body per nesting level.
        let bytes = [UInt8](data)
        let (headerBytes, body) = splitHeader(bytes[...])
        let headers = MIME.parseHeaders(Data(headerBytes))
        guard headers["from"] != nil || headers["subject"] != nil || headers["content-type"] != nil
                || headers["date"] != nil || headers["message-id"] != nil else { throw ParseError.notAMessage }
        var parts: [String: Data] = [:]
        var count = 0
        let structure = parseEntity(headers: headers, body: body, partID: "1", depth: 0, isRoot: true,
                                    parts: &parts, count: &count)
        return EMLDocument(headers: headers, structure: structure, parts: parts)
    }

    /// The decoded bytes of a leaf part.
    func data(for part: BodyPart) -> Data? {
        parts[part.partID].map { MIME.decode($0, encoding: part.encoding) }
    }

    /// Display bodies, decoded and charset-converted.
    func bodies() -> (html: String?, text: String?) {
        let (h, t) = structure.displayParts()
        let html = h.flatMap { data(for: $0) }.map { MIME.string(from: $0, charset: h?.charset) }
        let text = t.flatMap { data(for: $0) }.map { MIME.string(from: $0, charset: t?.charset) }
        return (html, text)
    }

    // MARK: Parsing

    /// Splits at the first empty line (CRLF CRLF or LF LF). Works on a slice of the byte array; no copies.
    static func splitHeader(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] == 10 {
                let next = bytes.index(after: i)
                if next < bytes.endIndex {
                    if bytes[next] == 10 { return (bytes[..<i], bytes[bytes.index(after: next)...]) }
                    let after = bytes.index(after: next)
                    if after < bytes.endIndex, bytes[next] == 13, bytes[after] == 10 {
                        return (bytes[..<i], bytes[bytes.index(after: after)...])
                    }
                }
            }
            i = bytes.index(after: i)
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    /// "type/subtype; a=b; c="d"" → (type, subtype, params) with lowercased names.
    static func parseContentType(_ raw: String?) -> (String, String, [String: String]) {
        let (value, params) = parseParams(raw ?? "text/plain")
        let ts = value.lowercased().split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ts.count == 2, !ts[0].isEmpty, !ts[1].isEmpty else { return ("text", "plain", params) }
        return (ts[0], ts[1], params)
    }

    /// "value; a=b; c="d;e"" → (value, [a: b, c: d;e]); quoted strings and backslash escapes honoured.
    static func parseParams(_ raw: String) -> (String, [String: String]) {
        var fields: [String] = []
        var cur = ""
        var inQuote = false
        var escaped = false
        for ch in raw {
            if escaped { cur.append(ch); escaped = false; continue }
            if ch == "\\" && inQuote { escaped = true; continue }
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == ";" && !inQuote { fields.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        fields.append(cur)
        let value = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var params: [String: String] = [:]
        for f in fields.dropFirst() {
            guard let eq = f.firstIndex(of: "=") else { continue }
            let k = f[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = f[f.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { params[k] = v }
        }
        return (value, params)
    }

    private static func parseEntity(headers: [String: String], body: ArraySlice<UInt8>, partID: String, depth: Int, isRoot: Bool,
                                    parts: inout [String: Data], count: inout Int) -> BodyPart {
        count += 1
        let (type, subtype, params) = parseContentType(headers["content-type"])
        let (disp, dispParams) = headers["content-disposition"].map { parseParams($0) } ?? ("", [:])
        var part = BodyPart(partID: partID, type: type, subtype: subtype, params: params,
                            contentID: headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")),
                            encoding: (headers["content-transfer-encoding"] ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased(),
                            size: body.count, disposition: disp.isEmpty ? nil : disp.lowercased(), dispositionParams: dispParams)
        if type == "multipart", let boundary = params["boundary"], !boundary.isEmpty {
            // The caps stop recursion here: the part is marked truncated (never stored as a leaf, so Save As
            // cannot write a still-encoded multipart as if it were one file) and gets no raw bytes (C-29).
            if depth >= maxDepth || count >= maxParts {
                part.truncated = true
                return part
            }
            let sections = split(body, boundary: boundary)
            var children: [BodyPart] = []
            for (i, section) in sections.enumerated() where count < maxParts {
                let (h, b) = splitHeader(section)
                let childID = isRoot ? "\(i + 1)" : "\(partID).\(i + 1)"
                children.append(parseEntity(headers: MIME.parseHeaders(Data(h)), body: b, partID: childID, depth: depth + 1,
                                            isRoot: false, parts: &parts, count: &count))
            }
            if children.count < sections.count { part.truncated = true }
            part.partID = isRoot ? "TEXT" : partID
            part.children = children
            return part
        }
        // Only the leaf's own bytes are materialised (one copy, in total bounded by the file size).
        parts[partID] = Data(body)
        return part
    }

    /// Body sections between "--boundary" lines, up to "--boundary--". Each section excludes the CRLF that
    /// belongs to the following delimiter. Works on a slice of the byte array; no copies.
    static func split(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let bytes = body
        let delim = Array(("--" + boundary).utf8)
        func matches(_ at: ArraySlice<UInt8>.Index) -> Bool {
            var k = at
            for d in delim {
                guard k < bytes.endIndex, bytes[k] == d else { return false }
                k = bytes.index(after: k)
            }
            return true
        }
        var starts: [(lineStart: Int, contentStart: Int, closing: Bool)] = []
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let atLineStart = i == bytes.startIndex || bytes[bytes.index(before: i)] == 10
            if atLineStart, matches(i) {
                var j = i
                for _ in delim { j = bytes.index(after: j) }
                let j1 = bytes.index(after: j)
                let closing = j < bytes.endIndex && bytes[j] == 45 && j1 < bytes.endIndex && bytes[j1] == 45
                while j < bytes.endIndex && bytes[j] != 10 { j = bytes.index(after: j) }
                let contentStart = j < bytes.endIndex ? bytes.index(after: j) : j
                starts.append((i, contentStart, closing))
                if closing { break }
                guard j < bytes.endIndex else { break }
                i = bytes.index(after: j)
                continue
            }
            while i < bytes.endIndex && bytes[i] != 10 { i = bytes.index(after: i) }
            if i < bytes.endIndex { i = bytes.index(after: i) }
        }
        var out: [ArraySlice<UInt8>] = []
        for (n, s) in starts.enumerated() where !s.closing {
            var end = n + 1 < starts.count ? starts[n + 1].lineStart : bytes.endIndex
            // Drop the line break that precedes the next delimiter.
            if end > s.contentStart, bytes[bytes.index(before: end)] == 10 { end = bytes.index(before: end) }
            if end > s.contentStart, bytes[bytes.index(before: end)] == 13 { end = bytes.index(before: end) }
            out.append(end > s.contentStart ? bytes[s.contentStart..<end] : bytes[bytes.endIndex...])
        }
        return out
    }

    private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
                                      "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm zzz",
                                      "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz",
                                      "d MMM yyyy HH:mm Z",
                                      "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ",
                                      "EEE MMM d HH:mm:ss yyyy"]
    private static let isoDateParser = ISO8601DateFormatter()

    static func parseDate(_ raw: String) -> Date? {
        // Drop comments such as "(UTC)".
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        // Collapse runs of whitespace (asctime dates pad single-digit days: "Sun Nov  9 …").
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return isoDateParser.date(from: s)
    }
}
