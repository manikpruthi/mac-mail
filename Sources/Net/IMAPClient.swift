import Foundation

struct SelectInfo {
    var exists: UInt32 = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
    var highestModseq: UInt64 = 0
    /// What the server actually granted, from its tagged [READ-ONLY]/[READ-WRITE] code.
    var readOnly: Bool = false
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
    let security: ConnectionSecurity

    private var stream: TLSStream?
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private(set) var selectedPath: String?
    private var selectedReadOnly = false
    /// Info from the most recent successful SELECT/EXAMINE on this connection.
    private var lastSelectInfo = SelectInfo()
    /// Response code of the last tagged OK (e.g. "CAPABILITY …" after LOGIN).
    private var lastTaggedCode: String?
    private var idleTag: String?
    private var idleDoneSent = false
    // Actors are re-entrant at every await, so commands need their own lock or two could interleave on the wire.
    private var commandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    /// Hard caps so a malicious or broken server can't balloon memory or hang the connection.
    private enum Limits {
        static let maxUntagged = 10_000
        static let maxResponseBytes = 64 * 1024 * 1024
        static let maxResponseDepth = 100
        static let greetingTimeout: TimeInterval = 60
        /// Extra time after IDLE's own limit for the server to answer DONE before the stream is cut.
        static let idleGrace: TimeInterval = 30
    }

    private func lockCommands() async {
        if commandBusy { await withCheckedContinuation { commandWaiters.append($0) } } else { commandBusy = true }
    }

    private func unlockCommands() {
        if commandWaiters.isEmpty { commandBusy = false } else { commandWaiters.removeFirst().resume() }
    }

    init(host: String, port: UInt16, username: String, password: String, security: ConnectionSecurity = .tls) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.security = security
    }

    /// True only while the stream is actually open (a dropped connection shows up as isClosed).
    var isConnected: Bool {
        get async {
            guard let s = stream else { return false }
            return await !s.isClosed
        }
    }
    var isGmail: Bool { capabilities.contains("X-GM-EXT-1") }
    var hasCondstore: Bool { capabilities.contains("CONDSTORE") }
    var hasMove: Bool { capabilities.contains("MOVE") }
    var hasIdle: Bool { capabilities.contains("IDLE") }

    // MARK: Connection

    /// TLS, then LOGIN. Gmail (and most servers) send their capabilities in the LOGIN reply, so the separate
    /// CAPABILITY round trip is only made when they don't; CONDSTORE turns on with the first SELECT (CONDSTORE).
    func connect() async throws {
        let s = TLSStream(host: host, port: port, security: security)
        try await s.open()
        stream = s
        do {
            let greeting = try await withReadTimeout(Limits.greetingTimeout) { try await self.readResponse() }
            guard greeting.status == "OK" || greeting.status == "PREAUTH" else {
                throw NetError.protocolError(greeting.text)
            }
            if security == .startTLS {
                // Fail closed: without STARTTLS the password would cross the network in the clear (F-01).
                try await refreshCapabilities()
                guard capabilities.contains("STARTTLS") else {
                    throw NetError.server("\(host) doesn't offer STARTTLS on port \(port). Use SSL/TLS (usually port 993).")
                }
                _ = try await run("STARTTLS", timeout: 30)
                try await s.startTLS()
                // Capabilities seen before TLS can't be trusted (RFC 3501 §6.2.1); ask again.
                capabilities = []
                try await refreshCapabilities()
            }
            do {
                _ = try await run("LOGIN \(username.imapQuoted) \(password.imapQuoted)", timeout: 30)
            } catch NetError.server(let m) {
                throw NetError.auth(m.isEmpty ? "the server rejected the email or App Password." : m)
            }
            if let code = lastTaggedCode, code.uppercased().hasPrefix("CAPABILITY ") {
                capabilities = Set(code.split(separator: " ").dropFirst().map { $0.uppercased() })
            }
            if capabilities.isEmpty { try await refreshCapabilities() }
        } catch {
            await s.close()
            stream = nil
            throw error
        }
    }

    private func refreshCapabilities() async throws {
        let caps = try await run("CAPABILITY", timeout: 20)
        for r in caps where r.isUntagged {
            if let first = r.values.first?.text, first.uppercased() == "CAPABILITY" {
                capabilities = Set(r.values.dropFirst().compactMap { $0.text?.uppercased() })
            }
        }
    }

    func disconnect() async {
        if let s = stream {
            try? await s.send("Z LOGOUT\r\n")
            await s.close()
        }
        stream = nil
        selectedPath = nil
        lastSelectInfo = SelectInfo()
    }

    private func drop() async {
        if let s = stream { await s.close() }
        stream = nil
        selectedPath = nil
        lastSelectInfo = SelectInfo()
    }

    /// Bounds a read with a watchdog that force-closes the stream, so a silent server can't hang
    /// a command forever (the pending read fails with NetError.closed once the stream is closed).
    private func withReadTimeout<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
        let s = stream
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await s?.close()
        }
        defer { watchdog.cancel() }
        return try await body()
    }

    // MARK: Low-level

    private func nextTag() -> String {
        tagCounter += 1
        return "M\(tagCounter)"
    }

    private func readResponse() async throws -> IMAPResponse {
        guard let s = stream else { throw NetError.closed }
        var parts: [ResponsePart] = []
        var totalBytes = 0
        while true {
            let line = try await s.readLine()
            parts.append(.text(line))
            if let n = IMAPParser.literalLength(line) {
                // A single response can't nest literals forever or carry unlimited bytes,
                // however the line itself advertises the sizes.
                guard parts.count <= Limits.maxResponseDepth else {
                    throw NetError.protocolError("response has too many literals")
                }
                totalBytes += n
                guard totalBytes <= Limits.maxResponseBytes else {
                    throw NetError.protocolError("response too large")
                }
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
                        guard untagged.count <= Limits.maxUntagged else {
                            throw NetError.protocolError("too many untagged responses")
                        }
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
                guard untagged.count <= Limits.maxUntagged else {
                    throw NetError.protocolError("too many untagged responses")
                }
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
            // A truncated LIST line means the response was cut short; refusing here keeps the caller
            // from pruning the whole folder cache off a partial list.
            let attrs = r.values[1].list?.compactMap { $0.text } ?? []
            let delim = r.values[2].text ?? "/"
            guard let rawName = r.values[3].text else { throw NetError.protocolError("truncated LIST response") }
            out.append(ListedFolder(path: MailboxName.decode(rawName), delimiter: delim, attributes: attrs))
        }
        return out
    }

    /// Folder list plus unread counts in one command where the server supports LIST-STATUS (O-07);
    /// the counts map is empty when it doesn't, and the caller falls back to STATUS per folder.
    func listWithStatus() async throws -> ([ListedFolder], [String: Int]) {
        guard capabilities.contains("LIST-STATUS") else { return (try await list(), [:]) }
        let rs = try await run("LIST \"\" \"*\" RETURN (STATUS (UNSEEN))")
        var out: [ListedFolder] = []
        var counts: [String: Int] = [:]
        for r in rs where r.isUntagged {
            let word = r.values.first?.text?.uppercased()
            if word == "LIST", r.values.count >= 4 {
                let attrs = r.values[1].list?.compactMap { $0.text } ?? []
                let delim = r.values[2].text ?? "/"
                guard let rawName = r.values[3].text else { throw NetError.protocolError("truncated LIST response") }
                out.append(ListedFolder(path: MailboxName.decode(rawName), delimiter: delim, attributes: attrs))
            } else if word == "STATUS", r.values.count >= 3, let raw = r.values[1].text, let n = Self.unseen(from: [r]) {
                counts[MailboxName.decode(raw)] = n
            }
        }
        return (out, counts)
    }

    // MARK: Folder management (F-12, F-14)

    func createMailbox(_ path: String) async throws {
        try await run("CREATE \(MailboxName.encode(path).imapQuoted)")
        _ = try? await run("SUBSCRIBE \(MailboxName.encode(path).imapQuoted)")
    }

    func renameMailbox(_ from: String, to: String) async throws {
        if selectedPath == from { selectedPath = nil }
        try await run("RENAME \(MailboxName.encode(from).imapQuoted) \(MailboxName.encode(to).imapQuoted)")
        _ = try? await run("SUBSCRIBE \(MailboxName.encode(to).imapQuoted)")
    }

    func deleteMailbox(_ path: String) async throws {
        if selectedPath == path {
            // A selected mailbox can't be deleted on some servers; leave it first.
            _ = try? await run("CLOSE")
            selectedPath = nil
        }
        try await run("DELETE \(MailboxName.encode(path).imapQuoted)")
    }

    func setSubscribed(_ path: String, _ on: Bool) async throws {
        try await run("\(on ? "SUBSCRIBE" : "UNSUBSCRIBE") \(MailboxName.encode(path).imapQuoted)")
    }

    /// Marks every message in the selected mailbox deleted and expunges (Empty Trash / Empty Spam, F-10).
    func expungeAll() async throws {
        guard lastSelectInfo.exists > 0 else { return }
        if capabilities.contains("UIDPLUS") {
            try await run("UID STORE 1:* +FLAGS.SILENT (\\Deleted)")
            try await run("UID EXPUNGE 1:*", timeout: 300)
        } else {
            // Without UIDPLUS a bare EXPUNGE would also purge messages another client flagged \Deleted;
            // expunge only when the pending deletions are exactly the ones we just made.
            let ours = Set(try await uidSearch("ALL"))
            guard !ours.isEmpty else { return }
            try await run("UID STORE 1:* +FLAGS.SILENT (\\Deleted)")
            guard Set(try await uidSearch("DELETED")) == ours else { return }
            try await run("EXPUNGE", timeout: 300)
        }
    }

    /// Storage quota for the account's root (F-27): (used KB, limit KB), nil when the server has no QUOTA.
    func quota() async throws -> (used: Int, limit: Int)? {
        guard capabilities.contains("QUOTA") else { return nil }
        let rs = try await run("GETQUOTAROOT INBOX")
        for r in rs where r.isUntagged {
            guard r.values.first?.text?.uppercased() == "QUOTA", r.values.count >= 3, let items = r.values[2].list else { continue }
            var i = 0
            while i + 2 < items.count {
                if items[i].text?.uppercased() == "STORAGE", let used = items[i + 1].number, let limit = items[i + 2].number {
                    return (Int(clamping: used), Int(clamping: limit))
                }
                i += 3
            }
        }
        return nil
    }

    /// The server's unread count for a mailbox (STATUS … (UNSEEN)); nil if the server didn't report it.
    func unseenCount(_ path: String) async throws -> Int? {
        Self.unseen(from: try await run("STATUS \(MailboxName.encode(path).imapQuoted) (UNSEEN)"))
    }

    /// Extracts UNSEEN from a STATUS reply (`* STATUS "INBOX" (UNSEEN 12)`).
    static func unseen(from rs: [IMAPResponse]) -> Int? {
        for r in rs where r.isUntagged {
            guard r.values.count >= 3, r.values[0].text?.uppercased() == "STATUS", let items = r.values[2].list else { continue }
            var i = 0
            while i + 1 < items.count {
                if items[i].text?.uppercased() == "UNSEEN", let n = items[i + 1].number { return Int(clamping: n) }
                i += 2
            }
        }
        return nil
    }

    @discardableResult
    func select(_ path: String, readOnly: Bool = false, force: Bool = true) async throws -> SelectInfo? {
        if !force, selectedPath == path, selectedReadOnly == readOnly || (!selectedReadOnly && readOnly) { return nil }
        let verb = readOnly ? "EXAMINE" : "SELECT"
        let suffix = hasCondstore ? " (CONDSTORE)" : ""
        let rs = try await run("\(verb) \(MailboxName.encode(path).imapQuoted)\(suffix)")
        selectedPath = path
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
        // The server's tagged code, not the requested mode, decides whether writes can succeed
        // (shared/delegated mailboxes come back [READ-ONLY] even after a plain SELECT).
        let tagged = (lastTaggedCode ?? "").uppercased()
        if tagged.hasPrefix("READ-ONLY") { selectedReadOnly = true }
        else if tagged.hasPrefix("READ-WRITE") { selectedReadOnly = false }
        else { selectedReadOnly = readOnly }
        info.readOnly = selectedReadOnly
        lastSelectInfo = info
        return info
    }

    /// Selects the folder unless it's already the current one, and returns the selection info either way
    /// (no extra round trip when the folder is unchanged).
    @discardableResult
    func ensureSelected(_ path: String, readOnly: Bool) async throws -> SelectInfo {
        try await select(path, readOnly: readOnly, force: false)
        return lastSelectInfo
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

    func fetch(_ set: String, items: String, uid: Bool = true, changedSince: UInt64? = nil,
               timeout: TimeInterval = 180) async throws -> [FetchResult] {
        var cmd = (uid ? "UID FETCH " : "FETCH ") + set + " " + items
        if let m = changedSince { cmd += " (CHANGEDSINCE \(m))" }
        let rs = try await run(cmd, timeout: timeout)
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
            if capabilities.contains("UIDPLUS") { try await run("UID EXPUNGE \(set)") }
            // Without UIDPLUS a bare EXPUNGE would also purge messages another client flagged \Deleted;
            // only expunge when exactly our UIDs are pending deletion.
            else { try await expungeExactly(uids) }
        }
    }

    func expungeUIDs(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = imapUIDSet(uids)
        try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") { try await run("UID EXPUNGE \(set)") } else { try await expungeExactly(uids) }
    }

    /// Bare EXPUNGE only when the pending deletions are exactly these UIDs, so other clients' deleted
    /// messages survive (a subset check would still let EXPUNGE purge theirs).
    private func expungeExactly(_ uids: [UInt32]) async throws {
        let deleted = Set(try await uidSearch("DELETED"))
        guard deleted == Set(uids) else { return }
        try await run("EXPUNGE")
    }

    /// Appends a message; returns the new UID when the server reports it (APPENDUID, UIDPLUS).
    @discardableResult
    func append(_ path: String, flags: String, message: Data) async throws -> UInt32? {
        try await run("APPEND \(MailboxName.encode(path).imapQuoted) (\(flags)) {\(message.count)}", literals: [message], timeout: 300)
        // Tagged OK [APPENDUID <uidvalidity> <uid>]
        let parts = (lastTaggedCode ?? "").split(separator: " ")
        if parts.count >= 3, parts[0].uppercased() == "APPENDUID" { return UInt32(parts[2]) }
        return nil
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
        // The server must answer DONE within the grace window; a silent one gets the stream cut
        // instead of a read that hangs forever.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64((maxSeconds + Limits.idleGrace) * 1_000_000_000))
            await s.close()
        }
        defer { timer.cancel(); watchdog.cancel(); idleTag = nil }
        var changed = false
        var turns = 0
        do {
            while true {
                turns += 1
                guard turns <= Limits.maxUntagged else {
                    throw NetError.protocolError("too many untagged responses")
                }
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
        if !gmail || thrid == 0 {
            let people = ([from.email] + MIME.parseAddresses(h["to"] ?? "").map { $0.email }
                          + MIME.parseAddresses(h["cc"] ?? "").map { $0.email })
            thrid = MIME.threadKey(messageID: h["message-id"] ?? "", inReplyTo: h["in-reply-to"] ?? "",
                                   references: h["references"] ?? "", subject: subject, participants: people)
        }
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

    /// Streams one part to a file in 8 MB chunks (O-21: a 25 MB file is 4 round trips, not 13), decoding as it goes.
    func downloadPart(uid: UInt32, part: BodyPart, to url: URL) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        // A truncated or failed download must not leave a broken file behind.
        defer { try? handle.close() }
        do {
            let chunk = 8 * 1024 * 1024
            // A server that keeps sending past the advertised size (with a small margin) is cut off here.
            let maxBytes = max(part.size, part.decodedSize) + 1024 * 1024
            var offset = 0
            var b64 = StreamingBase64Decoder()
            let enc = part.encoding.lowercased()
            var qpBuffer = Data()
            let newline = Data("\n".utf8)
            while true {
                let results = try await fetch("\(uid)", items: "(UID BODY.PEEK[\(part.partID)]<\(offset).\(chunk)>)")
                guard let r = results.first(where: { $0.uid == uid }), let raw = r.items["BODY[\(part.partID)]"]?.data else { break }
                switch enc {
                case "base64": handle.write(b64.feed(raw))
                case "quoted-printable":
                    // Decode complete lines only, so a soft break or =XX never spans two chunks in RAM.
                    qpBuffer.append(raw)
                    if let r = qpBuffer.range(of: newline, options: [.backwards]) {
                        let complete = qpBuffer.subdata(in: qpBuffer.startIndex..<r.upperBound)
                        qpBuffer.removeSubrange(qpBuffer.startIndex..<r.upperBound)
                        if !complete.isEmpty { handle.write(MIME.decodeQuotedPrintable(complete)) }
                    }
                default: handle.write(raw)
                }
                offset += raw.count
                guard offset <= maxBytes else {
                    throw NetError.protocolError("attachment sent more data than advertised")
                }
                if raw.count < chunk { break }
            }
            if enc == "base64" { handle.write(b64.finish()) }
            if enc == "quoted-printable" { handle.write(MIME.decodeQuotedPrintable(qpBuffer)) }
            // Verify the decoded size against BODYSTRUCTURE: short chunks don't end the fetch, a short
            // total does mean truncation.
            let written = Int64(handle.offsetInFile)
            if part.decodedSize > 0 && written != Int64(part.decodedSize) {
                throw NetError.server("The attachment arrived incomplete from the server. Try downloading it again.")
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
