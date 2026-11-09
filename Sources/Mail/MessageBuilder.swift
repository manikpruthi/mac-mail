import Foundation
import UniformTypeIdentifiers

struct OutgoingAttachment {
    var url: URL
    var filename: String
    var mimeType: String
}

struct OutgoingMessage {
    var from: EmailAddress
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var bcc: [EmailAddress]
    var subject: String
    var textBody: String
    var htmlBody: String
    var inReplyTo: String?
    var references: String?
    var attachments: [OutgoingAttachment]

    var allRecipients: [String] { (to + cc + bcc).map { $0.email }.filter { MailSafety.isValidAddrSpec($0) } }
}

/// Builds RFC 5322 / MIME messages with CRLF line endings.
enum MessageBuilder {
    static func build(_ m: OutgoingMessage, date: Date = Date()) throws -> Data {
        let to = m.to.filter { MailSafety.isValidAddrSpec($0.email) }
        let cc = m.cc.filter { MailSafety.isValidAddrSpec($0.email) }
        let bcc = m.bcc.filter { MailSafety.isValidAddrSpec($0.email) }
        guard MailSafety.isValidAddrSpec(m.from.email), !(to.isEmpty && cc.isEmpty && bcc.isEmpty) else {
            throw NetError.protocolError("no valid recipients")
        }
        var out = ""
        let domain = m.from.email.split(separator: "@").last.map(String.init) ?? "macmail.local"
        out += "From: \(encodeAddress(m.from))\r\n"
        if !to.isEmpty { out += foldHeader("To: " + to.map(encodeAddress).joined(separator: ", ")) + "\r\n" }
        if !cc.isEmpty { out += foldHeader("Cc: " + cc.map(encodeAddress).joined(separator: ", ")) + "\r\n" }
        out += "Subject: \(encodeHeaderText(m.subject))\r\n"
        out += "Date: \(MIME.rfc2822(date))\r\n"
        out += "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>\r\n"
        if let r = messageID(m.inReplyTo) { out += "In-Reply-To: \(r)\r\n" }
        if let refs = references(m.references) { out += foldHeader("References: \(refs)") + "\r\n" }
        out += "MIME-Version: 1.0\r\n"
        out += "User-Agent: Mac Mail 1.0\r\n"

        let alt = "alt-" + UUID().uuidString
        var body = Data()
        func appendS(_ s: String) { body.append(Data(s.utf8)) }

        let alternative: String = {
            var s = "Content-Type: multipart/alternative; boundary=\"\(alt)\"\r\n\r\n"
            s += "--\(alt)\r\n"
            s += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            s += wrap76(Data(m.textBody.utf8).base64EncodedString()) + "\r\n"
            s += "--\(alt)\r\n"
            s += "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            s += wrap76(Data(m.htmlBody.utf8).base64EncodedString()) + "\r\n"
            s += "--\(alt)--\r\n"
            return s
        }()

        if m.attachments.isEmpty {
            appendS(out)
            appendS(alternative)
            return body
        }

        let mixed = "mix-" + UUID().uuidString
        out += "Content-Type: multipart/mixed; boundary=\"\(mixed)\"\r\n\r\n"
        appendS(out)
        appendS("--\(mixed)\r\n")
        appendS(alternative)
        for a in m.attachments {
            let data = try Data(contentsOf: a.url, options: .mappedIfSafe)
            let name = MailSafety.stripControls(a.filename)
            appendS("--\(mixed)\r\n")
            appendS("Content-Type: \(a.mimeType); name=\"\(asciiFallback(name))\"\r\n")
            appendS("Content-Disposition: attachment; filename=\"\(asciiFallback(name))\"; filename*=UTF-8''\(percentEncode(name))\r\n")
            appendS("Content-Transfer-Encoding: base64\r\n\r\n")
            appendS(wrap76(data.base64EncodedString()))
            appendS("\r\n")
        }
        appendS("--\(mixed)--\r\n")
        return body
    }

    static func wrap76(_ s: String) -> String {
        var lines: [Substring] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
            lines.append(s[i..<j])
            i = j
        }
        return lines.joined(separator: "\r\n")
    }

    /// Folds a full header line ("Name: value") at whitespace/commas once it passes ~78 chars.
    static func foldHeader(_ line: String) -> String {
        guard line.utf8.count > 78 else { return line }
        var lines: [String] = []
        var cur = ""
        for w in line.split(separator: " ", omittingEmptySubsequences: false) {
            if !cur.isEmpty && cur.utf8.count + 1 + w.utf8.count > 78 {
                lines.append(cur)
                cur = String(w)
            } else {
                cur += cur.isEmpty ? String(w) : " " + String(w)
            }
        }
        lines.append(cur)
        return lines.joined(separator: "\r\n ")
    }

    /// Keeps only well-formed message-ids (<id@domain>) from a header the message supplied.
    private static func messageID(_ raw: String?) -> String? {
        guard let ids = messageIDs(raw), let first = ids.first else { return nil }
        return "<\(first)>"
    }

    private static func references(_ raw: String?) -> String? {
        guard let ids = messageIDs(raw), !ids.isEmpty else { return nil }
        return ids.map { "<\($0)>" }.joined(separator: " ")
    }

    private static func messageIDs(_ raw: String?) -> [String]? {
        guard var r = raw.map(MailSafety.stripControls), !r.isEmpty else { return nil }
        var ids: [String] = []
        while let lt = r.firstIndex(of: "<") {
            guard let gt = r[lt...].firstIndex(of: ">") else { break }
            let inner = String(r[r.index(after: lt)..<gt])
            if inner.contains("@"), !inner.contains(where: { "<> \t\r\n\"".contains($0) }), inner.utf8.count <= 254 {
                ids.append(inner)
            }
            r = String(r[r.index(after: gt)...])
        }
        return ids.isEmpty ? nil : ids
    }

    static func encodeHeaderText(_ s: String) -> String {
        let s = MailSafety.stripControls(s)
        if s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) { return s }
        // Split into encoded words of at most 45 source bytes (≤72 chars per word), folded.
        var words: [String] = []
        var cur = ""
        var bytes = 0
        for ch in s {
            let cb = String(ch).utf8.count
            if !cur.isEmpty && bytes + cb > 45 {
                words.append("=?UTF-8?B?" + Data(cur.utf8).base64EncodedString() + "?=")
                cur = ""
                bytes = 0
            }
            cur.append(ch)
            bytes += cb
        }
        if !cur.isEmpty { words.append("=?UTF-8?B?" + Data(cur.utf8).base64EncodedString() + "?=") }
        return words.joined(separator: "\r\n ")
    }

    static func encodeAddress(_ a: EmailAddress) -> String {
        let email = MailSafety.stripControls(a.email)
        guard !a.name.isEmpty else { return email }
        let clean = MailSafety.stripControls(a.name)
        let name: String
        if clean.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value != 0x7f }) {
            name = "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            name = encodeHeaderText(clean)
        }
        return "\(name) <\(email)>"
    }

    /// ASCII-only value for name=/filename=. Controls, quotes, backslashes and parameter separators
    /// become "_" so nothing can escape the quoted string.
    private static func asciiFallback(_ s: String) -> String {
        String(s.unicodeScalars.map { scalar in
            if scalar.value < 0x20 || scalar.value == 0x7f || scalar.value > 0x7e
                || scalar == "\"" || scalar == "\\" || scalar == ";" { return "_" }
            return Character(scalar)
        })
    }

    private static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func mimeType(for url: URL) -> String {
        if let t = UTType(filenameExtension: url.pathExtension), let m = t.preferredMIMEType { return m }
        return "application/octet-stream"
    }
}
