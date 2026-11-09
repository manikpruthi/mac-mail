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
    private var syncPending: Set<Int64> = []
    /// One gate per connection: "select folder, then act" must run as a unit on that connection.
    private let syncGate = AsyncGate()
    private let fetchGate = AsyncGate()
    private let downloadGate = AsyncGate()
    private let prefetchGate = AsyncGate()
    private let searchGate = AsyncGate()
    private var searchTask: Task<[Int64], Error>?
    private var idleTask: Task<Void, Never>?
    private var startupTasks: [Task<Void, Never>] = []
    private var flushing = false
    private var flushPending = false
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
        // Publish the connecting task before anything can suspend, so a second caller shares this
        // connection instead of opening a second one.
        let a = account
        let t0 = Date()
        let task = Task<IMAPClient, Error> {
            let password = try await appPassword()
            let c = IMAPClient(host: a.imapHost, port: a.imapPort, username: a.username, password: password)
            try await c.connect()
            return c
        }
        connecting[lane] = task
        do {
            let c = try await task.value
            Debug.log("\(lane) connection ready: \(Debug.ms(since: t0))")
            clients[lane] = c
            isGmail = await c.isGmail
            // Only now is it safe to clear: anyone who arrived while we were waiting already holds the task.
            connecting[lane] = nil
            return c
        } catch {
            connecting[lane] = nil
            throw error
        }
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
        for t in startupTasks { t.cancel() }
        startupTasks.removeAll()
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
        startupTasks.append(Task { await prewarmFetch() })
        startupTasks.append(Task {
            if store.folder(account: account.id, role: .inbox) == nil {
                await refreshFolders()
            }
            if Task.isCancelled { return }
            if let inbox = store.folder(account: account.id, role: .inbox) {
                await sync(folderID: inbox.id, prefetch: false)
                if Task.isCancelled { return }
                startupTasks.append(Task { await prefetchBodies(folderID: inbox.id, limit: 60) })
            }
            await flushOps()
            if Task.isCancelled { return }
            // Refresh the folder list after the Inbox is on screen; it changes rarely.
            await refreshFolders()
            startIdle()
        })
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

    /// Every fetch lane checks that the folder's UIDVALIDITY still matches what's cached: after a
    /// mismatch (folder recreated on the server) the cache is reset and the request fails loudly,
    /// instead of UIDs silently resolving to different messages.
    private func verifySelection(_ info: SelectInfo, folder: Folder) throws {
        guard folder.uidValidity != 0, info.uidValidity != 0, info.uidValidity != folder.uidValidity else { return }
        store.resetFolder(folder.id)
        throw NetError.server("\"\(folder.name)\" changed on the server and was reloaded. Try again.")
    }

    /// Delta sync of one folder: new mail since the last UIDNEXT, flag changes since the last MODSEQ, and removals.
    func sync(folderID: Int64, prefetch: Bool = true) async {
        guard !isDemo, let folder = store.folder(folderID), folder.selectable else { return }
        // A request for a folder already syncing is coalesced, not dropped: it re-runs right after.
        guard !syncing.contains(folderID) else { syncPending.insert(folderID); return }
        syncing.insert(folderID)
        beginSync()
        defer {
            syncing.remove(folderID); endSync()
            if syncPending.remove(folderID) != nil { Task { await self.sync(folderID: folderID, prefetch: prefetch) } }
        }
        var prefetchLimit = 0
        do {
          try await syncGate.run {
            let c = try await client(.sync)
            guard let info = try await c.select(folder.path, readOnly: false) else { return }
            var state = folder
            if state.uidValidity != 0 && info.uidValidity != 0 && state.uidValidity != info.uidValidity {
                store.resetFolder(folderID)
                state.uidNext = 0
                state.modseq = 0
            }
            var newHeaders: [ParsedHeader] = []
            let isInitial = state.uidNext == 0 || store.messageCount(folderID: folderID) == 0
            // The folder state advances right after headers land, so a later failure can't cause
            // the same range to be re-fetched (and new mail re-notified) on every sync.
            let finalUIDNext = info.uidNext > 0 ? info.uidNext : (store.maxUID(folderID: folderID) ?? 0) + 1

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
                store.updateFolderState(folderID, uidValidity: info.uidValidity, uidNext: finalUIDNext, modseq: info.highestModseq)
            } else {
                let next = state.uidNext > 0 ? state.uidNext : (store.maxUID(folderID: folderID).map { $0 + 1 } ?? 1)
                if info.uidNext == 0 || info.uidNext > next {
                    let headers = try await c.fetchHeaders("\(next):*").filter { $0.uid >= next }
                    store.insert(folderID: folderID, headers)
                    newHeaders = headers
                    store.updateFolderState(folderID, uidValidity: info.uidValidity, uidNext: finalUIDNext, modseq: state.modseq)
                }
                // Don't let server flag writes clobber what the user just changed: UIDs with a queued
                // flag op keep their local (and soon server) state.
                let pendingFlagUIDs = Set(store.ops(account: account.id)
                    .filter { ($0.kind == "flag+" || $0.kind == "flag-") && $0.folderPath == folder.path }
                    .flatMap { $0.uids })
                var flagsOK = true
                if let minUID = store.minUID(folderID: folderID) {
                    // Flag changes.
                    do {
                        if await c.hasCondstore, state.modseq > 0 {
                            if info.highestModseq != state.modseq {
                                let changed = try await c.fetch("1:*", items: "(UID FLAGS)", changedSince: state.modseq)
                                store.updateFlags(folderID: folderID, changed.compactMap { r in
                                    guard let uid = r.uid, !pendingFlagUIDs.contains(uid) else { return nil }
                                    return (uid, MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? []))
                                })
                            }
                        } else {
                            let all = try await c.fetch("\(minUID):*", items: "(UID FLAGS)")
                            store.updateFlags(folderID: folderID, all.compactMap { r in
                                guard let uid = r.uid, !pendingFlagUIDs.contains(uid) else { return nil }
                                return (uid, MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? []))
                            })
                        }
                    } catch { flagsOK = false; report(error) }
                    // Removals (moved, archived or deleted elsewhere) run even if the flag stage failed.
                    do {
                        let present = Set(try await c.uidSearch("UID \(minUID):*"))
                        let gone = store.localUIDs(folderID: folderID).filter { !present.contains($0) }
                        store.deleteMessages(folderID: folderID, uids: gone)
                    } catch { report(error) }
                }
                // MODSEQ only advances when the flag stage succeeded, so missed flag changes re-fetch.
                store.updateFolderState(folderID, uidValidity: info.uidValidity, uidNext: finalUIDNext,
                                        modseq: flagsOK ? info.highestModseq : state.modseq)
            }
            NotificationCenter.default.post(name: .mailDataChanged, object: folderID)
            report(nil)
            if folder.role == .inbox, !newHeaders.isEmpty {
                onNewMail?(self, newHeaders.filter { !$0.flags.contains(.seen) })
            }
            prefetchLimit = isInitial ? 60 : 25
          }
        } catch {
            report(error)
            return
        }
        if prefetch, prefetchLimit > 0 { await prefetchBodies(folderID: folderID, limit: prefetchLimit) }
        // Offline actions queued while we were away go out right after a successful sync.
        await flushOps()
        MailService.shared.updateBadge()
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
                    try self.verifySelection(try await c.ensureSelected(group.folder.path, readOnly: true), folder: group.folder)
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
                    // Nothing came back for this message: leave it uncached so opening it fetches again,
                    // instead of caching an empty body forever.
                    guard html != nil || text != nil else { continue }
                    store.saveBody(item.id, html: html, text: text)
                }
            }
        }
    }

    /// Fetches the next 200 older messages for a folder ("Load older messages"). Resolved by UID SEARCH
    /// below the oldest cached UID, so a remotely deleted boundary message doesn't read as "no older mail".
    func loadOlder(folderID: Int64) async -> Int {
        guard !isDemo, let folder = store.folder(folderID), let minUID = store.minUID(folderID: folderID) else { return 0 }
        do {
            let headers = try await fetchGate.run { () async throws -> [ParsedHeader] in
                let c = try await client(.fetch)
                try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
                let below = try await c.uidSearch("UID 1:\(max(0, Int(minUID) - 1))")
                let older = below.sorted().prefix(200)
                guard !older.isEmpty else { return [] }
                return try await c.fetchHeaders(imapUIDSet(older))
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
                        // Whether the server reported a change or the window timed out, catch up on disk first.
                        _ = try await c.idle(maxSeconds: 24 * 60)
                        await self.sync(folderID: inbox.id)
                    } else {
                        try await Task.sleep(nanoseconds: 120_000_000_000)
                        await self.sync(folderID: inbox.id)
                    }
                } catch {
                    if Task.isCancelled { return }
                    // The connection dropped: after reconnecting, sync before idling again so
                    // changes missed while offline aren't skipped.
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    await self.sync(folderID: inbox.id)
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
            try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
            if d.structure != nil {
                return try await c.fetchParts(uid: d.uid, parts: [h, t].compactMap { $0 })
            }
            let r = try await c.fetch("\(d.uid)", items: "(UID BODY.PEEK[TEXT])")
            return ["TEXT": r.first?.items["BODY[TEXT]"]?.data ?? Data()]
        }
        if let h, let raw = data[h.partID] { html = MIME.string(from: raw, charset: h.charset) }
        if let t, let raw = data[t.partID] { text = MIME.string(from: raw, charset: t.charset) }
        if let raw = data["TEXT"] { text = MIME.string(from: raw, charset: nil) }
        if html == nil && text == nil {
            // The server returned no text part (rare, usually a transient hiccup). Don't cache it; try again on next open.
            if (h == nil && t == nil) || d.size < 2_000 { return StoredBody(html: nil, text: "") }
            throw NetError.server("The message text didn't arrive from the server. Select the message again to retry.")
        }
        store.saveBody(messageID, html: html, text: text)
        return StoredBody(html: html, text: text)
    }

    /// Whole decoded part (inline images). Capped so a huge inline part can't balloon memory.
    func partData(messageID: Int64, partID: String) async throws -> Data? {
        guard !isDemo, let d = store.detail(messageID), let folder = store.folder(d.folderID),
              let part = d.structure?.part(withID: partID), part.decodedSize < 12_000_000 else { return nil }
        return try await fetchGate.run { () async throws -> Data? in
            let c = try await client(.fetch)
            try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
            return try await c.fetchParts(uid: d.uid, parts: [part])[partID]
        }
    }

    func download(messageID: Int64, part: BodyPart, to url: URL) async throws {
        guard !isDemo, let d = store.detail(messageID), let folder = store.folder(d.folderID) else {
            throw NetError.server("This message is no longer in the cache.")
        }
        // Downloads get their own connection so a 25 MB attachment never blocks reading other mail.
        try await downloadGate.run {
            let c = try await client(.download)
            try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
            try await c.downloadPart(uid: d.uid, part: part, to: url)
        }
    }

    // MARK: Search

    /// Server-side search (Gmail search syntax via X-GM-RAW on Gmail, IMAP SEARCH elsewhere) in one folder,
    /// or across the whole mailbox (All Mail). Fetches headers for hits that aren't cached and returns their ids.
    /// Runs on its own gate and cancels the previous search, so typing can't queue full searches
    /// ahead of a message you clicked.
    func serverSearch(_ query: SearchQuery, folder: Folder? = nil) async throws -> [Int64] {
        guard !isDemo, !query.isEmpty else { return [] }
        guard let scope = folder ?? store.folder(account: account.id, role: .all) ?? store.folder(account: account.id, role: .inbox) else { return [] }
        searchTask?.cancel()
        let known = Set(store.localUIDs(folderID: scope.id))
        let t0 = Date()
        let task = Task { [weak self] () async throws -> [Int64] in
            guard let self else { return [] }
            return try await self.searchGate.run { () async throws -> [Int64] in
                try Task.checkCancellation()
                let c = try await self.client(.fetch)
                try self.verifySelection(try await c.ensureSelected(scope.path, readOnly: true), folder: scope)
                let uids: [UInt32]
                if await c.isGmail {
                    uids = try await c.uidSearch(prefix: "X-GM-RAW", text: query.gmailRaw)
                } else {
                    uids = try await c.uidSearch(query.imapCriteria)
                }
                let newest = Array(uids.sorted(by: >).prefix(200))
                let missing = newest.filter { !known.contains($0) }
                try Task.checkCancellation()
                let headers = missing.isEmpty ? [] : try await c.fetchHeaders(imapUIDSet(missing))
                self.store.insert(folderID: scope.id, headers)
                Debug.log("server search '\(query.gmailRaw)' in \(scope.name): \(newest.count) hits, \(headers.count) new, \(Debug.ms(since: t0))")
                return self.store.ids(folderID: scope.id, uids: newest)
            }
        }
        searchTask = task
        return try await task.value
    }

    // MARK: Actions (optimistic locally, queued for the server)

    func queue(kind: String, rows: [MessageRow], arg: String = "") {
        let byFolder = Dictionary(grouping: rows, by: { $0.folderID })
        for (fid, list) in byFolder {
            guard let f = store.folder(fid) else { continue }
            store.addOp(account: account.id, kind: kind, folderPath: f.path, uids: list.map { $0.uid }, arg: arg,
                        folderID: f.id, uidvalidity: f.uidValidity)
        }
        Task { await flushOps() }
    }

    /// Classified server refusals: LIMIT/INUSE/rate-limit style NOs are worth retrying;
    /// anything else (message gone, folder missing, no permission) is final.
    private static func isTemporaryRefusal(_ message: String) -> Bool {
        let m = message.uppercased()
        return ["LIMIT", "INUSE", "UNAVAILABLE", "SERVERBUG", "CONTACTSYSADMIN", "OVERQUOTA",
                "RATE", "THROTTLE", "TEMPORAR", "TRYAGAIN"].contains { m.contains($0) }
    }

    /// Applies queued actions to the server. Loops over fresh snapshots until the queue is empty, so
    /// actions queued mid-flush are picked up instead of lost. Temporary refusals retry with backoff;
    /// a final refusal of a move/delete re-fetches the source headers so the messages reappear locally.
    func flushOps() async {
        guard !isDemo else { return }
        guard !flushing else { flushPending = true; return }
        flushing = true
        defer { flushing = false }
        var attempts: [Int64: Int] = [:]
        while true {
            flushPending = false
            guard let op = store.ops(account: account.id).first else {
                if flushPending { continue } else { break }
            }
            guard let f = store.folder(account: account.id, path: op.folderPath), f.selectable else {
                store.removeOp(op.id) // Folder is gone; its ops were already reset with it.
                continue
            }
            if op.uidvalidity != 0, f.uidValidity != 0, op.uidvalidity != f.uidValidity {
                store.removeOp(op.id) // Stale UIDs would land on the wrong messages.
                continue
            }
            do {
                try await syncGate.run {
                    let c = try await client(.sync)
                    try self.verifySelection(try await c.ensureSelected(op.folderPath, readOnly: false), folder: f)
                    switch op.kind {
                    case "flag+": try await c.store(op.uids, "+FLAGS.SILENT (\(op.arg))")
                    case "flag-": try await c.store(op.uids, "-FLAGS.SILENT (\(op.arg))")
                    case "move": try await c.move(op.uids, to: op.arg)
                    case "expunge": try await c.expungeUIDs(op.uids)
                    default: break
                    }
                }
                store.removeOp(op.id)
                attempts[op.id] = nil
            } catch let e as NetError {
                if case .server(let m) = e, !Self.isTemporaryRefusal(m) {
                    // The server refused it for good; don't retry forever.
                    store.removeOp(op.id)
                    report(e)
                    if op.kind == "move" || op.kind == "expunge" { await refetchHeaders(folder: f, uids: op.uids) }
                    continue
                }
                report(e)
                let n = (attempts[op.id] ?? 0) + 1
                if n >= 3 {
                    // Temporary refusal that won't clear: give up and undo the optimistic local delete.
                    store.removeOp(op.id)
                    if op.kind == "move" || op.kind == "expunge" { await refetchHeaders(folder: f, uids: op.uids) }
                } else {
                    attempts[op.id] = n
                    try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 << (n - 1)))
                }
            } catch {
                report(error)
                return // Connection is gone; the next flush trigger retries.
            }
        }
    }

    /// A move/delete was refused after the local rows were already removed: re-fetch the headers so the
    /// messages reappear instead of vanishing until the next full resync.
    private func refetchHeaders(folder: Folder, uids: [UInt32]) async {
        guard !uids.isEmpty else { return }
        do {
            let headers = try await syncGate.run { () async throws -> [ParsedHeader] in
                let c = try await client(.sync)
                try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
                return try await c.fetchHeaders(imapUIDSet(uids))
            }
            store.insert(folderID: folder.id, headers)
            NotificationCenter.default.post(name: .mailDataChanged, object: folder.id)
        } catch {
            report(error)
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
            do {
                try await syncGate.run {
                    let c = try await client(.sync)
                    try await c.append(sent.path, flags: "\\Seen", message: data)
                }
            } catch {
                // The message went out; failing to file the copy must not read as a failed send.
                report(NetError.server("The message was sent, but filing it in \"\(sent.name)\" failed: "
                                       + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)))
            }
        }
        // Gmail (and other servers) need a moment to file the sent copy before the Sent sync runs.
        if let sent = store.folder(account: account.id, role: .sent) {
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await self.sync(folderID: sent.id) }
        }
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
