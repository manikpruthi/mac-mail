import Foundation

/// SMTP submission over implicit TLS (465) or STARTTLS (587), with AUTH PLAIN (or LOGIN where PLAIN isn't offered).
enum SMTPClient {
    /// Where a server connection is; also what the progress callback reports.
    enum Stage: Equatable {
        case connecting, authenticating, uploading(sent: Int, total: Int), finishing
    }

    struct Endpoint {
        var host: String
        var port: UInt16
        var security: ConnectionSecurity
        var username: String
        var password: String
    }

    /// Per-command idle limit: each reply must arrive within this (B-34).
    static let commandTimeout: TimeInterval = 60
    /// The final "." gets extra time per megabyte uploaded: servers scan large messages before answering.
    static func dataDeadline(bytes: Int) -> TimeInterval { 120 + Double(bytes) / 1_048_576 * 10 }

    /// Refuses addresses that could break out of the envelope commands (injection, splitting).
    static func validateAddresses(from: String, recipients: [String]) throws {
        guard MailSafety.isValidAddrSpec(from) else { throw NetError.protocolError("invalid sender address") }
        guard recipients.allSatisfy({ MailSafety.isValidAddrSpec($0) }) else {
            throw NetError.protocolError("invalid recipient address")
        }
    }

    /// One SMTP conversation: reply parsing with per-command timeouts.
    private final class Session {
        let s: TLSStream
        var extensions: Set<String> = []
        var authMechanisms: Set<String> = []
        init(_ s: TLSStream) { self.s = s }

        func reply(timeout: TimeInterval) async throws -> (Int, String) {
            let stream = s
            let fired = FiredFlag()
            let watchdog = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                fired.fire()
                await stream.close()
            }
            defer { watchdog.cancel() }
            var text = ""
            var totalBytes = 0
            var lines = 0
            while true {
                let line: String
                do { line = String(decoding: try await s.readLine(), as: UTF8.self) } catch {
                    throw fired.didFire ? NetError.timeout : error
                }
                lines += 1
                totalBytes += line.utf8.count + 1
                // Both a line-count and a total-size cap: a broken server must not grow the reply forever.
                guard lines < 1000, totalBytes <= 64 * 1024 else { throw NetError.protocolError("reply too long") }
                text += line + "\n"
                guard line.count >= 3, let code = Int(line.prefix(3)) else { throw NetError.protocolError(line) }
                if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { return (code, text) }
            }
        }

        func expect(_ ok: ClosedRange<Int>, after command: String?, timeout: TimeInterval = SMTPClient.commandTimeout,
                    redacted: Bool = false) async throws -> String {
            try Task.checkCancellation()
            if let command { try await s.send(command + "\r\n") }
            let (code, text) = try await reply(timeout: timeout)
            guard ok.contains(code) else {
                if code == 535 || code == 534 || code == 530 { throw NetError.auth("the mail server rejected the password.") }
                let shown = redacted ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NetError.server("Sending failed (\(code)): " + shown)
            }
            return text
        }

        func ehlo() async throws {
            let text = try await expect(250...250, after: "EHLO macmail.local")
            extensions = []
            authMechanisms = []
            for line in text.split(separator: "\n").dropFirst() {
                let body = line.dropFirst(4).uppercased()
                let words = body.split(separator: " ").map(String.init)
                guard let first = words.first else { continue }
                extensions.insert(first)
                if first == "AUTH" { authMechanisms.formUnion(words.dropFirst()) }
            }
        }
    }

    /// Greeting, EHLO, STARTTLS when asked for, then AUTH. Returns the ready session.
    private static func open(_ e: Endpoint, progress: ((Stage) -> Void)?) async throws -> Session {
        progress?(.connecting)
        let s = TLSStream(host: e.host, port: e.port, security: e.security)
        try await s.open()
        let session = Session(s)
        do {
            _ = try await session.expect(220...220, after: nil)
            try await session.ehlo()
            if e.security == .startTLS {
                // Fail closed: the password must never be sent without TLS (F-01).
                guard session.extensions.contains("STARTTLS") else {
                    throw NetError.server("\(e.host) doesn't offer STARTTLS on port \(e.port). Use SSL/TLS (usually port 465).")
                }
                _ = try await session.expect(220...220, after: "STARTTLS")
                try await s.startTLS()
                try await session.ehlo()
            }
            progress?(.authenticating)
            if session.authMechanisms.contains("PLAIN") || !session.authMechanisms.contains("LOGIN") {
                let token = Data(("\u{0}" + e.username + "\u{0}" + e.password).utf8).base64EncodedString()
                _ = try await session.expect(235...235, after: "AUTH PLAIN " + token, redacted: true)
            } else {
                _ = try await session.expect(334...334, after: "AUTH LOGIN")
                _ = try await session.expect(334...334, after: Data(e.username.utf8).base64EncodedString(), redacted: true)
                _ = try await session.expect(235...235, after: Data(e.password.utf8).base64EncodedString(), redacted: true)
            }
            return session
        } catch {
            await s.close()
            throw error
        }
    }

    /// Checks that the server accepts the login, without sending anything (F-05: run when adding an account).
    static func verify(_ e: Endpoint) async throws {
        let session = try await open(e, progress: nil)
        _ = try? await session.expect(250...250, after: "NOOP")
        try? await session.s.send("QUIT\r\n")
        await session.s.close()
    }

    /// Sends one message. Cancellation is honoured between every stage (B-04); once the final "." is
    /// written the server decides, so callers must treat a cancellation after `.finishing` as "maybe sent".
    static func send(_ e: Endpoint, from: String, recipients: [String], message: Data,
                     progress: ((Stage) -> Void)? = nil) async throws {
        try validateAddresses(from: from, recipients: recipients)
        let session = try await open(e, progress: progress)
        defer { Task { await session.s.close() } }
        _ = try await session.expect(250...250, after: "MAIL FROM:<\(from)>")
        for r in recipients { _ = try await session.expect(250...251, after: "RCPT TO:<\(r)>") }
        _ = try await session.expect(354...354, after: "DATA")
        let payload = dotStuffed(message)
        // Uploaded in slices, so progress is reported and a stalled uplink trips the idle watchdog
        // instead of one deadline for the whole conversation (B-34).
        let slice = 256 * 1024
        var sent = 0
        while sent < payload.count {
            try Task.checkCancellation()
            let end = min(payload.count, sent + slice)
            let stream = session.s
            let fired = FiredFlag()
            let watchdog = Task {
                try await Task.sleep(nanoseconds: UInt64(commandTimeout * 1_000_000_000))
                fired.fire()
                await stream.close()
            }
            do { try await session.s.send(payload.subdata(in: sent..<end)) } catch {
                watchdog.cancel()
                throw fired.didFire ? NetError.timeout : error
            }
            watchdog.cancel()
            sent = end
            progress?(.uploading(sent: sent, total: payload.count))
        }
        progress?(.finishing)
        _ = try await session.expect(250...250, after: ".", timeout: dataDeadline(bytes: payload.count))
        try? await session.s.send("QUIT\r\n")
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

/// Set by a watchdog when it fires, so the failure it causes reads as a timeout rather than "closed".
final class FiredFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func fire() { lock.lock(); value = true; lock.unlock() }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
