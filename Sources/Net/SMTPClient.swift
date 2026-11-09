import Foundation

/// Minimal SMTP submission over implicit TLS (port 465), with AUTH PLAIN.
enum SMTPClient {
    /// Refuses addresses that could break out of the envelope commands (injection, splitting).
    static func validateAddresses(from: String, recipients: [String]) throws {
        guard MailSafety.isValidAddrSpec(from) else { throw NetError.protocolError("invalid sender address") }
        guard recipients.allSatisfy({ MailSafety.isValidAddrSpec($0) }) else {
            throw NetError.protocolError("invalid recipient address")
        }
    }

    static func send(host: String, port: UInt16, username: String, password: String,
                     from: String, recipients: [String], message: Data) async throws {
        try validateAddresses(from: from, recipients: recipients)
        let s = TLSStream(host: host, port: port)
        try await s.open()
        defer { Task { await s.close() } }
        // One-shot watchdog so a silent server can never hang the send.
        let watchdog = Task { [weak s] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            await s?.close()
        }
        defer { watchdog.cancel() }

        func reply() async throws -> (Int, String) {
            var text = ""
            while true {
                let line = String(decoding: try await s.readLine(), as: UTF8.self)
                text += line + "\n"
                guard line.count >= 3, let code = Int(line.prefix(3)) else { throw NetError.protocolError(line) }
                if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { return (code, text) }
            }
        }
        func expect(_ ok: ClosedRange<Int>, after command: String?) async throws {
            if let command { try await s.send(command + "\r\n") }
            let (code, text) = try await reply()
            guard ok.contains(code) else {
                if code == 535 || code == 534 { throw NetError.auth("the mail server rejected the App Password.") }
                throw NetError.server("Sending failed: " + text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        try await expect(220...220, after: nil)
        try await expect(250...250, after: "EHLO macmail.local")
        let token = Data(("\u{0}" + username + "\u{0}" + password).utf8).base64EncodedString()
        try await expect(235...235, after: "AUTH PLAIN " + token)
        try await expect(250...250, after: "MAIL FROM:<\(from)>")
        for r in recipients { try await expect(250...251, after: "RCPT TO:<\(r)>") }
        try await expect(354...354, after: "DATA")
        try await s.send(dotStuffed(message))
        try await expect(250...250, after: ".")
        try? await s.send("QUIT\r\n")
    }

    /// Lines starting with "." get an extra "." (RFC 5321 §4.5.2). The message already uses CRLF.
    static func dotStuffed(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 64)
        var atLineStart = true
        for b in data {
            if atLineStart && b == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(b)
            atLineStart = (b == 10)
        }
        if !(out.suffix(2) == Data([13, 10])) { out.append(contentsOf: [13, 10]) }
        return out
    }
}
