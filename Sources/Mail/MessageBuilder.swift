import Foundation
import UniformTypeIdentifiers

struct OutgoingAttachment {
    var url: URL
    var filename: String
    var mimeType: String
    /// Set for an image shown in the body: it's sent inline (multipart/related) and the HTML refers to it
    /// as cid:<contentID>.
    var contentID: String? = nil
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
    /// Message-ID to write (without angle brackets); generated when nil. Set by the composer so a saved
    /// draft can be found again by its id (B-09).
    var messageID: String? = nil

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
        // An encoded subject is already folded word by word; a long plain one is folded at its spaces,
        // so the line stays far below SMTP's 998-byte limit.
        let subject = encodeHeaderText(m.subject)
        out += (subject.contains("\r\n") ? "Subject: \(subject)" : foldHeader("Subject: \(subject)")) + "\r\n"
        out += "Date: \(MIME.rfc2822(date))\r\n"
        let mid = m.messageID.flatMap { id -> String? in
            let bare = MailSafety.stripControls(id).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            return bare.contains("@") && !bare.contains(" ") ? bare : nil
        } ?? newMessageID(domain: domain)
        out += "Message-ID: <\(mid)>\r\n"
        if let r = messageID(m.inReplyTo) { out += "In-Reply-To: \(r)\r\n" }
        if let refs = references(m.references) { out += foldHeader("References: \(refs)") + "\r\n" }
        out += "MIME-Version: 1.0\r\n"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        out += "User-Agent: Mac Mail \(MailSafety.stripControls(version))\r\n"

        let alt = "alt-" + UUID().uuidString
        var body = Data()
        func appendS(_ s: String) { body.append(Data(s.utf8)) }
        // One part per Content-ID: the same image can be referenced from several places in the body, and a
        // duplicate multipart/related part makes clients show the wrong picture (C-08). A part whose
        // Content-ID is unusable is sent as an ordinary file instead.
        var inline: [OutgoingAttachment] = []
        var files: [OutgoingAttachment] = []
        var contentIDs = Set<String>()
        for a in m.attachments {
            guard let raw = a.contentID else { files.append(a); continue }
            let cid = cleanContentID(raw)
            guard !cid.isEmpty else { files.append(a); continue }
            if contentIDs.insert(cid).inserted { inline.append(a) }
        }

        func appendFile(_ a: OutgoingAttachment, boundary: String) throws {
            let data = try Data(contentsOf: a.url, options: .mappedIfSafe)
            let name = MailSafety.stripControls(a.filename)
            appendS("--\(boundary)\r\n")
            appendS("Content-Type: \(MailSafety.stripControls(a.mimeType)); name=\"\(asciiFallback(name))\"\r\n")
            if let cid = a.contentID.map(cleanContentID), !cid.isEmpty {
                appendS("Content-Disposition: inline; filename=\"\(asciiFallback(name))\"\r\n")
                appendS("Content-ID: <\(cid)>\r\n")
            } else {
                appendS("Content-Disposition: attachment; filename=\"\(asciiFallback(name))\"; filename*=UTF-8''\(percentEncode(name))\r\n")
            }
            appendS("Content-Transfer-Encoding: base64\r\n\r\n")
            appendBase64(data, to: &body)
            appendS("\r\n")
        }

        // alternative { text/plain, html } where html is related { text/html, images… } when the body has
        // inline images: the layout Apple Mail and Outlook send, which every client renders.
        func appendAlternative() throws {
            appendS("Content-Type: multipart/alternative; boundary=\"\(alt)\"\r\n\r\n")
            appendS("--\(alt)\r\n")
            appendS("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n")
            appendS(wrap76(Data(m.textBody.utf8).base64EncodedString()) + "\r\n")
            appendS("--\(alt)\r\n")
            let html = "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                + wrap76(Data(m.htmlBody.utf8).base64EncodedString()) + "\r\n"
            if inline.isEmpty {
                appendS(html)
            } else {
                let rel = "rel-" + UUID().uuidString
                appendS("Content-Type: multipart/related; type=\"text/html\"; boundary=\"\(rel)\"\r\n\r\n")
                appendS("--\(rel)\r\n" + html)
                for a in inline { try appendFile(a, boundary: rel) }
                appendS("--\(rel)--\r\n")
            }
            appendS("--\(alt)--\r\n")
        }

        if files.isEmpty {
            appendS(out)
            try appendAlternative()
            return body
        }

        let mixed = "mix-" + UUID().uuidString
        out += "Content-Type: multipart/mixed; boundary=\"\(mixed)\"\r\n\r\n"
        appendS(out)
        appendS("--\(mixed)\r\n")
        try appendAlternative()
        for a in files { try appendFile(a, boundary: mixed) }
        appendS("--\(mixed)--\r\n")
        return body
    }

    /// A Content-ID value safe inside <…>: printable ASCII without brackets, quotes or spaces.
    static func cleanContentID(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7f && !"<>\" \\".unicodeScalars.contains($0) }
            .map(Character.init))
    }

    /// A fresh unique Message-ID (no angle brackets) for a sender's domain.
    static func newMessageID(domain: String) -> String {
        "\(UUID().uuidString.lowercased())@\(domain.isEmpty ? "macmail.local" : domain)"
    }

    static func newMessageID(for from: EmailAddress) -> String {
        newMessageID(domain: from.email.split(separator: "@").last.map(String.init) ?? "macmail.local")
    }

    /// Base64 in 76-column CRLF lines, encoded slice by slice straight into `out`, so a large attachment
    /// never exists as one giant base64 String in memory (O-04).
    static func appendBase64(_ data: Data, to out: inout Data) {
        let slice = 57 * 1024 // multiple of 57 bytes = whole 76-char lines
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: slice, limitedBy: data.endIndex) ?? data.endIndex
            autoreleasepool {
                let encoded = data[i..<j].base64EncodedData(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                out.append(encoded)
                if j < data.endIndex { out.append(contentsOf: [13, 10]) }
            }
            i = j
        }
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
