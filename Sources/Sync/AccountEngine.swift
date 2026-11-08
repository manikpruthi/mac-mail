import Foundation

/// Sync and server actions for one account. Uses three IMAP connections so a long sync never blocks
/// opening a message: `sync` (sync + actions), `fetch` (bodies, attachments, search) and `idle` (push for Inbox).
@MainActor
final class AccountEngine {
    /// sync: delta sync + queued actions · fetch: what you click (bodies, inline images, search) ·
    /// prefetch: background body caching · idle: Inbox push · download: attachment saves.
    /// Keeping clicks on their own connection means they never wait behind background work.
    enum Lane { case sync, fetch, prefetch, idle, download }

    private(set) var account: Account
    let store: Store
    private var clients: [Lane: IMAPClient] = [:]
    private var connecting: [Lane: Task<IMAPClient, Error>] = [:]
    private var syncing: Set<Int64> = []
    /// One gate per connection: "select folder, then act" must run as a unit on that connection.
    private let syncGate = AsyncGate()
    private let fetchGate = AsyncGate()
    private let downloadGate = AsyncGate()
    private let prefetchGate = AsyncGate()
    private var idleTask: Task<Void, Never>?
    private var flushing = false
    private(set) var isGmail: Bool
    private(set) var lastError: String?
    private(set) var syncingFolders = 0
    var onNewMail: ((AccountEngine, [ParsedHeader]) -> Void)?

    init(account: Account, store: Store) {
        self.account = account
        self.store = store
        self.isGmail = account.provider == .gmail
    }

    var isDemo: Bool { account.provider == .demo }

    func update(account: Account) { self.account = account }

    // MARK: Connections

    func client(_ lane: Lane) async throws -> IMAPClient {
        if let c = clients[lane], await c.isConnected { return c }
        if let pending = connecting[lane] { return try await pending.value }
        let password = try await appPassword()
        let a = account
        let t0 = Date()
        let task = Task<IMAPClient, Error> {
            let c = IMAPClient(host: a.imapHost, port: a.imapPort, username: a.username, password: password)
            try await c.connect()
            return c
        }
        connecting[lane] = task
        defer { connecting[lane] = nil }
        let c = try await task.value
        Debug.log("\(lane) connection ready: \(Debug.ms(since: t0))")
        clients[lane] = c
        isGmail = await c.isGmail
        return c
    }

    private var cachedPassword: String?
    private var passwordTask: Task<String?, Never>?

    /// Reads the App Password once, off the main thread: a Keychain read can block for seconds
    /// (macOS verifies the app before releasing the item), which would freeze the window.
    func appPassword() async throws -> String {
        if let p = cachedPassword { return p }
        let task = passwordTask ?? {
            let id = account.id
            let t = Task.detached(priority: .userInitiated) { () -> String? in
                let t0 = Date()
                let p = Keychain.get(id)
                Debug.log("keychain read: \(Debug.ms(since: t0))")
                return p
            }
            passwordTask = t
            return t
        }()
        guard let p = await task.value else {
            passwordTask = nil
            throw NetError.auth("no App Password saved for \(account.email). Open Settings → Accounts.")
        }
        cachedPassword = p
        return p
    }

    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        let all = clients.values
        clients.removeAll()
        for c in all { Task { await c.disconnect() } }
    }

    private func report(_ error: Error?) {
        let message = error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
        if message != lastError {
            lastError = message
            NotificationCenter.default.post(name: .mailStatusChanged, object: self)
        }
    }

    // MARK: Start-up

    func start() {
        guard !isDemo else { return }
        // The click connection opens first and in parallel, so a message you open right after launch
        // isn't stuck behind the startup sync.
        Task { await prewarmFetch() }
        Task {
            if store.folder(account: account.id, role: .inbox) == nil {
                await refreshFolders()
            }
            if let inbox = store.folder(account: account.id, role: .inbox) {
                await sync(folderID: inbox.id, prefetch: false)
                Task { await prefetchBodies(folderID: inbox.id, limit: 60) }
            }
            await flushOps()
            // Refresh the folder list after the Inbox is on screen; it changes rarely.
            await refreshFolders()
            startIdle()
        }
    }

    /// Opens the click connection ahead of time (TLS + login + Inbox selected), so the first message you open
    /// that isn't cached yet costs one round trip instead of three.
    private func prewarmFetch() async {
        guard let inbox = store.folder(account: account.id, role: .inbox) else { return }
        let t0 = Date()
        _ = try? await fetchGate.run {
            let c = try await client(.fetch)
            try await c.ensureSelected(inbox.path, readOnly: true)
        }
        Debug.log("fetch connection warmed: \(Debug.ms(since: t0))")
    }

    func refreshFolders() async {
        do {
            let (listed, gmail) = try await syncGate.run { () async throws -> ([ListedFolder], Bool) in
                let c = try await client(.sync)
                return (try await c.list(), await c.isGmail)
            }
            store.upsertFolders(account: account.id, listed, isGmail: gmail)
            NotificationCenter.default.post(name: .mailFoldersChanged, object: self)
            report(nil)
        } catch {
            report(error)
        }
    }

    // MARK: Sync

    private func beginSync() {
        syncingFolders += 1
        NotificationCenter.default.post(name: .mailStatusChanged, object: self)
    }

    private func endSync() {
        syncingFolders -= 1
        NotificationCenter.default.post(name: .mailStatusChanged, object: self)
    }

    /// Delta sync of one folder: new mail since the last UIDNEXT, flag changes since the last MODSEQ, and removals.
    func sync(folderID: Int64, prefetch: Bool = true) async {
        guard !isDemo, !syncing.contains(folderID), let folder = store.folder(folderID), folder.selectable else { return }
        syncing.insert(folderID)
        beginSync()
        defer { syncing.remove(folderID); endSync() }
        var prefetchLimit = 0
        do {
          try await syncGate.run {
            let c = try await client(.sync)
            guard let info = try await c.select(folder.path, readOnly: false) else { return }
            var state = folder
            if state.uidValidity != 0 && state.uidValidity != info.uidValidity {
                store.resetFolder(folderID)
                state.uidNext = 0
                state.modseq = 0
            }
            var newHeaders: [ParsedHeader] = []
            let isInitial = state.uidNext == 0 || store.messageCount(folderID: folderID) == 0

            if isInitial {
                var uids = Set<UInt32>()
                if info.exists > 0 {
                    let from = max(1, Int(info.exists) - 199)
                    let recent = try await c.fetch("\(from):\(info.exists)", items: "(UID)", uid: false)
                    uids.formUnion(recent.compactMap { $0.uid })
                    let since = Date().addingTimeInterval(-Double(Prefs.offlineDays) * 86400)
                    uids.formUnion(try await c.uidSearch("SINCE \(MIME.imapSearchDate(since))"))
                }
                // Newest first, so the top of the list fills in within the first round trip.
                for chunk in uids.sorted(by: >).chunked(200) {
                    let headers = try await c.fetchHeaders(imapUIDSet(chunk))
                    store.insert(folderID: folderID, headers)
                    NotificationCenter.default.post(name: .mailDataChanged, object: folderID)
                }
            } else {
                let next = state.uidNext > 0 ? state.uidNext : (store.maxUID(folderID: folderID).map { $0 + 1 } ?? 1)
                if info.uidNext == 0 || info.uidNext > next {
                    let headers = try await c.fetchHeaders("\(next):*").filter { $0.uid >= next }
                    store.insert(folderID: folderID, headers)
                    newHeaders = headers
                }
                if let minUID = store.minUID(folderID: folderID) {
                    // Flag changes.
                    if await c.hasCondstore, state.modseq > 0 {
                        if info.highestModseq != state.modseq {
                            let changed = try await c.fetch("1:*", items: "(UID FLAGS)", changedSince: state.modseq)
                            store.updateFlags(folderID: folderID, changed.compactMap { r in
                                r.uid.map { ($0, MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? [])) }
                            })
                        }
                    } else {
                        let all = try await c.fetch("\(minUID):*", items: "(UID FLAGS)")
                        store.updateFlags(folderID: folderID, all.compactMap { r in
                            r.uid.map { ($0, MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? [])) }
                        })
                    }
                    // Removals (moved, archived or deleted elsewhere).
                    let present = Set(try await c.uidSearch("UID \(minUID):*"))
                    let gone = store.localUIDs(folderID: folderID).filter { !present.contains($0) }
                    store.deleteMessages(folderID: folderID, uids: gone)
                }
            }
            store.updateFolderState(folderID, uidValidity: info.uidValidity,
                                    uidNext: info.uidNext > 0 ? info.uidNext : (store.maxUID(folderID: folderID) ?? 0) + 1,
                                    modseq: info.highestModseq)
            NotificationCenter.default.post(name: .mailDataChanged, object: folderID)
            report(nil)
            if folder.role == .inbox, !newHeaders.isEmpty {
                onNewMail?(self, newHeaders.filter { !$0.flags.contains(.seen) })
            }
            prefetchLimit = isInitial ? 60 : 25
          }
        } catch {
            report(error)
        }
        if prefetch, prefetchLimit > 0 { await prefetchBodies(folderID: folderID, limit: prefetchLimit) }
        // Parsing a big FETCH leaves freed pages behind; hand them back.
        if syncingFolders <= 1 { Memory.relieve() }
    }

    /// Caches the text of the newest messages so they open instantly and show a preview line.
    private func prefetchBodies(folderID: Int64, limit: Int) async {
        let ids = store.messagesNeedingBody(folderID: folderID, limit: limit)
        guard !ids.isEmpty else { return }
        let t0 = Date()
        await prefetch(ids: ids)
        Debug.log("prefetched \(ids.count) bodies: \(Debug.ms(since: t0))")
        NotificationCenter.default.post(name: .mailDataChanged, object: folderID)
    }

    /// Caches message text for several messages at once: messages that share the same text part numbers
    /// (most do: "1", or "1" + "2") are fetched together, 10 per round trip instead of one each.
    /// Each batch is a separate turn on the fetch connection, so a click waits for at most one batch.
    func prefetch(ids: [Int64]) async {
        guard !isDemo else { return }
        struct Item { let id: Int64; let uid: UInt32; let html: BodyPart?; let text: BodyPart? }
        var groups: [String: (folder: Folder, items: [Item])] = [:]
        for id in ids where !store.hasBody(id) {
            guard let d = store.detail(id), let f = store.folder(d.folderID), let st = d.structure else { continue }
            let (h, t) = st.displayParts()
            guard h != nil || t != nil, (h?.size ?? 0) + (t?.size ?? 0) < 400_000 else { continue }
            let key = "\(f.id)|\(h?.partID ?? "-")|\(t?.partID ?? "-")"
            if groups[key] == nil { groups[key] = (f, []) }
            groups[key]!.items.append(Item(id: id, uid: d.uid, html: h, text: t))
        }
        for (_, group) in groups {
            for chunk in group.items.chunked(10) {
                if Task.isCancelled { return }
                let partIDs = [chunk[0].html?.partID, chunk[0].text?.partID].compactMap { $0 }
                let raw = try? await prefetchGate.run { () async throws -> [UInt32: [String: Data]] in
                    let c = try await client(.prefetch)
                    try await c.ensureSelected(group.folder.path, readOnly: true)
                    return try await c.fetchRawParts(uids: chunk.map { $0.uid }, partIDs: partIDs)
                }
                guard let raw else { continue }
                for item in chunk where !store.hasBody(item.id) {
                    guard let parts = raw[item.uid] else { continue }
                    var html: String?
                    var text: String?
                    if let h = item.html, let r = parts[h.partID] {
                        html = MIME.string(from: MIME.decode(r, encoding: h.encoding), charset: h.charset)
                    }
                    if let t = item.text, let r = parts[t.partID] {
                        text = MIME.string(from: MIME.decode(r, encoding: t.encoding), charset: t.charset)
                    }
                    store.saveBody(item.id, html: html, text: text ?? (html == nil ? "" : nil))
                }
            }
        }
    }

    /// Fetches the next 200 older messages for a folder ("Load older messages").
    func loadOlder(folderID: Int64) async -> Int {
        guard !isDemo, let folder = store.folder(folderID), let minUID = store.minUID(folderID: folderID) else { return 0 }
        do {
            let headers = try await fetchGate.run { () async throws -> [ParsedHeader] in
                let c = try await client(.fetch)
                try await c.ensureSelected(folder.path, readOnly: true)
                let probe = try await c.fetch("\(minUID)", items: "(UID)")
                guard let seq = probe.first?.seq, seq > 1 else { return [] }
                let from = max(1, Int(seq) - 200)
                return try await c.fetchHeaders("\(from):\(seq - 1)", uid: false)
            }
            store.insert(folderID: folderID, headers)
            NotificationCenter.default.post(name: .mailDataChanged, object: folderID)
            return headers.count
        } catch {
            report(error)
            return 0
        }
    }

    // MARK: Push (IDLE)

    func startIdle() {
        guard idleTask == nil, !isDemo else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let inbox = self.store.folder(account: self.account.id, role: .inbox) else {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continue
                }
                do {
                    let c = try await self.client(.idle)
                    if await c.hasIdle {
                        try await c.ensureSelected(inbox.path, readOnly: true)
                        // Gmail drops idle connections after ~29 minutes; re-issue every 24.
                        if try await c.idle(maxSeconds: 24 * 60) { await self.sync(folderID: inbox.id) }
                    } else {
                        try await Task.sleep(nanoseconds: 120_000_000_000)
                        await self.sync(folderID: inbox.id)
                    }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
        }
    }

    // MARK: Bodies and parts

    func loadBody(messageID: Int64) async throws -> StoredBody {
        if let b = store.body(messageID) { return b }
        if isDemo { return StoredBody(html: nil, text: "") }
        guard let d = store.detail(messageID), let folder = store.folder(d.folderID) else {
            throw NetError.server("This message is no longer in the cache.")
        }
        var html: String?
        var text: String?
        let (h, t) = d.structure?.displayParts() ?? (nil, nil)
        let data = try await fetchGate.run { () async throws -> [String: Data] in
            let c = try await client(.fetch)
            try await c.ensureSelected(folder.path, readOnly: true)
            if d.structure != nil {
                return try await c.fetchParts(uid: d.uid, parts: [h, t].compactMap { $0 })
            }
            let r = try await c.fetch("\(d.uid)", items: "(UID BODY.PEEK[TEXT])")
            return ["TEXT": r.first?.items["BODY[TEXT]"]?.data ?? Data()]
        }
        if let h, let raw = data[h.partID] { html = MIME.string(from: raw, charset: h.charset) }
        if let t, let raw = data[t.partID] { text = MIME.string(from: raw, charset: t.charset) }
        if let raw = data["TEXT"] { text = MIME.string(from: raw, charset: nil) }
        if html == nil && text == nil { text = "" }
        store.saveBody(messageID, html: html, text: text)
        return StoredBody(html: html, text: text)
    }

    /// Whole decoded part (inline images). Capped so a huge inline part can't balloon memory.
    func partData(messageID: Int64, partID: String) async throws -> Data? {
        guard let d = store.detail(messageID), let folder = store.folder(d.folderID),
              let part = d.structure?.part(withID: partID), part.decodedSize < 12_000_000 else { return nil }
        return try await fetchGate.run { () async throws -> Data? in
            let c = try await client(.fetch)
            try await c.ensureSelected(folder.path, readOnly: true)
            return try await c.fetchParts(uid: d.uid, parts: [part])[partID]
        }
    }

    func download(messageID: Int64, part: BodyPart, to url: URL) async throws {
        guard let d = store.detail(messageID), let folder = store.folder(d.folderID) else {
            throw NetError.server("This message is no longer in the cache.")
        }
        // Downloads get their own connection so a 25 MB attachment never blocks reading other mail.
        try await downloadGate.run {
            let c = try await client(.download)
            try await c.ensureSelected(folder.path, readOnly: true)
            try await c.downloadPart(uid: d.uid, part: part, to: url)
        }
    }

    // MARK: Search

    /// Server-side search across the whole mailbox (Gmail search syntax on Gmail). Returns cached message ids.
    func serverSearch(_ query: String) async throws -> [Int64] {
        guard !isDemo else { return [] }
        guard let scope = store.folder(account: account.id, role: .all) ?? store.folder(account: account.id, role: .inbox) else { return [] }
        let known = Set(store.localUIDs(folderID: scope.id))
        let (newest, headers) = try await fetchGate.run { () async throws -> ([UInt32], [ParsedHeader]) in
            let c = try await client(.fetch)
            try await c.ensureSelected(scope.path, readOnly: true)
            let uids: [UInt32]
            if await c.isGmail {
                uids = try await c.uidSearch(prefix: "X-GM-RAW", text: query)
            } else {
                uids = try await c.uidSearch(prefix: "TEXT", text: query)
            }
            let newest = Array(uids.sorted(by: >).prefix(150))
            let missing = newest.filter { !known.contains($0) }
            return (newest, missing.isEmpty ? [] : try await c.fetchHeaders(imapUIDSet(missing)))
        }
        store.insert(folderID: scope.id, headers)
        return store.ids(folderID: scope.id, uids: newest)
    }

    // MARK: Actions (optimistic locally, queued for the server)

    func queue(kind: String, rows: [MessageRow], arg: String = "") {
        let byFolder = Dictionary(grouping: rows, by: { $0.folderID })
        for (fid, list) in byFolder {
            guard let f = store.folder(fid) else { continue }
            store.addOp(account: account.id, kind: kind, folderPath: f.path, uids: list.map { $0.uid }, arg: arg)
        }
        Task { await flushOps() }
    }

    func flushOps() async {
        guard !isDemo, !flushing else { return }
        flushing = true
        defer { flushing = false }
        for op in store.ops(account: account.id) {
            do {
                try await syncGate.run {
                    let c = try await client(.sync)
                    try await c.ensureSelected(op.folderPath, readOnly: false)
                    switch op.kind {
                    case "flag+": try await c.store(op.uids, "+FLAGS.SILENT (\(op.arg))")
                    case "flag-": try await c.store(op.uids, "-FLAGS.SILENT (\(op.arg))")
                    case "move": try await c.move(op.uids, to: op.arg)
                    case "expunge": try await c.expungeUIDs(op.uids)
                    default: break
                    }
                }
                store.removeOp(op.id)
            } catch let e as NetError {
                if case .server = e {
                    store.removeOp(op.id) // The server refused it (message gone, folder missing); don't retry forever.
                    report(e)
                    continue
                }
                report(e)
                return
            } catch {
                report(error)
                return
            }
        }
    }

    /// Saves a draft to the server's Drafts folder.
    func saveDraft(_ data: Data) async throws {
        guard let drafts = store.folder(account: account.id, role: .drafts) else {
            throw NetError.server("This account has no Drafts folder.")
        }
        try await syncGate.run {
            let c = try await client(.sync)
            try await c.append(drafts.path, flags: "\\Draft \\Seen", message: data)
        }
        await sync(folderID: drafts.id)
    }

    /// Sends through SMTP. Gmail files a copy in Sent itself; other servers get an APPEND.
    func send(_ message: OutgoingMessage) async throws {
        let password = try await appPassword()
        let data = try MessageBuilder.build(message)
        try await SMTPClient.send(host: account.smtpHost, port: account.smtpPort, username: account.username,
                                  password: password, from: account.email, recipients: message.allRecipients, message: data)
        if !isGmail, let sent = store.folder(account: account.id, role: .sent) {
            try? await syncGate.run {
                let c = try await client(.sync)
                try await c.append(sent.path, flags: "\\Seen", message: data)
            }
        }
        if let sent = store.folder(account: account.id, role: .sent) { Task { await sync(folderID: sent.id) } }
    }
}

/// A FIFO async lock for the main actor: callers queue up and run one at a time.
@MainActor
final class AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
