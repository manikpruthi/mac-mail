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

    var allRecipients: [String] { (to + cc + bcc).map { $0.email } }
}

/// Builds RFC 5322 / MIME messages with CRLF line endings.
enum MessageBuilder {
    static func build(_ m: OutgoingMessage, date: Date = Date()) throws -> Data {
        var out = ""
        let domain = m.from.email.split(separator: "@").last.map(String.init) ?? "macmail.local"
        out += "From: \(encodeAddress(m.from))\r\n"
        if !m.to.isEmpty { out += "To: \(m.to.map(encodeAddress).joined(separator: ", "))\r\n" }
        if !m.cc.isEmpty { out += "Cc: \(m.cc.map(encodeAddress).joined(separator: ", "))\r\n" }
        out += "Subject: \(encodeHeaderText(m.subject))\r\n"
        out += "Date: \(MIME.rfc2822(date))\r\n"
        out += "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>\r\n"
        if let r = m.inReplyTo, !r.isEmpty { out += "In-Reply-To: \(r)\r\n" }
        if let r = m.references, !r.isEmpty { out += "References: \(r)\r\n" }
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
            let name = a.filename
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

    static func encodeHeaderText(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }

    static func encodeAddress(_ a: EmailAddress) -> String {
        guard !a.name.isEmpty else { return a.email }
        let name: String
        if a.name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            name = "\"" + a.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            name = encodeHeaderText(a.name)
        }
        return "\(name) <\(a.email)>"
    }

    private static func asciiFallback(_ s: String) -> String {
        String(s.unicodeScalars.map { $0.isASCII && $0 != "\"" ? Character($0) : "_" })
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
