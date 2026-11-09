import Foundation

/// A parsed search: Gmail-style operators plus the filter bar's choices. Used for both the instant local search
/// (SQL) and the server search (X-GM-RAW on Gmail, IMAP SEARCH elsewhere).
struct SearchQuery: Equatable {
    var words: [String] = []
    var from: [String] = []
    var to: [String] = []
    var subject: [String] = []
    var hasAttachment = false
    var unread = false
    var flagged = false
    /// Only messages newer than this many days.
    var withinDays: Int?
    /// Operators only Gmail understands (in:, label:, older_than:, category:, …); sent to the server as-is.
    var serverOnly: [String] = []

    var isEmpty: Bool {
        words.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty && !hasAttachment && !unread && !flagged
            && withinDays == nil && serverOnly.isEmpty
    }

    /// Whether the local cache can answer it (server-only operators need Gmail).
    var hasLocalCriteria: Bool {
        !(words.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty && !hasAttachment && !unread && !flagged && withinDays == nil)
    }

    // MARK: Parsing

    /// Accepts Gmail syntax, including a space after the colon ("from: divya") and quoted values (from:"divya k").
    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        let tokens = tokenize(raw)
        var i = 0
        while i < tokens.count {
            var token = tokens[i]
            // "from:" followed by a separate value token.
            if token.hasSuffix(":"), token.count > 1, i + 1 < tokens.count, !tokens[i + 1].contains(":") || tokens[i + 1].hasPrefix("\"") {
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
            guard !value.isEmpty else { continue }
            switch key {
            case "from": q.from.append(value)
            case "to", "cc": q.to.append(value)
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
                q.serverOnly.append("\(key):\(quoteIfNeeded(value))")
            }
        }
        return q
    }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); cur.append(ch); continue }
            if ch.isWhitespace && !inQuote {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).trimmingCharacters(in: .whitespaces)
    }

    private static func quoteIfNeeded(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }

    /// "7d" → 7, "2m" → 60, "1y" → 365.
    static func days(_ s: String) -> Int? {
        guard let unit = s.last, let n = Int(s.dropLast()) else { return nil }
        switch unit {
        case "d": return n
        case "m": return n * 30
        case "y": return n * 365
        default: return nil
        }
    }

    // MARK: Server forms

    /// Gmail search string for X-GM-RAW.
    var gmailRaw: String {
        var parts: [String] = words.map(Self.quoteIfNeeded)
        parts += from.map { "from:\(Self.quoteIfNeeded($0))" }
        parts += to.map { "to:\(Self.quoteIfNeeded($0))" }
        parts += subject.map { "subject:\(Self.quoteIfNeeded($0))" }
        if hasAttachment { parts.append("has:attachment") }
        if unread { parts.append("is:unread") }
        if flagged { parts.append("is:starred") }
        if let d = withinDays { parts.append("newer_than:\(d)d") }
        parts += serverOnly
        return parts.joined(separator: " ")
    }

    /// Plain IMAP SEARCH criteria for non-Gmail servers (ASCII values only; others are left to the local search).
    var imapCriteria: String {
        func q(_ s: String) -> String? { s.unicodeScalars.allSatisfy { $0.isASCII } ? s.imapQuoted : nil }
        var parts: [String] = []
        parts += words.compactMap { q($0).map { "TEXT \($0)" } }
        parts += from.compactMap { q($0).map { "FROM \($0)" } }
        parts += to.compactMap { q($0).map { "TO \($0)" } }
        parts += subject.compactMap { q($0).map { "SUBJECT \($0)" } }
        if unread { parts.append("UNSEEN") }
        if flagged { parts.append("FLAGGED") }
        if let d = withinDays { parts.append("SINCE \(MIME.imapSearchDate(Date().addingTimeInterval(-Double(d) * 86400)))") }
        return parts.isEmpty ? "ALL" : parts.joined(separator: " ")
    }
}
