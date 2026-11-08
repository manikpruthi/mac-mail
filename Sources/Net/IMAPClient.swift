import Foundation

struct SelectInfo {
    var exists: UInt32 = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
    var highestModseq: UInt64 = 0
}

struct ListedFolder {
    var path: String
    var delimiter: String
    var attributes: [String]

    var selectable: Bool { !attributes.contains { $0.lowercased() == "\\noselect" || $0.lowercased() == "\\nonexistent" } }

    var role: FolderRole {
        let a = Set(attributes.map { $0.lowercased() })
        if path.uppercased() == "INBOX" { return .inbox }
        if a.contains("\\all") { return .all }
        if a.contains("\\sent") { return .sent }
        if a.contains("\\drafts") { return .drafts }
        if a.contains("\\junk") { return .spam }
        if a.contains("\\trash") { return .trash }
        if a.contains("\\flagged") { return .starred }
        if a.contains("\\important") { return .important }
        if a.contains("\\archive") { return .archive }
        let lower = path.lowercased()
        switch lower {
        case "sent", "sent items", "sent messages", "inbox.sent": return .sent
        case "drafts", "inbox.drafts": return .drafts
        case "spam", "junk", "junk e-mail", "inbox.spam", "inbox.junk": return .spam
        case "trash", "deleted items", "deleted messages", "inbox.trash": return .trash
        case "archive", "inbox.archive": return .archive
        default: return .none
        }
    }
}

/// One IMAP connection. Commands run one at a time; the actor keeps network work and response parsing off the main thread.
actor IMAPClient {
    let host: String
    let port: UInt16
    let username: String
    private let password: String

    private var stream: TLSStream?
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private(set) var selectedPath: String?
    private var selectedReadOnly = false
    /// Response code of the last tagged OK (e.g. "CAPABILITY …" after LOGIN).
    private var lastTaggedCode: String?
    private var idleTag: String?
    private var idleDoneSent = false
    // Actors are re-entrant at every await, so commands need their own lock or two could interleave on the wire.
    private var commandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    private func lockCommands() async {
        if commandBusy { await withCheckedContinuation { commandWaiters.append($0) } } else { commandBusy = true }
    }

    private func unlockCommands() {
        if commandWaiters.isEmpty { commandBusy = false } else { commandWaiters.removeFirst().resume() }
    }

    init(host: String, port: UInt16, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    var isConnected: Bool { stream != nil }
    var isGmail: Bool { capabilities.contains("X-GM-EXT-1") }
    var hasCondstore: Bool { capabilities.contains("CONDSTORE") }
    var hasMove: Bool { capabilities.contains("MOVE") }
    var hasIdle: Bool { capabilities.contains("IDLE") }

    // MARK: Connection

    /// TLS, then LOGIN. Gmail (and most servers) send their capabilities in the LOGIN reply, so the separate
    /// CAPABILITY round trip is only made when they don't; CONDSTORE turns on with the first SELECT (CONDSTORE).
    func connect() async throws {
        let s = TLSStream(host: host, port: port)
        try await s.open()
        stream = s
        do {
            let greeting = try await readResponse()
            guard greeting.status == "OK" || greeting.status == "PREAUTH" else {
                throw NetError.protocolError(greeting.text)
            }
            do {
                _ = try await run("LOGIN \(username.imapQuoted) \(password.imapQuoted)", timeout: 30)
            } catch NetError.server(let m) {
                throw NetError.auth(m.isEmpty ? "the server rejected the email or App Password." : m)
            }
            if let code = lastTaggedCode, code.uppercased().hasPrefix("CAPABILITY ") {
                capabilities = Set(code.split(separator: " ").dropFirst().map { $0.uppercased() })
            }
            if capabilities.isEmpty {
                let caps = try await run("CAPABILITY", timeout: 20)
                for r in caps where r.isUntagged {
                    if let first = r.values.first?.text, first.uppercased() == "CAPABILITY" {
                        capabilities = Set(r.values.dropFirst().compactMap { $0.text?.uppercased() })
                    }
                }
            }
        } catch {
            await s.close()
            stream = nil
            throw error
        }
    }

    func disconnect() async {
        if let s = stream {
            try? await s.send("Z LOGOUT\r\n")
            await s.close()
        }
        stream = nil
        selectedPath = nil
    }

    private func drop() async {
        if let s = stream { await s.close() }
        stream = nil
        selectedPath = nil
    }

    // MARK: Low-level

    private func nextTag() -> String {
        tagCounter += 1
        return "M\(tagCounter)"
    }

    private func readResponse() async throws -> IMAPResponse {
        guard let s = stream else { throw NetError.closed }
        var parts: [ResponsePart] = []
        while true {
            let line = try await s.readLine()
            parts.append(.text(line))
            if let n = IMAPParser.literalLength(line) {
                parts.append(.literal(try await s.readBytes(n)))
            } else {
                break
            }
        }
        return IMAPParser.parse(parts)
    }

    /// Sends a command (optionally with synchronizing literals between segments) and collects untagged responses.
    @discardableResult
    func run(_ command: String, literals: [Data] = [], trailing: [String] = [], timeout: TimeInterval = 90) async throws -> [IMAPResponse] {
        await lockCommands()
        defer { unlockCommands() }
        guard let s = stream else { throw NetError.closed }
        let tag = nextTag()
        let watchdog = Task { [weak s] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await s?.close()
        }
        defer { watchdog.cancel() }
        var untagged: [IMAPResponse] = []
        do {
            if literals.isEmpty {
                try await s.send("\(tag) \(command)\r\n")
            } else {
                // command ends with "{n}"; wait for "+" before each literal.
                try await s.send("\(tag) \(command)\r\n")
                for (i, lit) in literals.enumerated() {
                    while true {
                        let r = try await readResponse()
                        if r.isContinuation { break }
                        if r.tag == tag { throw NetError.server(r.text) }
                        untagged.append(r)
                    }
                    var payload = lit
                    let tail = i < trailing.count ? trailing[i] : ""
                    payload.append(Data((tail + "\r\n").utf8))
                    try await s.send(payload)
                }
            }
            while true {
                let r = try await readResponse()
                if r.tag == tag {
                    lastTaggedCode = r.code
                    if r.status == "OK" { return untagged }
                    throw NetError.server(r.text.isEmpty ? "\(command.prefix(20)) failed" : r.text)
                }
                if r.isUntagged && r.status == "BYE" {
                    await drop()
                    throw NetError.closed
                }
                untagged.append(r)
            }
        } catch let e as NetError {
            if case .server = e { throw e }
            if case .auth = e { throw e }
            await drop()
            throw e
        } catch {
            await drop()
            throw NetError.closed
        }
    }

    // MARK: Commands

    func list() async throws -> [ListedFolder] {
        let rs = try await run("LIST \"\" \"*\"")
        var out: [ListedFolder] = []
        for r in rs where r.isUntagged {
            guard r.values.count >= 4, r.values[0].text?.uppercased() == "LIST" else { continue }
            let attrs = r.values[1].list?.compactMap { $0.text } ?? []
            let delim = r.values[2].text ?? "/"
            guard let rawName = r.values[3].text else { continue }
            out.append(ListedFolder(path: MailboxName.decode(rawName), delimiter: delim, attributes: attrs))
        }
        return out
    }

    @discardableResult
    func select(_ path: String, readOnly: Bool = false, force: Bool = true) async throws -> SelectInfo? {
        if !force, selectedPath == path, selectedReadOnly == readOnly || (!selectedReadOnly && readOnly) { return nil }
        let verb = readOnly ? "EXAMINE" : "SELECT"
        let suffix = hasCondstore ? " (CONDSTORE)" : ""
        let rs = try await run("\(verb) \(MailboxName.encode(path).imapQuoted)\(suffix)")
        selectedPath = path
        selectedReadOnly = readOnly
        var info = SelectInfo()
        for r in rs where r.isUntagged {
            if r.values.count >= 2, let n = r.values[0].number, r.values[1].text?.uppercased() == "EXISTS" {
                info.exists = UInt32(truncatingIfNeeded: n)
            }
            if let code = r.code {
                let parts = code.split(separator: " ")
                if parts.count >= 2 {
                    switch parts[0].uppercased() {
                    case "UIDVALIDITY": info.uidValidity = UInt32(parts[1]) ?? 0
                    case "UIDNEXT": info.uidNext = UInt32(parts[1]) ?? 0
                    case "HIGHESTMODSEQ": info.highestModseq = UInt64(parts[1]) ?? 0
                    default: break
                    }
                }
            }
        }
        return info
    }

    func ensureSelected(_ path: String, readOnly: Bool) async throws {
        try await select(path, readOnly: readOnly, force: false)
    }

    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        let rs = try await run("UID SEARCH \(criteria)")
        return Self.searchResults(rs)
    }

    /// Search with a free-text argument that may need a literal (non-ASCII).
    func uidSearch(prefix: String, text: String) async throws -> [UInt32] {
        if text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return try await uidSearch("\(prefix) \(text.imapQuoted)")
        }
        let data = Data(text.utf8)
        let rs = try await run("UID SEARCH CHARSET UTF-8 \(prefix) {\(data.count)}", literals: [data])
        return Self.searchResults(rs)
    }

    private static func searchResults(_ rs: [IMAPResponse]) -> [UInt32] {
        var out: [UInt32] = []
        for r in rs where r.isUntagged {
            guard r.values.first?.text?.uppercased() == "SEARCH" else { continue }
            for v in r.values.dropFirst() {
                if let n = v.number { out.append(UInt32(truncatingIfNeeded: n)) }
            }
        }
        return out
    }

    func fetch(_ set: String, items: String, uid: Bool = true, changedSince: UInt64? = nil) async throws -> [FetchResult] {
        var cmd = (uid ? "UID FETCH " : "FETCH ") + set + " " + items
        if let m = changedSince { cmd += " (CHANGEDSINCE \(m))" }
        let rs = try await run(cmd, timeout: 180)
        return rs.compactMap { FetchResult.from($0) }
    }

    func store(_ uids: [UInt32], _ change: String) async throws {
        guard !uids.isEmpty else { return }
        try await run("UID STORE \(imapUIDSet(uids)) \(change)")
    }

    func move(_ uids: [UInt32], to dest: String) async throws {
        guard !uids.isEmpty else { return }
        let set = imapUIDSet(uids)
        let mbox = MailboxName.encode(dest).imapQuoted
        if hasMove {
            try await run("UID MOVE \(set) \(mbox)")
        } else {
            try await run("UID COPY \(set) \(mbox)")
            try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") { try await run("UID EXPUNGE \(set)") } else { try await run("EXPUNGE") }
        }
    }

    func expungeUIDs(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = imapUIDSet(uids)
        try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") { try await run("UID EXPUNGE \(set)") } else { try await run("EXPUNGE") }
    }

    func append(_ path: String, flags: String, message: Data) async throws {
        try await run("APPEND \(MailboxName.encode(path).imapQuoted) (\(flags)) {\(message.count)}", literals: [message], timeout: 300)
    }

    /// Waits in IDLE until the server reports a change or the time limit passes. Returns true on change.
    func idle(maxSeconds: TimeInterval) async throws -> Bool {
        await lockCommands()
        defer { unlockCommands() }
        guard let s = stream else { throw NetError.closed }
        let tag = nextTag()
        try await s.send("\(tag) IDLE\r\n")
        let first = try await readResponse()
        guard first.isContinuation else {
            if first.tag == tag { throw NetError.server(first.text) }
            return true
        }
        idleTag = tag
        idleDoneSent = false
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(maxSeconds * 1_000_000_000))
            await self?.endIdle()
        }
        defer { timer.cancel(); idleTag = nil }
        var changed = false
        do {
            while true {
                let r = try await readResponse()
                if r.tag == tag { return changed }
                if r.isUntagged, r.values.count >= 2, let word = r.values[1].text?.uppercased(),
                   word == "EXISTS" || word == "EXPUNGE" || word == "FETCH" {
                    changed = true
                    await endIdle()
                }
                if r.isUntagged && r.status == "BYE" { await drop(); throw NetError.closed }
            }
        } catch {
            await drop()
            throw error
        }
    }

    func endIdle() async {
        guard idleTag != nil, !idleDoneSent, let s = stream else { return }
        idleDoneSent = true
        try? await s.send("DONE\r\n")
    }

    // MARK: High-level helpers

    func headerItems() -> String {
        var items = "UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE"
        if isGmail { items += " X-GM-MSGID X-GM-THRID" }
        items += " BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES REPLY-TO LIST-UNSUBSCRIBE)]"
        return "(\(items))"
    }

    /// Fetches and parses header rows for a set of UIDs (or sequence numbers).
    func fetchHeaders(_ set: String, uid: Bool = true) async throws -> [ParsedHeader] {
        let results = try await fetch(set, items: headerItems(), uid: uid)
        let gmail = isGmail
        return results.compactMap { Self.parseHeader($0, gmail: gmail) }
    }

    static func parseHeader(_ r: FetchResult, gmail: Bool) -> ParsedHeader? {
        guard let uid = r.uid else { return nil }
        let headerData = r.item(prefix: "BODY[HEADER")?.data ?? Data()
        let h = MIME.parseHeaders(headerData)
        let flags = MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? [])
        let date = r.items["INTERNALDATE"]?.text.flatMap { MIME.parseInternalDate($0) } ?? Date()
        let structure = r.items["BODYSTRUCTURE"].flatMap { BodyPart.parse($0) }
        let from = MIME.parseAddresses(h["from"] ?? "").first ?? EmailAddress(name: "", email: "")
        let subject = h["subject"] ?? ""
        let gmsgid = r.items["X-GM-MSGID"]?.number.map { Int64(bitPattern: $0) } ?? 0
        var thrid = r.items["X-GM-THRID"]?.number.map { Int64(bitPattern: $0) } ?? 0
        if !gmail || thrid == 0 { thrid = MIME.stableHash(MIME.normalizedSubject(subject)) }
        return ParsedHeader(
            uid: uid, gmailID: gmsgid, threadID: thrid, date: date,
            size: Int(r.items["RFC822.SIZE"]?.number ?? 0), flags: flags, subject: subject, from: from,
            toList: h["to"] ?? "", ccList: h["cc"] ?? "", replyTo: h["reply-to"] ?? "",
            messageID: h["message-id"] ?? "", inReplyTo: h["in-reply-to"] ?? "", references: h["references"] ?? "",
            listUnsubscribe: h["list-unsubscribe"] ?? "", structureJSON: structure?.json(),
            hasAttachments: structure?.hasAttachments ?? false)
    }

    /// Fetches decoded text for the given parts of one message in a single round trip.
    func fetchParts(uid: UInt32, parts: [BodyPart]) async throws -> [String: Data] {
        guard !parts.isEmpty else { return [:] }
        let items = parts.map { "BODY.PEEK[\($0.partID)]" }.joined(separator: " ")
        let results = try await fetch("\(uid)", items: "(UID \(items))")
        var out: [String: Data] = [:]
        for r in results where r.uid == uid {
            for p in parts {
                if let raw = r.items["BODY[\(p.partID)]"]?.data { out[p.partID] = MIME.decode(raw, encoding: p.encoding) }
            }
        }
        return out
    }

    /// Raw (still transfer-encoded) parts for several messages in one command.
    func fetchRawParts(uids: [UInt32], partIDs: [String]) async throws -> [UInt32: [String: Data]] {
        guard !uids.isEmpty, !partIDs.isEmpty else { return [:] }
        let items = partIDs.map { "BODY.PEEK[\($0)]" }.joined(separator: " ")
        let results = try await fetch(imapUIDSet(uids), items: "(UID \(items))")
        var out: [UInt32: [String: Data]] = [:]
        for r in results {
            guard let uid = r.uid else { continue }
            for p in partIDs {
                if let d = r.items["BODY[\(p)]"]?.data { out[uid, default: [:]][p] = d }
            }
        }
        return out
    }

    /// Streams one part to a file in 2 MB chunks, decoding as it goes.
    func downloadPart(uid: UInt32, part: BodyPart, to url: URL) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = 2 * 1024 * 1024
        var offset = 0
        var b64 = StreamingBase64Decoder()
        let enc = part.encoding.lowercased()
        var qpBuffer = Data()
        while true {
            let results = try await fetch("\(uid)", items: "(UID BODY.PEEK[\(part.partID)]<\(offset).\(chunk)>)")
            guard let r = results.first(where: { $0.uid == uid }), let raw = r.items["BODY[\(part.partID)]"]?.data else { break }
            switch enc {
            case "base64": handle.write(b64.feed(raw))
            case "quoted-printable": qpBuffer.append(raw)
            default: handle.write(raw)
            }
            offset += raw.count
            if raw.count < chunk { break }
        }
        if enc == "base64" { handle.write(b64.finish()) }
        if enc == "quoted-printable" { handle.write(MIME.decodeQuotedPrintable(qpBuffer)) }
    }
}
