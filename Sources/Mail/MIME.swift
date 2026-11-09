import Foundation

/// MIME decoding helpers: transfer encodings, charsets, RFC 2047 encoded words, RFC 2231 parameters,
/// header and address parsing. Pure Foundation so it runs off the main thread and in the self-test.
enum MIME {

    // MARK: Transfer encodings

    static func decode(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased() {
        case "base64": return decodeBase64(data)
        case "quoted-printable": return decodeQuotedPrintable(data)
        default: return data
        }
    }

    static func decodeBase64(_ data: Data) -> Data {
        var clean = [UInt8]()
        clean.reserveCapacity(data.count)
        // Ignore every '=' (valid or misplaced) and re-pad, so malformed padding can't blank the payload.
        for b in data where isBase64Char(b) && b != UInt8(ascii: "=") { clean.append(b) }
        while clean.count % 4 != 0 { clean.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    @inline(__always) static func isBase64Char(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47 || b == 61
    }

    static func decodeQuotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                if i + 1 < bytes.count, bytes[i + 1] == 13 || bytes[i + 1] == 10 {
                    // Soft line break: skip "=\r\n" or "=\n".
                    i += (bytes[i + 1] == 13 && i + 2 < bytes.count && bytes[i + 2] == 10) ? 3 : 2
                    continue
                }
                if i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(b)
                i += 1
            } else if underscoreIsSpace && b == UInt8(ascii: "_") {
                out.append(32)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return Data(out)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    // MARK: Charsets

    static func string(from data: Data, charset: String?) -> String {
        if let cs = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased(), !cs.isEmpty {
            if cs == "utf-8" || cs == "utf8" || cs == "us-ascii" || cs == "ascii" {
                if let s = String(data: data, encoding: .utf8) { return s }
            } else {
                let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
                if cf != kCFStringEncodingInvalidId {
                    let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                    if let s = String(data: data, encoding: enc) { return s }
                }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Headers

    /// Parses a raw header block into lowercased name → unfolded, decoded value (first occurrence wins).
    static func parseHeaders(_ data: Data) -> [String: String] {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var result: [String: String] = [:]
        var currentName: String?
        var currentValue = ""
        func flush() {
            if let n = currentName, result[n] == nil {
                result[n] = decodeEncodedWords(currentValue.trimmingCharacters(in: .whitespaces))
            }
        }
        for line in raw.components(separatedBy: "\n") {
            let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if l.isEmpty { continue }
            if let first = l.first, first == " " || first == "\t" {
                currentValue += " " + l.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            if let colon = l.firstIndex(of: ":") {
                currentName = l[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = String(l[l.index(after: colon)...])
            } else {
                currentName = nil
                currentValue = ""
            }
        }
        flush()
        return result
    }

    private static let encodedWord = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?]*)\\?=")

    /// Decodes RFC 2047 encoded words ("=?UTF-8?B?...?="). Whitespace between adjacent words is dropped.
    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let ns = s as NSString
        let matches = encodedWord.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        var previousWasWord = false
        for m in matches {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(previousWasWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                out += gap
            }
            let charset = ns.substring(with: m.range(at: 1)).components(separatedBy: "*").first ?? "utf-8"
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data: Data
            if mode == "B" {
                data = decodeBase64(Data(text.utf8))
            } else {
                data = decodeQuotedPrintable(Data(text.utf8), underscoreIsSpace: true)
            }
            out += string(from: data, charset: charset)
            last = m.range.location + m.range.length
            previousWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    /// Decodes RFC 2231 parameter values ("UTF-8''na%C3%AFve.pdf").
    static func decodeRFC2231(_ value: String) -> String {
        let parts = value.components(separatedBy: "'")
        guard parts.count >= 3 else { return value.removingPercentEncoding ?? value }
        let charset = parts[0]
        let encoded = parts[2...].joined(separator: "'")
        var bytes = [UInt8]()
        var i = encoded.utf8.startIndex
        let u = encoded.utf8
        while i < u.endIndex {
            let c = u[i]
            if c == UInt8(ascii: "%"), let j = u.index(i, offsetBy: 2, limitedBy: u.endIndex), j < u.endIndex,
               let h = hexValue(u[u.index(after: i)]), let l = hexValue(u[j]) {
                bytes.append(h << 4 | l)
                i = u.index(after: j)
            } else {
                bytes.append(c)
                i = u.index(after: i)
            }
        }
        return string(from: Data(bytes), charset: charset.isEmpty ? "utf-8" : charset)
    }

    /// Resolves a parameter from a dictionary that may hold "name", "name*", or "name*0*", "name*1*" continuations.
    static func parameter(_ name: String, in params: [String: String]) -> String? {
        let key = name.lowercased()
        if let v = params[key + "*"] { return decodeRFC2231(v) }
        if let v = params[key] { return decodeEncodedWords(v) }
        var pieces: [(Int, String, Bool)] = []
        for (k, v) in params where k.hasPrefix(key + "*") {
            let rest = k.dropFirst(key.count + 1)
            let encoded = rest.hasSuffix("*")
            if let n = Int(encoded ? rest.dropLast() : rest) { pieces.append((n, v, encoded)) }
        }
        guard !pieces.isEmpty else { return nil }
        pieces.sort { $0.0 < $1.0 }
        let joined = pieces.map { $0.1 }.joined()
        return pieces.first!.2 ? decodeRFC2231(joined) : joined
    }

    // MARK: Addresses

    static func parseAddresses(_ s: String) -> [EmailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var inAngle = false
        for ch in s {
            switch ch {
            case "\"": inQuote.toggle(); current.append(ch)
            case "<" where !inQuote: inAngle = true; current.append(ch)
            case ">" where !inQuote: inAngle = false; current.append(ch)
            case ",", ";":
                if inQuote || inAngle { current.append(ch) } else { parts.append(current); current = "" }
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts.compactMap { parseAddress($0) }
    }

    static func parseAddress(_ raw: String) -> EmailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            return EmailAddress(name: name, email: cleanEmail(email))
        }
        // "addr (Name)" comment form.
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let email = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            let name = String(s[s.index(after: open)..<close])
            return EmailAddress(name: name, email: cleanEmail(email))
        }
        return EmailAddress(name: "", email: cleanEmail(s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))))
    }

    /// Senders sometimes put a link in an address header ("<mailto:help@bank.in.>"); Gmail rejects that as not
    /// RFC 5321. Strip a mailto: scheme and any ?query, and the trailing dots of a fully-qualified domain.
    /// Percent-encoding is deliberately NOT decoded: "%0D%0A" must stay inert, never become CRLF.
    static func cleanEmail(_ raw: String) -> String {
        var e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.lowercased().hasPrefix("mailto:") { e = String(e.dropFirst(7)) }
        if let q = e.firstIndex(of: "?") { e = String(e[..<q]) }
        while e.hasSuffix(".") { e.removeLast() }
        return e.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }

    // MARK: HTML helpers

    static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static let blockStrip = try! NSRegularExpression(
        pattern: "<(style|script|head|title)[^>]*>.*?</\\1\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let tagStrip = try! NSRegularExpression(pattern: "<[^>]+>", options: [])
    private static let entity = try! NSRegularExpression(pattern: "&(#x?[0-9a-fA-F]+|[a-zA-Z]+);")
    private static let spaces = try! NSRegularExpression(pattern: "\\s+")

    /// Plain-text rendering of HTML for snippets and search, not for display.
    static func plainText(fromHTML html: String, limit: Int = 4000) -> String {
        var s = html
        if s.utf16.count > 200_000 { s = String(s.prefix(200_000)) }
        s = blockStrip.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        s = tagStrip.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        s = decodeEntities(s)
        s = spaces.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(limit))
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            var rep: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
            } else if name.hasPrefix("#") {
                if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
            } else {
                switch name.lowercased() {
                case "nbsp": rep = " "
                case "amp": rep = "&"
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "quot": rep = "\""
                case "apos": rep = "'"
                case "zwnj", "zwj", "shy": rep = ""
                case "mdash": rep = "—"
                case "ndash": rep = "–"
                case "hellip": rep = "…"
                case "rsquo": rep = "’"
                case "lsquo": rep = "‘"
                case "rdquo": rep = "”"
                case "ldquo": rep = "“"
                case "copy": rep = "©"
                case "reg": rep = "®"
                case "trade": rep = "™"
                default: rep = nil
                }
            }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func snippet(html: String?, text: String?) -> String {
        if let t = text, !t.isEmpty {
            let collapsed = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return String(collapsed.prefix(240))
        }
        if let h = html { return String(plainText(fromHTML: h, limit: 240)) }
        return ""
    }

    // MARK: Dates

    private static let rfc2822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func rfc2822(_ date: Date) -> String { rfc2822Formatter.string(from: date) }

    private static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func parseInternalDate(_ s: String) -> Date? {
        internalDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    private static let searchDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy"
        return f
    }()

    static func imapSearchDate(_ d: Date) -> String { searchDateFormatter.string(from: d) }

    // MARK: Misc

    /// Stable 63-bit FNV-1a hash, used as a thread id for servers without Gmail's X-GM-THRID.
    /// Conversation key for servers without X-GM-THRID (B-12). Replies point back at the thread's first
    /// message through References (oldest first) or In-Reply-To, so the root Message-ID identifies the
    /// conversation; a message with no ids falls back to subject plus the people involved, never subject alone.
    static func threadKey(messageID: String, inReplyTo: String, references: String, subject: String,
                          participants: [String]) -> Int64 {
        func ids(_ raw: String) -> [String] {
            var out: [String] = []
            var rest = Substring(raw)
            while let lt = rest.firstIndex(of: "<"), let gt = rest[lt...].firstIndex(of: ">") {
                let inner = rest[rest.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { out.append(inner.lowercased()) }
                rest = rest[rest.index(after: gt)...]
            }
            if out.isEmpty {
                let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !bare.isEmpty, !bare.contains(" ") { out.append(bare.lowercased()) }
            }
            return out
        }
        if let root = ids(references).first ?? ids(inReplyTo).first ?? ids(messageID).first {
            return stableHash("mid:" + root)
        }
        let people = Set(participants.map { $0.lowercased() }.filter { !$0.isEmpty }).sorted().joined(separator: ",")
        return stableHash("subj:" + normalizedSubject(subject).lowercased() + "|" + people)
    }

    static func stableHash(_ s: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return Int64(bitPattern: h & 0x7fff_ffff_ffff_ffff)
    }

    static func normalizedSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "fw:", "fwd:", "aw:", "sv:", "wg:"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return t.lowercased()
    }

    static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Streaming base64 decoder that writes decoded bytes as chunks arrive, so large attachments never sit in RAM whole.
struct StreamingBase64Decoder {
    private var carry: [UInt8] = []

    mutating func feed(_ data: Data) -> Data {
        var clean = carry
        clean.reserveCapacity(carry.count + data.count)
        for b in data where MIME.isBase64Char(b) { clean.append(b) }
        let usable = clean.count - clean.count % 4
        carry = Array(clean[usable...])
        guard usable > 0 else { return Data() }
        return Data(base64Encoded: Data(clean[0..<usable])) ?? MIME.decodeBase64(Data(clean[0..<usable]))
    }

    mutating func finish() -> Data {
        guard !carry.isEmpty else { return Data() }
        defer { carry = [] }
        return MIME.decodeBase64(Data(carry))
    }
}
