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
        let (headerData, body) = splitHeader(data)
        let headers = MIME.parseHeaders(headerData)
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

    /// Splits at the first empty line (CRLF CRLF or LF LF).
    static func splitHeader(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 10 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { return (data.subdata(in: 0..<i), data.subdata(in: i + 2..<bytes.count)) }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 {
                    return (data.subdata(in: 0..<i), data.subdata(in: i + 3..<bytes.count))
                }
            }
            i += 1
        }
        return (data, Data())
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

    private static func parseEntity(headers: [String: String], body: Data, partID: String, depth: Int, isRoot: Bool,
                                    parts: inout [String: Data], count: inout Int) -> BodyPart {
        count += 1
        let (type, subtype, params) = parseContentType(headers["content-type"])
        let (disp, dispParams) = headers["content-disposition"].map { parseParams($0) } ?? ("", [:])
        var part = BodyPart(partID: partID, type: type, subtype: subtype, params: params,
                            contentID: headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")),
                            encoding: (headers["content-transfer-encoding"] ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased(),
                            size: body.count, disposition: disp.isEmpty ? nil : disp.lowercased(), dispositionParams: dispParams)
        if type == "multipart", depth < maxDepth, count < maxParts, let boundary = params["boundary"], !boundary.isEmpty {
            let sections = split(body, boundary: boundary)
            var children: [BodyPart] = []
            for (i, section) in sections.enumerated() where count < maxParts {
                let (h, b) = splitHeader(section)
                let childID = isRoot ? "\(i + 1)" : "\(partID).\(i + 1)"
                children.append(parseEntity(headers: MIME.parseHeaders(h), body: b, partID: childID, depth: depth + 1,
                                            isRoot: false, parts: &parts, count: &count))
            }
            part.partID = isRoot ? "TEXT" : partID
            part.children = children
            return part
        }
        parts[partID] = body
        return part
    }

    /// Body sections between "--boundary" lines, up to "--boundary--". Each section excludes the CRLF that
    /// belongs to the following delimiter.
    static func split(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delim = Array(("--" + boundary).utf8)
        var starts: [(lineStart: Int, contentStart: Int, closing: Bool)] = []
        var i = 0
        while i < bytes.count {
            let atLineStart = i == 0 || bytes[i - 1] == 10
            if atLineStart, i + delim.count <= bytes.count, Array(bytes[i..<i + delim.count]) == delim {
                var j = i + delim.count
                let closing = j + 1 < bytes.count && bytes[j] == 45 && bytes[j + 1] == 45
                while j < bytes.count && bytes[j] != 10 { j += 1 }
                starts.append((i, min(j + 1, bytes.count), closing))
                if closing { break }
                i = j + 1
                continue
            }
            while i < bytes.count && bytes[i] != 10 { i += 1 }
            i += 1
        }
        var out: [Data] = []
        for (n, s) in starts.enumerated() where !s.closing {
            var end = n + 1 < starts.count ? starts[n + 1].lineStart : bytes.count
            // Drop the line break that precedes the next delimiter.
            if end > s.contentStart, bytes[end - 1] == 10 { end -= 1 }
            if end > s.contentStart, bytes[end - 1] == 13 { end -= 1 }
            out.append(end > s.contentStart ? body.subdata(in: s.contentStart..<end) : Data())
        }
        return out
    }

    private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
                                      "EEE, d MMM yyyy HH:mm:ss zzz"]

    static func parseDate(_ raw: String) -> Date? {
        // Drop comments such as "(UTC)".
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
