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
        // Gmail names its system folders the same in every account. A server may leave the special-use
        // attributes out of LIST — RFC 6154 only requires them when the client asks — and without this
        // fallback Drafts, Sent and Trash all end up with no role, so saving a draft finds no folder.
        for prefix in ["[gmail]/", "[google mail]/"] where lower.hasPrefix(prefix) {
            switch String(lower.dropFirst(prefix.count)) {
            case "all mail": return .all
            case "sent mail": return .sent
            case "drafts": return .drafts
            case "spam": return .spam
            case "trash": return .trash
            case "starred": return .starred
            case "important": return .important
            default: break
            }
        }
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

    /// Deliberately not cancellation-aware: a command that already waited its turn still runs, because
    /// the multi-step writers (Empty Trash, the MOVE fallback) rely on their rollback commands going
    /// out even when the task that started them was cancelled.
    private func lockCommands() async {
        if commandBusy { await withCheckedContinuation { commandWaiters.append($0) } } else { commandBusy = true }
    }

    /// Takes the command lock only when no command is in flight.
    private func tryLockCommands() -> Bool {
        if commandBusy { return false }
        commandBusy = true
        return true
    }

    private func unlockCommands() {
        if commandWaiters.isEmpty { commandBusy = false } else { commandWaiters.removeFirst().resume() }
    }

    /// Builds the byte transport; nil uses the real network. Injectable so tests can script a server.
    private let makeTransport: (@Sendable () -> ByteTransport)?

    init(host: String, port: UInt16, username: String, password: String, security: ConnectionSecurity = .tls,
         transport: (@Sendable () -> ByteTransport)? = nil) {
        makeTransport = transport
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
        let s = makeTransport.map { TLSStream(transport: $0()) } ?? TLSStream(host: host, port: port, security: security)
        try await s.open()
        stream = s
        do {
            let greeting = try await withReadTimeout(Limits.greetingTimeout) { try await self.readResponse() }
            guard greeting.status == "OK" || greeting.status == "PREAUTH" else {
                throw NetError.protocolError(greeting.text)
            }
            let preauthenticated = greeting.status == "PREAUTH"
            if security == .startTLS {
                // STARTTLS is only valid before authentication (RFC 3501 §6.2.1): a server that greets
                // with PREAUTH on a plain connection can never be upgraded, so it is refused.
                guard !preauthenticated else {
                    throw NetError.server("\(host) signs in before encryption starts on port \(port). Use SSL/TLS (usually port 993).")
                }
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
            // A PREAUTH greeting means the connection is already signed in; LOGIN there is an error
            // (RFC 3501 §6.2), so it is skipped and the capabilities are asked for below.
            if !preauthenticated {
                do {
                    _ = try await run("LOGIN \(username.imapQuoted) \(password.imapQuoted)", timeout: 30)
                } catch NetError.server(let m) {
                    throw NetError.auth(m.isEmpty ? "the server rejected the email or App Password." : m)
                }
                if let code = lastTaggedCode, code.uppercased().hasPrefix("CAPABILITY ") {
                    capabilities = Set(code.split(separator: " ").dropFirst().map { $0.uppercased() })
                }
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

    /// Closes the connection. LOGOUT is only written when no command is in flight: actors are
    /// re-entrant, so writing it unlocked could land in the middle of another command's literal
    /// (an APPEND upload) and corrupt the message being stored. A busy connection is simply closed,
    /// which also ends an IDLE at once; the interrupted command fails with a closed connection.
    func disconnect() async {
        if let s = stream {
            if tryLockCommands() {
                try? await s.send("Z LOGOUT\r\n")
                unlockCommands()
            }
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
    /// a command forever. The failure the close causes is reported as a timeout, not as "closed".
    private func withReadTimeout<T>(_ seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
        let s = stream
        let fired = FiredFlag()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            fired.fire()
            await s?.close()
        }
        defer { watchdog.cancel() }
        do { return try await body() } catch {
            if fired.didFire, !Self.isRefusal(error) { throw NetError.timeout }
            throw error
        }
    }

    /// A tagged NO/BAD (or a failed sign-in): the server answered, so the connection is still in step.
    private static func isRefusal(_ error: Error) -> Bool {
        switch error as? NetError {
        case .server, .auth: return true
        default: return false
        }
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
                // Over the cap the literal is refused outright: reading only the cap would leave the
                // rest of the payload to be parsed as protocol lines and desynchronise the connection.
                guard n <= Limits.maxResponseBytes else {
                    throw NetError.protocolError("literal of \(n) bytes exceeds the response limit")
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
        let fired = FiredFlag()
        let watchdog = Task { [weak s] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            fired.fire()
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
                        guard untagged.count < Limits.maxUntagged else {
                            throw NetError.protocolError("too many untagged responses")
                        }
                        let r = try await readResponse()
                        if r.isContinuation { break }
                        if r.tag == tag { throw NetError.server(r.text) }
                        untagged.append(r)
                    }
                    // A literal is part of the command line, and the line still ends with CRLF after
                    // the literal's octets (RFC 3501 §4.3, §6.3.11: "APPEND … {310}" CRLF, 310 octets,
                    // CRLF). The CRLF below is that terminator (or follows the next segment), not an
                    // extra empty line.
                    var payload = lit
                    let tail = i < trailing.count ? trailing[i] : ""
                    payload.append(Data((tail + "\r\n").utf8))
                    try await s.send(payload)
                }
            }
            while true {
                guard untagged.count < Limits.maxUntagged else {
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
            // The watchdog cut a silent connection: say "took too long", not "closed".
            throw fired.didFire ? NetError.timeout : e
        } catch {
            await drop()
            throw fired.didFire ? NetError.timeout : NetError.closed
        }
    }

    // MARK: Commands

    /// RFC 6154: the special-use attributes are only guaranteed when the client asks for them. Without
    /// this a server is free to omit them, and no folder but INBOX gets a role.
    private var specialUseReturn: String { capabilities.contains("SPECIAL-USE") ? " RETURN (SPECIAL-USE)" : "" }

    func list() async throws -> [ListedFolder] {
        let rs = try await run("LIST \"\" \"*\"" + specialUseReturn)
        var out: [ListedFolder] = []
        for r in rs where r.isUntagged {
            guard r.values.count >= 4, r.values[0].text?.uppercased() == "LIST" else { continue }
            // A truncated LIST line means the response was cut short; refusing here keeps the caller
            // from pruning the whole folder cache off a partial list.
            let attrs = r.values[1].list?.compactMap { $0.text } ?? []
            // NIL means a flat namespace: there is no hierarchy separator, which is stored as "".
            let delim = r.values[2].text ?? ""
            guard let rawName = r.values[3].text else { throw NetError.protocolError("truncated LIST response") }
            out.append(ListedFolder(path: MailboxName.decode(rawName), delimiter: delim, attributes: attrs))
        }
        return out
    }

    /// Folder list plus unread counts in one command where the server supports LIST-STATUS (O-07);
    /// the counts map is empty when it doesn't, and the caller falls back to STATUS per folder.
    func listWithStatus() async throws -> ([ListedFolder], [String: Int]) {
        var options: [String] = []
        if capabilities.contains("SPECIAL-USE") { options.append("SPECIAL-USE") }
        if capabilities.contains("LIST-STATUS") { options.append("STATUS (UNSEEN)") }
        guard !options.isEmpty else { return (try await list(), [:]) }
        let rs = try await run("LIST \"\" \"*\" RETURN (\(options.joined(separator: " ")))")
        var out: [ListedFolder] = []
        var counts: [String: Int] = [:]
        for r in rs where r.isUntagged {
            let word = r.values.first?.text?.uppercased()
            if word == "LIST", r.values.count >= 4 {
                let attrs = r.values[1].list?.compactMap { $0.text } ?? []
                let delim = r.values[2].text ?? ""
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
    /// The same snapshot-and-rollback runs with and without UIDPLUS (H-06):
    ///  - ALL is snapshotted first and only the snapshot is flagged and expunged, never `1:*`, so mail
    ///    that arrives meanwhile is left alone.
    ///  - Messages another client already flagged \Deleted are not flagged again, so a rollback never
    ///    takes their flag back. With CONDSTORE the flag read and the STORE are tied together by
    ///    UNCHANGEDSINCE, which closes the gap between the two (H-08); without it the read happens
    ///    immediately before each STORE, which is the narrowest window plain IMAP allows.
    ///  - Any failure takes back exactly the flags this command added, so a later EXPUNGE from any
    ///    client can't purge the folder after the user was told it failed.
    func expungeAll() async throws {
        let ours = try await snapshotUIDs()
        guard !ours.isEmpty else { return }
        let uidplus = capabilities.contains("UIDPLUS")
        let conditional = hasCondstore && lastSelectInfo.highestModseq > 0
        var marked: [UInt32] = []
        do {
            var changedElsewhere = false
            for chunk in ours.chunked(1000) {
                let set = imapUIDSet(chunk)
                var already = Set<UInt32>()
                var since: UInt64?
                if conditional {
                    let rows = try await fetch(set, items: "(UID FLAGS MODSEQ)")
                    var highest: UInt64 = 0
                    var complete = true
                    for r in rows {
                        guard let uid = r.uid else { continue }
                        let flags = r.items["FLAGS"]?.list?.compactMap { $0.text?.lowercased() } ?? []
                        if flags.contains("\\deleted") { already.insert(uid) }
                        if let m = r.items["MODSEQ"]?.list?.first?.number { highest = max(highest, m) } else { complete = false }
                    }
                    if complete, highest > 0 { since = highest }
                    else { already = Set(try await uidSearch("UID \(set) DELETED")) }
                } else {
                    already = Set(try await uidSearch("UID \(set) DELETED"))
                }
                let mine = chunk.filter { !already.contains($0) }
                guard !mine.isEmpty else { continue }
                let mineSet = imapUIDSet(mine)
                guard let since else {
                    // Recorded before the command: a STORE that fails may still have been applied.
                    marked += mine
                    try await run("UID STORE \(mineSet) +FLAGS.SILENT (\\Deleted)")
                    continue
                }
                // Conditional STORE: a message another client touched after the flag read is refused and
                // listed in [MODIFIED], so it is never counted as flagged by this command.
                var refused: Set<UInt32>? = []
                do {
                    try await run("UID STORE \(mineSet) (UNCHANGEDSINCE \(since)) +FLAGS.SILENT (\\Deleted)")
                    refused = Self.modifiedUIDs(lastTaggedCode)
                } catch NetError.server(let message) {
                    // Some servers answer NO [MODIFIED …] when nothing could be changed.
                    let code = lastTaggedCode ?? ""
                    guard code.uppercased().hasPrefix("MODIFIED") else {
                        marked += mine
                        throw NetError.server(message)
                    }
                    refused = Self.modifiedUIDs(code)
                } catch {
                    marked += mine
                    throw error
                }
                guard let refused else {
                    // A [MODIFIED] list that can't be read (oversized or malformed) says something was
                    // refused but not what: stop, and take the flag back from the whole chunk (H-13).
                    marked += mine
                    changedElsewhere = true
                    continue
                }
                marked += mine.filter { !refused.contains($0) }
                if !refused.isEmpty { changedElsewhere = true }
            }
            guard !changedElsewhere else {
                throw NetError.server("The folder changed while it was being emptied. Try again.")
            }
            if uidplus {
                // UID EXPUNGE only removes messages that are still \Deleted. One that another client
                // un-flagged since the STORE would silently survive while the folder is reported
                // empty, so the snapshot is checked first (H-09).
                for chunk in ours.chunked(1000) {
                    guard try await uidSearch("UID \(imapUIDSet(chunk)) UNDELETED").filter({ chunk.contains($0) }).isEmpty else {
                        throw NetError.server("The folder changed while it was being emptied. Try again.")
                    }
                }
                // UID EXPUNGE only touches the snapshot, so other pending deletions outside it survive.
                for chunk in ours.chunked(1000) {
                    try await run("UID EXPUNGE \(imapUIDSet(chunk))", timeout: 300)
                }
            } else {
                // A bare EXPUNGE purges every \Deleted message, so it only runs when the pending
                // deletions are exactly the snapshot. Anything else (a message that arrived already
                // deleted by another client) is reported instead of telling the user the folder is empty.
                let deleted = Set(try await uidSearch("DELETED"))
                guard deleted == Set(ours) else {
                    throw NetError.server("The folder changed while it was being emptied. Try again.")
                }
                try await run("EXPUNGE", timeout: 300)
            }
        } catch {
            // Best effort: on a dead connection there is nothing left to send. UIDs that were already
            // expunged are simply ignored by the server.
            for chunk in marked.chunked(1000) {
                _ = try? await run("UID STORE \(imapUIDSet(chunk)) -FLAGS.SILENT (\\Deleted)")
            }
            throw error
        }
    }

    /// Every UID in the selected mailbox. A big mailbox is read in windows: `UID SEARCH ALL` answers
    /// on one line, and a line over the 1 MB limit would drop the connection. The windows are message
    /// sequence ranges, which are dense, so the cost follows the message count and not how sparse the
    /// UIDs are (H-11). Sequence numbers shift when another client expunges, so an EXPUNGE seen during
    /// the walk falls back to UID windows, which never shift.
    private func snapshotUIDs() async throws -> [UInt32] {
        let info = lastSelectInfo
        guard info.exists > 50_000 else { return try await uidSearch("ALL") }
        var bySequence: [UInt32] = []
        var shifted = false
        var first: UInt64 = 1
        let count = UInt64(info.exists)
        while first <= count, !shifted {
            let last = min(count, first + 19_999)
            let rs = try await run("UID SEARCH \(first):\(last)")
            shifted = rs.contains { r in
                r.isUntagged && r.values.count >= 2 && r.values[1].text?.uppercased() == "EXPUNGE"
            }
            bySequence += Self.searchResults(rs)
            first = last + 1
        }
        if !shifted { return bySequence }
        var top = UInt64(info.uidNext > 0 ? info.uidNext - 1 : 0)
        if top == 0 {
            top = UInt64(try await fetch("*", items: "(UID)", uid: false).compactMap { $0.uid }.max() ?? 0)
        }
        var out: [UInt32] = []
        var lo: UInt64 = 1
        while lo <= top {
            let hi = min(top, lo + 19_999)
            // `lo:hi` past the last message can still return the last one (RFC 3501 ranges); keep the window.
            out += try await uidSearch("UID \(lo):\(hi)").filter { UInt64($0) >= lo && UInt64($0) <= hi }
            lo = hi + 1
        }
        return out
    }

    /// UIDs from a tagged `[MODIFIED 7,9:12]` response code (RFC 7162); empty for any other code.
    /// nil when the code is MODIFIED but its list can't be read in full (a malformed piece, or a range
    /// too large to expand): the caller must then treat every UID it sent as possibly refused (H-13).
    static func modifiedUIDs(_ code: String?) -> Set<UInt32>? {
        let parts = (code ?? "").split(separator: " ")
        guard let word = parts.first, word.uppercased() == "MODIFIED" else { return [] }
        guard parts.count == 2 else { return nil }
        var out = Set<UInt32>()
        for piece in parts[1].split(separator: ",", omittingEmptySubsequences: false) {
            let raw = piece.split(separator: ":", omittingEmptySubsequences: false)
            let ends = raw.compactMap { UInt32($0) }
            guard !ends.isEmpty, ends.count == raw.count, ends.count <= 2,
                  let lo = ends.min(), let hi = ends.max() else { return nil }
            // A hostile range must not allocate the whole UID space.
            guard hi - lo <= 100_000, out.count <= 100_000 else { return nil }
            for u in lo...hi { out.insert(u) }
        }
        return out
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
        if !force, selectedPath == path, readOnly || !selectedReadOnly { return nil }
        let verb = readOnly ? "EXAMINE" : "SELECT"
        let suffix = hasCondstore ? " (CONDSTORE)" : ""
        // A failed SELECT leaves the connection with no mailbox selected (RFC 3501 §6.3.1), so the old
        // selection is forgotten first; otherwise the next "already selected" shortcut would be wrong.
        selectedPath = nil
        lastSelectInfo = SelectInfo()
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
        } else if capabilities.contains("UIDPLUS") {
            try await run("UID COPY \(set) \(mbox)")
            try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            try await run("UID EXPUNGE \(set)")
        } else {
            // Without UIDPLUS only a bare EXPUNGE can remove the originals, and that is refused while
            // another client has deletions pending. Checked before the COPY: refusing afterwards left a
            // copy in the destination, and trying the move again then made a second one.
            let already = try await pendingDeletions(among: uids)
            try await run("UID COPY \(set) \(mbox)")
            try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            try await expungeExactly(uids, marked: uids.filter { !already.contains($0) })
        }
    }

    func expungeUIDs(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        let set = imapUIDSet(uids)
        if capabilities.contains("UIDPLUS") {
            try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            try await run("UID EXPUNGE \(set)")
        } else {
            let already = try await pendingDeletions(among: uids)
            try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
            try await expungeExactly(uids, marked: uids.filter { !already.contains($0) })
        }
    }

    private static let otherClientDeletions =
        "The server has pending deletions from another mail client, so the message wasn't removed."

    /// Which of these UIDs are already \Deleted. Throws when a message outside them is pending deletion:
    /// the bare EXPUNGE that follows would purge it too. Not temporary-refusal wording on purpose:
    /// AccountEngine drops the op and reports it instead of retrying against the other client forever.
    private func pendingDeletions(among uids: [UInt32]) async throws -> Set<UInt32> {
        let deleted = Set(try await uidSearch("DELETED"))
        guard deleted.isSubset(of: uids) else { throw NetError.server(Self.otherClientDeletions) }
        return deleted
    }

    /// Bare EXPUNGE only when the pending deletions are exactly these UIDs, so other clients' deleted
    /// messages survive (a subset check would still let EXPUNGE purge theirs).
    /// `marked` are the UIDs this operation flagged itself; only those are un-flagged on a refusal, so a
    /// deletion that was already pending on one of them is not reverted.
    private func expungeExactly(_ uids: [UInt32], marked: [UInt32]) async throws {
        // Only the UIDs that still exist count: one already removed elsewhere (another client, Empty
        // Trash) is simply done, not a mismatch to report.
        let present = Set(try await uidSearch("UID \(imapUIDSet(uids))")).intersection(uids)
        guard !present.isEmpty else { return }
        let deleted = Set(try await uidSearch("DELETED"))
        guard deleted == present else {
            // Un-flag what we marked: a bare EXPUNGE now would also purge another client's pending
            // deletions, and returning would drop the op as success while the message survives here.
            if !marked.isEmpty { try await run("UID STORE \(imapUIDSet(marked)) -FLAGS.SILENT (\\Deleted)") }
            throw NetError.server(Self.otherClientDeletions)
        }
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
        // Untagged updates may arrive before the "+": returning on one would leave IDLE running on the
        // wire and desynchronise the next command, so read on until the continuation (or a refusal).
        // The wait is as unbound as any other read: a silent server must not hang the idle lane.
        var changedEarly = false
        do {
            try await withReadTimeout(Limits.greetingTimeout) {
                var turns = 0
                while true {
                    turns += 1
                    guard turns <= Limits.maxUntagged else { throw NetError.protocolError("too many untagged responses") }
                    let r = try await self.readResponse()
                    if r.isContinuation { return }
                    if r.tag == tag { throw NetError.server(r.text.isEmpty ? "IDLE failed" : r.text) }
                    if r.isUntagged && r.status == "BYE" { throw NetError.closed }
                    if r.isUntagged, r.values.count >= 2, let word = r.values[1].text?.uppercased(),
                       word == "EXISTS" || word == "EXPUNGE" || word == "FETCH" { changedEarly = true }
                }
            }
        } catch let e as NetError {
            // A tagged refusal leaves the connection usable; anything else means it is out of step.
            if case .server = e { throw e }
            await drop()
            throw e
        } catch {
            await drop()
            throw error
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
        var changed = changedEarly
        var turns = 0
        do {
            if changedEarly { await endIdle() }
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
        // An unsolicited flag update (`* 5 FETCH (UID 9 FLAGS (..))`) can arrive in the middle of a header
        // fetch; without the header block it is not a message row and must not be stored as a blank one.
        guard let uid = r.uid, let headerData = r.item(prefix: "BODY[HEADER")?.data else { return nil }
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
            size: Int(clamping: r.items["RFC822.SIZE"]?.number ?? 0), flags: flags, subject: subject, from: from,
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
                // A server that keeps sending past the advertised size (with a small margin) is cut
                // off before the excess reaches the disk.
                guard offset + raw.count <= maxBytes else {
                    throw NetError.protocolError("attachment sent more data than advertised")
                }
                switch enc {
                case "base64": try handle.write(contentsOf: b64.feed(raw))
                case "quoted-printable":
                    // Decode complete lines only, so a soft break or =XX never spans two chunks in RAM.
                    qpBuffer.append(raw)
                    if let r = qpBuffer.range(of: newline, options: [.backwards]) {
                        let complete = qpBuffer.subdata(in: qpBuffer.startIndex..<r.upperBound)
                        qpBuffer.removeSubrange(qpBuffer.startIndex..<r.upperBound)
                        if !complete.isEmpty { try handle.write(contentsOf: MIME.decodeQuotedPrintable(complete)) }
                    }
                default: try handle.write(contentsOf: raw)
                }
                offset += raw.count
                if raw.count < chunk { break }
            }
            if enc == "base64" { try handle.write(contentsOf: b64.finish()) }
            if enc == "quoted-printable" { try handle.write(contentsOf: MIME.decodeQuotedPrintable(qpBuffer)) }
            // Verify the bytes received against BODYSTRUCTURE: its size is the transfer-encoded octet
            // count, which is exactly what BODY[part] returns, so a short total means truncation.
            if part.size > 0 && offset != part.size {
                throw NetError.server("The attachment arrived incomplete from the server. Try downloading it again.")
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
