import Foundation

/// A parsed IMAP data item.
indirect enum IMAPValue {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
        default: return nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var number: UInt64? {
        if case .atom(let s) = self { return UInt64(s) }
        return nil
    }

    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }
}

struct IMAPResponse {
    /// "*", "+", or the command tag.
    var tag: String
    /// Status word for status responses (OK, NO, BAD, BYE, PREAUTH).
    var status: String?
    /// Response code inside brackets, e.g. "UIDVALIDITY 123".
    var code: String?
    /// Human text after the status / code.
    var text: String = ""
    /// Parsed values for data responses ("* 5 EXISTS", "* 3 FETCH (...)").
    var values: [IMAPValue] = []

    var isUntagged: Bool { tag == "*" }
    var isContinuation: Bool { tag == "+" }
}

/// A response is read as alternating text lines and literal payloads.
enum ResponsePart {
    case text([UInt8])
    case literal(Data)
}

enum IMAPParser {
    private static let statusWords: Set<String> = ["OK", "NO", "BAD", "BYE", "PREAUTH"]

    /// No server literal larger than this is ever read (DoS cap; downloads stream their own parts).
    static let maxLiteralSize = 64 * 1024 * 1024
    /// Cap on nested parens in a response; hostile nesting must not overflow the stack.
    static let maxDepth = 100

    /// Length of a trailing literal marker "{123}" or "{123+}", if the line ends with one.
    /// Returns the exact advertised length, saturating at Int.max for absurd values instead of
    /// trapping (SEC-07); the caller must refuse anything over maxLiteralSize, not read only the cap.
    static func literalLength(_ line: [UInt8]) -> Int? {
        guard let last = line.last, last == UInt8(ascii: "}") else { return nil }
        var i = line.count - 2
        if i >= 0 && line[i] == UInt8(ascii: "+") { i -= 1 }
        var digits = 0
        var value = 0
        var weight = 1
        var overflowed = false
        while i >= 0, line[i] >= 48, line[i] <= 57 {
            digits += 1
            if !overflowed {
                let (w, wo) = weight.multipliedReportingOverflow(by: 10)
                let (d, dof) = Int(line[i] - 48).multipliedReportingOverflow(by: weight)
                let (t, to) = value.addingReportingOverflow(d)
                if wo || dof || to { overflowed = true } else { value = t; weight = w }
            }
            i -= 1
        }
        guard digits > 0, i >= 0, line[i] == UInt8(ascii: "{") else { return nil }
        return overflowed ? Int.max : value
    }

    static func parse(_ parts: [ResponsePart]) -> IMAPResponse {
        var cursor = Cursor(parts: parts)
        let tag = cursor.readRawWord()
        var resp = IMAPResponse(tag: tag)
        if tag == "+" {
            resp.text = cursor.restOfLine()
            return resp
        }
        let save = cursor.save()
        let word = cursor.readRawWord()
        if statusWords.contains(word.uppercased()) {
            resp.status = word.uppercased()
            cursor.skipSpaces()
            if cursor.peek() == UInt8(ascii: "[") {
                resp.code = cursor.readBracketed()
            }
            resp.text = cursor.restOfLine().trimmingCharacters(in: .whitespaces)
            return resp
        }
        cursor.restore(save)
        while let v = cursor.readValue() { resp.values.append(v) }
        return resp
    }

    struct Cursor {
        let parts: [ResponsePart]
        var partIndex = 0
        var pos = 0

        init(parts: [ResponsePart]) { self.parts = parts }

        func save() -> (Int, Int) { (partIndex, pos) }
        mutating func restore(_ s: (Int, Int)) { partIndex = s.0; pos = s.1 }

        private var line: [UInt8] {
            if partIndex < parts.count, case .text(let l) = parts[partIndex] { return l }
            return []
        }

        func peek() -> UInt8? {
            let l = line
            return pos < l.count ? l[pos] : nil
        }

        mutating func skipSpaces() {
            let l = line
            while pos < l.count, l[pos] == 32 { pos += 1 }
        }

        mutating func readRawWord() -> String {
            skipSpaces()
            let l = line
            let start = pos
            while pos < l.count, l[pos] != 32 { pos += 1 }
            return String(decoding: l[start..<pos], as: UTF8.self)
        }

        mutating func restOfLine() -> String {
            let l = line
            guard pos < l.count else { return "" }
            let s = String(decoding: l[pos...], as: UTF8.self)
            pos = l.count
            return s
        }

        mutating func readBracketed() -> String {
            let l = line
            guard pos < l.count, l[pos] == UInt8(ascii: "[") else { return "" }
            pos += 1
            let start = pos
            var depth = 1
            while pos < l.count {
                if l[pos] == UInt8(ascii: "[") { depth += 1 }
                if l[pos] == UInt8(ascii: "]") { depth -= 1; if depth == 0 { break } }
                pos += 1
            }
            let s = String(decoding: l[start..<min(pos, l.count)], as: UTF8.self)
            if pos < l.count { pos += 1 }
            return s
        }

        /// Reads one value; nil at end of response or at a closing paren (which it consumes).
        mutating func readValue(_ depth: Int = 0) -> IMAPValue? {
            skipSpaces()
            let l = line
            guard pos < l.count else { return nil }
            let c = l[pos]
            switch c {
            case UInt8(ascii: "("):
                guard depth < IMAPParser.maxDepth else { return nil } // hostile nesting: truncate this branch
                pos += 1
                var items: [IMAPValue] = []
                while true {
                    skipSpaces()
                    let cur = line
                    if pos >= cur.count {
                        // Ran out of text: either a literal follows (handled inside readValue) or the response is malformed.
                        if partIndex + 1 >= parts.count { break }
                    }
                    if pos < cur.count, cur[pos] == UInt8(ascii: ")") { pos += 1; break }
                    guard let v = readValue(depth + 1) else { break }
                    items.append(v)
                }
                return .list(items)
            case UInt8(ascii: ")"):
                return nil
            case UInt8(ascii: "\""):
                pos += 1
                var bytes: [UInt8] = []
                while pos < l.count {
                    let b = l[pos]
                    if b == UInt8(ascii: "\\"), pos + 1 < l.count { bytes.append(l[pos + 1]); pos += 2; continue }
                    if b == UInt8(ascii: "\"") { pos += 1; break }
                    bytes.append(b)
                    pos += 1
                }
                return .string(Data(bytes))
            case UInt8(ascii: "{"):
                // Literal marker: the payload is the next part; parsing continues on the part after it.
                if IMAPParser.literalLength(Array(l[pos...])) != nil, partIndex + 1 < parts.count,
                   case .literal(let d) = parts[partIndex + 1] {
                    partIndex += 2
                    pos = 0
                    return .string(d)
                }
                return readAtom()
            default:
                return readAtom()
            }
        }

        private mutating func readAtom() -> IMAPValue {
            let l = line
            let start = pos
            var depth = 0
            while pos < l.count {
                let b = l[pos]
                if b == UInt8(ascii: "[") { depth += 1 }
                else if b == UInt8(ascii: "]") { depth = max(0, depth - 1) }
                else if depth == 0 && (b == 32 || b == UInt8(ascii: "(") || b == UInt8(ascii: ")")) { break }
                pos += 1
            }
            let s = String(decoding: l[start..<pos], as: UTF8.self)
            if s.uppercased() == "NIL" { return .nilValue }
            return .atom(s)
        }
    }
}

/// One FETCH response: its sequence number and the item map (keys uppercased).
struct FetchResult {
    var seq: UInt32
    var items: [String: IMAPValue]

    var uid: UInt32? { items["UID"]?.number.map { UInt32(truncatingIfNeeded: $0) } }

    /// Finds an item whose key starts with the prefix, e.g. "BODY[HEADER" or "BODY[1.2]".
    func item(prefix: String) -> IMAPValue? {
        if let v = items[prefix] { return v }
        return items.first(where: { $0.key.hasPrefix(prefix) })?.value
    }

    static func from(_ r: IMAPResponse) -> FetchResult? {
        guard r.isUntagged, r.values.count >= 3,
              let seq = r.values[0].number,
              r.values[1].text?.uppercased() == "FETCH",
              let list = r.values[2].list else { return nil }
        var items: [String: IMAPValue] = [:]
        var i = 0
        while i + 1 < list.count {
            if let key = list[i].text?.uppercased() {
                // Normalise "BODY[1]<0>" → "BODY[1]" so partial fetches look the same as full ones.
                var k = key
                if let lt = k.lastIndex(of: "<"), k.hasSuffix(">") { k = String(k[..<lt]) }
                items[k] = list[i + 1]
            }
            i += 2
        }
        return FetchResult(seq: UInt32(truncatingIfNeeded: seq), items: items)
    }
}

/// Modified UTF-7 mailbox names (RFC 3501 §5.1.3).
enum MailboxName {
    static func encode(_ s: String) -> String {
        var out = ""
        var buffer: [UInt16] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            var bytes = [UInt8]()
            for u in buffer { bytes.append(UInt8(u >> 8)); bytes.append(UInt8(u & 0xff)) }
            let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: ",")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            out += "&" + b64 + "-"
            buffer.removeAll()
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                buffer.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return out
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&" {
                guard let dash = s[i...].firstIndex(of: "-") else { out += String(s[i...]); break }
                let inner = String(s[s.index(after: i)..<dash])
                if inner.isEmpty {
                    out += "&"
                } else {
                    var b64 = inner.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    if let d = Data(base64Encoded: b64) {
                        let bytes = [UInt8](d)
                        if bytes.count % 2 == 0 {
                            var units: [UInt16] = []
                            var j = 0
                            while j + 1 < bytes.count { units.append(UInt16(bytes[j]) << 8 | UInt16(bytes[j + 1])); j += 2 }
                            out += String(decoding: units, as: UTF16.self)
                        } else {
                            out += String(s[i...dash]) // malformed segment: keep it verbatim, don't drop
                        }
                    } else {
                        out += String(s[i...dash]) // malformed segment: keep it verbatim, don't drop
                    }
                }
                i = s.index(after: dash)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}

extension String {
    /// IMAP quoted string; CR/LF are illegal in one and would let the value inject extra commands,
    /// so they are stripped rather than sent verbatim.
    var imapQuoted: String {
        let escaped = replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // Scalars, not Characters: Swift folds "\r\n" into one Character, which a Character filter lets through.
        return "\"" + String(String.UnicodeScalarView(escaped.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })) + "\""
    }
}

/// Compact UID set syntax: [1,2,3,7,9,10] → "1:3,7,9:10".
func imapUIDSet<S: Sequence>(_ uids: S) -> String where S.Element == UInt32 {
    let sorted = Array(Set(uids)).sorted()
    guard var start = sorted.first else { return "" }
    var prev = start
    var ranges: [String] = []
    for u in sorted.dropFirst() {
        if u == prev + 1 { prev = u; continue }
        ranges.append(start == prev ? "\(start)" : "\(start):\(prev)")
        start = u
        prev = u
    }
    ranges.append(start == prev ? "\(start)" : "\(start):\(prev)")
    return ranges.joined(separator: ",")
}
