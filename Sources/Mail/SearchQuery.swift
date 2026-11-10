import Foundation

/// A parsed search: Gmail-style operators plus the filter bar's choices. Used for both the instant local search
/// (SQL) and the server search (X-GM-RAW on Gmail, IMAP SEARCH elsewhere).
struct SearchQuery: Equatable, Codable {
    var words: [String] = []
    var from: [String] = []
    var to: [String] = []
    /// cc: is its own criterion (B-13): Gmail and IMAP both search the Cc header separately from To.
    var cc: [String] = []
    var subject: [String] = []
    var hasAttachment = false
    var unread = false
    var flagged = false
    /// Only messages newer than this many days.
    var withinDays: Int?
    /// Operators only Gmail understands (in:, label:, older_than:, category:, …); sent to the server as-is.
    var serverOnly: [String] = []

    var isEmpty: Bool {
        words.isEmpty && from.isEmpty && to.isEmpty && cc.isEmpty && subject.isEmpty && !hasAttachment && !unread && !flagged
            && withinDays == nil && serverOnly.isEmpty
    }

    /// Whether the local cache can answer it (server-only operators need Gmail).
    var hasLocalCriteria: Bool {
        !(words.isEmpty && from.isEmpty && to.isEmpty && cc.isEmpty && subject.isEmpty && !hasAttachment && !unread && !flagged
          && withinDays == nil)
    }

    // MARK: Parsing

    /// Operators the parser understands; anything else with a colon is plain text, so subjects like
    /// "Re: budget" or "time: 10am" stay searchable locally instead of becoming server-only.
    private static let knownOperators: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "has", "is", "in", "label", "list", "category",
        "filename", "newer_than", "older_than", "after", "before", "around", "larger", "smaller",
        "deliveredto", "rfc822msgid",
    ]

    /// Accepts Gmail syntax, including a space after the colon ("from: divya") and quoted values (from:"divya k").
    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        let tokens = tokenize(raw)
        var i = 0
        while i < tokens.count {
            var token = tokens[i]
            // "from:" followed by a separate value token.
            if token.hasSuffix(":"), token.count > 1,
               knownOperators.contains(token.dropLast().lowercased()),
               i + 1 < tokens.count, tokens[i + 1].hasPrefix("\"") || !startsWithOperator(Array(tokens[i + 1]), at: 0) {
                token += tokens[i + 1]
                i += 1
            }
            i += 1
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                let w = unquote(token)
                if !w.isEmpty { q.words.append(w) }
                continue
            }
            let key = token[..<colon].lowercased()
            let value = unquote(String(token[token.index(after: colon)...]))
            guard !value.isEmpty else { continue } // bare "Re:" carries nothing to search for
            switch key {
            case "from": q.from.append(value)
            case "to": q.to.append(value)
            case "cc": q.cc.append(value)
            case "bcc": q.serverOnly.append("bcc:\(quoteIfNeeded(value))")
            case "subject": q.subject.append(value)
            case "has" where value.lowercased().hasPrefix("attachment"): q.hasAttachment = true
            case "is":
                switch value.lowercased() {
                case "unread": q.unread = true
                case "starred", "flagged": q.flagged = true
                default: q.serverOnly.append("is:\(value)")
                }
            case "newer_than":
                if let days = days(value) { q.withinDays = days } else { q.serverOnly.append(token) }
            case "http", "https", "mailto":
                q.words.append(token)
            default:
                guard knownOperators.contains(key) else {
                    let w = unquote(token)
                    if !w.isEmpty { q.words.append(w) }
                    continue
                }
                q.serverOnly.append("\(key):\(quoteIfNeeded(value))")
            }
        }
        return q
    }

    /// Splits at whitespace outside quotes. A comma directly followed by another operator also ends a
    /// token ("from:divya,to:bob"), so the second operator is not swallowed into the first one's value.
    private static func tokenize(_ s: String) -> [String] {
        let chars = Array(s)
        var out: [String] = []
        var cur = ""
        var inQuote = false
        for (i, ch) in chars.enumerated() {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if !inQuote, ch.isWhitespace || (ch == "," && startsWithOperator(chars, at: i + 1)) {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Whether a known operator and its colon ("from:") start at this position.
    private static func startsWithOperator(_ chars: [Character], at start: Int) -> Bool {
        var j = start
        while j < chars.count, chars[j].isLetter || chars[j] == "_" || chars[j].isNumber { j += 1 }
        guard j > start, j < chars.count, chars[j] == ":" else { return false }
        return knownOperators.contains(String(chars[start..<j]).lowercased())
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
    }

    /// Gmail's search syntax has no escape for a quote inside a quoted term, so quotes are dropped.
    private static func quoteIfNeeded(_ s: String) -> String {
        let s = s.replacingOccurrences(of: "\"", with: "")
        return s.contains(" ") ? "\"\(s)\"" : s
    }

    /// "7d" → 7, "2m" → 60, "1y" → 365. Huge values clamp instead of trapping.
    static func days(_ s: String) -> Int? {
        guard let unit = s.last, let n = Int(s.dropLast()) else { return nil }
        switch unit {
        case "d": return n
        case "m": return n > Int.max / 30 ? Int.max : n * 30
        case "y": return n > Int.max / 365 ? Int.max : n * 365
        default: return nil
        }
    }

    // MARK: Server forms

    /// Gmail search string for X-GM-RAW.
    var gmailRaw: String {
        var parts: [String] = words.map(Self.quoteIfNeeded)
        parts += from.map { "from:\(Self.quoteIfNeeded($0))" }
        parts += to.map { "to:\(Self.quoteIfNeeded($0))" }
        parts += cc.map { "cc:\(Self.quoteIfNeeded($0))" }
        parts += subject.map { "subject:\(Self.quoteIfNeeded($0))" }
        if hasAttachment { parts.append("has:attachment") }
        if unread { parts.append("is:unread") }
        if flagged { parts.append("is:starred") }
        if let d = withinDays { parts.append("newer_than:\(d)d") }
        parts += serverOnly
        return parts.joined(separator: " ")
    }

    /// Whether the query is fully expressible as plain IMAP SEARCH for non-Gmail servers: no has:attachment,
    /// no server-only operators, and ASCII-only values. When false, the server search must be skipped
    /// (or its results post-filtered) rather than silently widened to "ALL".
    var isIMAPRepresentable: Bool {
        guard serverOnly.isEmpty && !hasAttachment else { return false }
        let all = words + from + to + cc + subject
        return all.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) }
    }

    /// Plain IMAP SEARCH criteria for non-Gmail servers (ASCII values only; others are left to the local search).
    var imapCriteria: String {
        func q(_ s: String) -> String? { s.unicodeScalars.allSatisfy { $0.isASCII } ? s.imapQuoted : nil }
        var parts: [String] = []
        parts += words.compactMap { q($0).map { "TEXT \($0)" } }
        parts += from.compactMap { q($0).map { "FROM \($0)" } }
        parts += to.compactMap { q($0).map { "TO \($0)" } }
        parts += cc.compactMap { q($0).map { "CC \($0)" } }
        parts += subject.compactMap { q($0).map { "SUBJECT \($0)" } }
        if unread { parts.append("UNSEEN") }
        if flagged { parts.append("FLAGGED") }
        if let d = withinDays { parts.append("SINCE \(MIME.imapSearchDate(Date().addingTimeInterval(-Double(d) * 86400)))") }
        return parts.isEmpty ? "ALL" : parts.joined(separator: " ")
    }
}
