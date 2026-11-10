import Foundation

/// Sync and server actions for one account. Uses five IMAP connections (lanes) so a long sync never blocks
/// opening a message: `sync` (delta sync + queued actions), `fetch` (bodies, inline images, search),
/// `prefetch` (background body caching), `idle` (Inbox push) and `download` (attachment saves).
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
    private var syncWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    /// One gate per connection: "select folder, then act" must run as a unit on that connection.
    private let syncGate = AsyncGate()
    private let fetchGate = AsyncGate()
    private let downloadGate = AsyncGate()
    private let prefetchGate = AsyncGate()
    private var searchTask: Task<[Int64], Error>?
    private var idleTask: Task<Void, Never>?
    private var startupTasks: [Task<Void, Never>] = []
    private var flushing = false
    private(set) var isGmail: Bool
    private(set) var lastError: String?
    /// Classification of `lastError` (credentials vs network vs server refusal); the string stays as the human form.
    private(set) var lastErrorKind: MailErrorKind?
    private(set) var syncingFolders = 0
    /// New unread Inbox mail: the engine, the folder it landed in and the headers.
    var onNewMail: ((AccountEngine, Int64, [ParsedHeader]) -> Void)?

    /// Creates the IMAP client for a lane; injectable so tests can substitute a fake.
    typealias ClientFactory = @Sendable (_ host: String, _ port: UInt16, _ username: String, _ password: String,
                                         _ security: ConnectionSecurity) -> IMAPClient
    /// Resolves the account password; injectable so tests can bypass the Keychain.
    typealias PasswordProvider = @Sendable (_ accountID: String) async throws -> String?

    private let clientFactory: ClientFactory
    private let passwordProvider: PasswordProvider

    init(account: Account, store: Store,
         clientFactory: @escaping ClientFactory = { IMAPClient(host: $0, port: $1, username: $2, password: $3, security: $4) },
         passwordProvider: @escaping PasswordProvider = { Keychain.get($0) }) {
        self.account = account
        self.store = store
        self.clientFactory = clientFactory
        self.passwordProvider = passwordProvider
        self.isGmail = account.provider == .gmail
    }

    var isDemo: Bool { account.provider == .demo }

    /// Applies an edited account. A changed server, port, login or security mode drops every live
    /// connection and the cached password, so the next command reconnects with the new settings (B-11).
    func update(account new: Account) {
        let reconnect = new.connectionDiffers(from: account)
        account = new
        if reconnect { resetConnections() }
    }

    /// Drops the cached password and all connections (after "Sign in again" saved a new password — F-04).
    func resetConnections() {
        guard !stopped else { return }
        cachedPassword = nil
        passwordTask = nil
        idleTask?.cancel()
        idleTask = nil
        connectionEpoch += 1
        for t in connecting.values { t.cancel() }
        connecting.removeAll()
        let all = clients.values
        clients.removeAll()
        for c in all { Task { await c.disconnect() } }
        lastError = nil
        lastErrorKind = nil
        NotificationCenter.default.post(name: .mailStatusChanged, object: self)
        guard !isDemo else { return }
        startupTasks.append(Task {
            await refreshFolders()
            if Task.isCancelled { return }
            if let inbox = store.folder(account: account.id, role: .inbox) { await sync(folderID: inbox.id) }
            startIdle()
        })
    }

    /// Set by shutdown() (quit, or the account was removed). Background tasks that were already
    /// running check it, so none of them can reconnect, write this account's folders back into the
    /// cache or restart IDLE afterwards.
    private var stopped = false

    // MARK: Connections

    /// Bumped whenever the connections are dropped (reset or shutdown). client() re-checks it after every
    /// suspension, so no caller can be handed a connection opened with the old settings.
    private var connectionEpoch = 0

    func client(_ lane: Lane) async throws -> IMAPClient {
        guard !stopped else { throw CancellationError() }
        let epoch = connectionEpoch
        if let c = clients[lane] {
            let alive = await c.isConnected
            guard epoch == connectionEpoch else { throw CancellationError() }
            if alive { return c }
            // The old connection died (sleep/wake, server restart): close it before opening a new one,
            // instead of leaving its socket to the garbage collector.
            if clients[lane] === c { clients[lane] = nil }
            Task { await c.disconnect() }
        }
        if let pending = connecting[lane] {
            // A caller that joined an in-flight connect is checked too; the creator closes the connection.
            let c = try await pending.value
            guard epoch == connectionEpoch else { throw CancellationError() }
            return c
        }
        // Publish the connecting task before anything can suspend, so a second caller shares this
        // connection instead of opening a second one.
        let a = account
        let makeClient = clientFactory
        let t0 = Date()
        let task = Task<IMAPClient, Error> {
            let password = try await appPassword()
            let c = makeClient(a.imapHost, a.imapPort, a.username, password, a.imapSecurity)
            try await c.connect()
            return c
        }
        connecting[lane] = task
        do {
            let c = try await task.value
            // The engine was shut down or its connections were reset while this one was opening: it
            // belongs to the old settings, so close it instead of keeping it.
            guard epoch == connectionEpoch, connecting[lane] == task else {
                Task { await c.disconnect() }
                throw CancellationError()
            }
            Debug.log("\(lane) connection ready: \(Debug.ms(since: t0))")
            clients[lane] = c
            let gmail = await c.isGmail
            // A reset can land during that hop too; it already dropped `c` from `clients`.
            guard epoch == connectionEpoch else {
                Task { await c.disconnect() }
                throw CancellationError()
            }
            isGmail = gmail
            // Only now is it safe to clear: anyone who arrived while we were waiting already holds the task.
            connecting[lane] = nil
            return c
        } catch {
            if connecting[lane] == task { connecting[lane] = nil }
            throw error
        }
    }

    private var cachedPassword: String?
    private var passwordTask: Task<String?, Error>?

    /// Reads the App Password once, off the main thread: a Keychain read can block for seconds
    /// (macOS verifies the app before releasing the item), which would freeze the window.
    func appPassword() async throws -> String {
        if let p = cachedPassword { return p }
        let epoch = connectionEpoch
        let provide = passwordProvider
        let task = passwordTask ?? {
            let id = account.id
            let t = Task.detached(priority: .userInitiated) { () -> String? in
                let t0 = Date()
                let p = try await provide(id)
                Debug.log("keychain read: \(Debug.ms(since: t0))")
                return p
            }
            passwordTask = t
            return t
        }()
        do {
            guard let p = try await task.value else {
                passwordTask = nil
                throw NetError.auth("no App Password saved for \(account.email). Open Settings → Accounts.")
            }
            // A read that was in flight across a reset may hold the password from before it: read again
            // instead of caching it.
            guard epoch == connectionEpoch else {
                if passwordTask == task { passwordTask = nil }
                return try await appPassword()
            }
            cachedPassword = p
            return p
        } catch {
            // Never cache a failed read: a transient Keychain error must be retryable, not permanent.
            if passwordTask == task { passwordTask = nil }
            throw error
        }
    }

    func shutdown() {
        stopped = true
        for t in startupTasks { t.cancel() }
        startupTasks.removeAll()
        idleTask?.cancel()
        idleTask = nil
        searchTask?.cancel()
        searchTask = nil
        connectionEpoch += 1
        for t in connecting.values { t.cancel() }
        connecting.removeAll()
        let all = clients.values
        clients.removeAll()
        for c in all { Task { await c.disconnect() } }
    }

    private func report(_ error: Error?) {
        // A cancelled task (engine shut down, search superseded) is not a failure worth showing the user.
        if error is CancellationError { return }
        let message = error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
        lastErrorKind = Self.classify(error)
        if message != lastError {
            if let message { DiagnosticsLog.record("\(account.email): \(message)") }
            lastError = message
            NotificationCenter.default.post(name: .mailStatusChanged, object: self)
        }
    }

    /// Why an operation failed, so callers can tell a credentials problem from a network blip
    /// or a retryable server refusal without parsing the message text.
    private static func classify(_ error: Error?) -> MailErrorKind? {
        guard let error else { return nil }
        switch error as? NetError {
        case .auth: return .auth
        case .closed, .timeout, .protocolError: return .network
        case .server(let m): return isTemporaryRefusal(m) ? .temporary : .permanent
        case nil: return .network
        }
    }

    // MARK: Start-up

    func start() {
        guard !isDemo, !stopped else { return }
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
            let (listed, counts, gmail) = try await syncGate.run { () async throws -> ([ListedFolder], [String: Int], Bool) in
                let c = try await client(.sync)
                let (list, counts) = try await c.listWithStatus()
                return (list, counts, await c.isGmail)
            }
            guard store.upsertFolders(account: account.id, listed, isGmail: gmail) else {
                report(NetError.server("The folder list couldn't be saved to the mail cache."))
                return
            }
            NotificationCenter.default.post(name: .mailFoldersChanged, object: self)
            report(nil)
            if !counts.isEmpty {
                // LIST-STATUS answered every folder's count in the same round trip (O-07).
                for f in store.folders(account: account.id) { if let n = counts[f.path] { store.setServerUnread(folderID: f.id, n) } }
                lastUnreadRefresh = Date()
                NotificationCenter.default.post(name: .mailCountsChanged, object: self)
            } else {
                await refreshServerUnread()
            }
        } catch {
            report(error)
        }
    }

    private var lastUnreadRefresh: Date?

    /// STATUS (UNSEEN) for every selectable folder, after the folder list refreshes. Runs on the sync
    /// connection, never on the click path, and at most every 5 minutes (O-07): per-folder syncs keep
    /// their own count current in between.
    private func refreshServerUnread() async {
        if let last = lastUnreadRefresh, Date().timeIntervalSince(last) < 300 { return }
        let folders = store.folders(account: account.id).filter { $0.selectable }
        guard !folders.isEmpty else { return }
        lastUnreadRefresh = Date()
        _ = try? await syncGate.run {
            let c = try await client(.sync)
            for f in folders {
                if Task.isCancelled { return }
                if let n = try? await c.unseenCount(f.path) { store.setServerUnread(folderID: f.id, n) }
            }
        }
        NotificationCenter.default.post(name: .mailCountsChanged, object: self)
    }

    /// Syncs since the last full flag sweep, per folder, for servers without CONDSTORE (O-11).
    private var flagSweepCounter: [Int64: Int] = [:]

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
        resetFolderCache(folder.id)
        throw NetError.server("\"\(folder.name)\" changed on the server and was reloaded. Try again.")
    }

    /// Drops a folder's cached rows and queued actions after its UIDVALIDITY changed. The UIDs hidden for
    /// an Undo window belong to the old numbering too: kept, they would hide whichever new messages
    /// happen to carry the same numbers.
    private func resetFolderCache(_ folderID: Int64) {
        store.resetFolder(folderID)
        undoHidden[folderID] = nil
    }

    /// Delta sync of one folder: new mail since the last UIDNEXT, flag changes since the last MODSEQ, and removals.
    func sync(folderID: Int64, prefetch: Bool = true) async {
        guard !isDemo, !stopped, let folder = store.folder(folderID), folder.selectable else { return }
        // A request for a folder already syncing is coalesced, not dropped: it re-runs right after.
        guard !syncing.contains(folderID) else { syncPending.insert(folderID); return }
        syncing.insert(folderID)
        beginSync()
        defer {
            syncing.remove(folderID); endSync()
            for c in syncWaiters.removeValue(forKey: folderID) ?? [] { c.resume() }
            if syncPending.remove(folderID) != nil { Task { await self.sync(folderID: folderID, prefetch: prefetch) } }
        }
        var prefetchLimit = 0
        do {
          try await syncGate.run {
            let c = try await client(.sync)
            guard let info = try await c.select(folder.path, readOnly: false) else { return }
            var state = folder
            if state.uidValidity != 0 && info.uidValidity != 0 && state.uidValidity != info.uidValidity {
                resetFolderCache(folderID)
                state.uidNext = 0
                state.modseq = 0
            }
            var newHeaders: [ParsedHeader] = []
            // What this sync actually changed: lists redraw only for real changes (no-op syncs used to
            // rebuild the visible rows every time, which showed as stutter).
            var rowsChanged = false
            var flagChangedUIDs: [UInt32] = []
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
                // Read after the searches: something removed while they were in flight is skipped too.
                uids.subtract(locallyRemovedUIDs(folderID: folderID, folder: folder))
                // Newest first, so the top of the list fills in within the first round trip.
                for chunk in uids.sorted(by: >).chunked(200) {
                    let headers = try await c.fetchHeaders(imapUIDSet(chunk))
                    // A write that fails throws out of here: UIDNEXT must not move past the missing rows (C-10).
                    try store.insertChecked(folderID: folderID, headers)
                    NotificationCenter.default.postMailDataChanged(.folder(folderID))
                }
                try store.updateFolderStateChecked(folderID, uidValidity: info.uidValidity,
                                                   uidNext: info.uidNext > 0 ? info.uidNext : (store.maxUID(folderID: folderID) ?? 0) + 1,
                                                   modseq: info.highestModseq)
                rowsChanged = true
            } else {
                let next = state.uidNext > 0 ? state.uidNext : (store.maxUID(folderID: folderID).map { $0 + 1 } ?? 1)
                if info.uidNext == 0 || info.uidNext > next {
                    let headers = try await c.fetchHeaders("\(next):*").filter { $0.uid >= next }
                    try store.insertChecked(folderID: folderID, headers)
                    newHeaders = headers
                    if !headers.isEmpty { rowsChanged = true }
                    // A server that omits UIDNEXT gets the highest cached UID *after* these headers landed.
                    try store.updateFolderStateChecked(folderID, uidValidity: info.uidValidity,
                                                       uidNext: info.uidNext > 0 ? info.uidNext : (store.maxUID(folderID: folderID) ?? 0) + 1,
                                                       modseq: state.modseq)
                }
                var flagsOK = true
                if store.minUID(folderID: folderID) != nil {
                    // Flag changes.
                    do {
                        if await c.hasCondstore, state.modseq > 0 {
                            if info.highestModseq != state.modseq {
                                let changed = try await c.fetch("1:*", items: "(UID FLAGS)", changedSince: state.modseq)
                                let pending = pendingFlagUIDs(folderID: folderID, folder: folder)
                                flagChangedUIDs += try store.updateFlagsChecked(folderID: folderID, changed.compactMap { r in
                                    guard let uid = r.uid, !pending.contains(uid) else { return nil }
                                    return (uid, MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? []))
                                })
                            }
                        } else {
                            // Without CONDSTORE every flag must be fetched to see changes. Most syncs only
                            // look at the newest 500 cached UIDs; every 10th sweeps the whole cached range (O-11).
                            let n = (flagSweepCounter[folderID] ?? 0) + 1
                            flagSweepCounter[folderID] = n % 10
                            // Only the cached UIDs are asked about, 1,000 per command like the removals
                            // check below: `from:*` on a big folder answered with more untagged lines
                            // than a reply may hold, which dropped the connection on every sweep.
                            var wanted = store.localUIDs(folderID: folderID).sorted(by: >)
                            if n % 10 != 1 { wanted = Array(wanted.prefix(500)) }
                            var all: [FetchResult] = []
                            for chunk in wanted.sorted().chunked(1000) {
                                all += try await c.fetch(imapUIDSet(chunk), items: "(UID FLAGS)")
                            }
                            let pending = pendingFlagUIDs(folderID: folderID, folder: folder)
                            flagChangedUIDs += try store.updateFlagsChecked(folderID: folderID, all.compactMap { r in
                                guard let uid = r.uid, !pending.contains(uid) else { return nil }
                                return (uid, MessageFlags.from(imapFlags: r.items["FLAGS"]?.list?.compactMap { $0.text } ?? []))
                            })
                        }
                    } catch { flagsOK = false; report(error) }
                    // Removals (moved, archived or deleted elsewhere) run even if the flag stage failed.
                    // Only the cached UIDs are asked about, 1,000 per command, so the reply is bounded by
                    // the cache, not the mailbox: `UID min:*` on a big Inbox returned one >1 MB line, which
                    // dropped the connection on every sync and left queued actions stuck.
                    var gone: [UInt32] = []
                    do {
                        let local = store.localUIDs(folderID: folderID).sorted()
                        var present = Set<UInt32>()
                        for chunk in local.chunked(1000) {
                            present.formUnion(try await c.uidSearch("UID \(imapUIDSet(chunk))"))
                        }
                        gone = local.filter { !present.contains($0) }
                    } catch { report(error) }
                    if !gone.isEmpty {
                        // A failed cache delete stops the sync here: the folder state must not advance
                        // past rows that are still cached, and the failure is reported, not hidden.
                        guard store.deleteMessages(folderID: folderID, uids: gone) else {
                            throw NetError.server("Messages removed on the server couldn't be removed from the mail cache.")
                        }
                        rowsChanged = true
                    }
                }
                // MODSEQ only advances when the flag stage succeeded, so missed flag changes re-fetch.
                try store.updateFolderStateChecked(folderID, uidValidity: info.uidValidity,
                                                   uidNext: info.uidNext > 0 ? info.uidNext : (store.maxUID(folderID: folderID) ?? 0) + 1,
                                                   modseq: flagsOK ? info.highestModseq : state.modseq)
                // Server unread count (one small command on the sync connection), so the sidebar and badge
                // count mail older than the offline window too.
                if let unseen = try? await c.unseenCount(folder.path) {
                    store.setServerUnread(folderID: folderID, unseen)
                    NotificationCenter.default.post(name: .mailCountsChanged, object: self)
                }
            }
            if rowsChanged {
                NotificationCenter.default.postMailDataChanged(.folder(folderID))
            } else if !flagChangedUIDs.isEmpty {
                // Flag-only changes patch the affected rows in place.
                NotificationCenter.default.postMailDataChanged(.flags(ids: store.ids(folderID: folderID, uids: flagChangedUIDs)))
            }
            report(nil)
            if folder.role == .inbox, !newHeaders.isEmpty {
                onNewMail?(self, folderID, newHeaders.filter { !$0.flags.contains(.seen) })
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

    /// Don't let server flag writes clobber what the user just changed: UIDs with a queued flag op keep
    /// their local (and soon server) state. Ops queued by older builds carry no folder id, so fall back
    /// to the path they recorded. Call this after a FETCH returns, not before: a flag changed while the
    /// fetch was in flight must not be overwritten by the older server value.
    private func pendingFlagUIDs(folderID: Int64, folder: Folder) -> Set<UInt32> {
        Set(store.ops(account: account.id)
            .filter { op in
                guard PendingOpKind(op)?.isFlagChange == true else { return false }
                return op.folderID == folderID || (op.folderID == 0 && op.folderPath == folder.path)
            }
            .flatMap { $0.uids })
    }

    /// Messages removed locally whose server action is still inside its Undo window (not queued yet).
    private var undoHidden: [Int64: Set<UInt32>] = [:]

    /// Marks rows as removed locally but not yet queued for the server (the Undo window), or clears it.
    func setHidden(_ rows: [MessageRow], _ hidden: Bool) {
        for r in rows {
            if hidden { undoHidden[r.folderID, default: []].insert(r.uid) }
            else { undoHidden[r.folderID]?.remove(r.uid) }
        }
    }

    /// UIDs the user already moved or deleted here that the server still has: inside the Undo window,
    /// or queued and not sent yet. A header fetch must skip them, or the messages would reappear in the
    /// list until the next sync notices they are gone.
    private func locallyRemovedUIDs(folderID: Int64, folder: Folder) -> Set<UInt32> {
        var out = undoHidden[folderID] ?? []
        for op in store.ops(account: account.id) {
            guard let kind = PendingOpKind(op), kind.needsRefetchOnRefusal,
                  op.folderID == folderID || (op.folderID == 0 && op.folderPath == folder.path) else { continue }
            out.formUnion(op.uids)
        }
        return out
    }

    /// Waits until no sync is running for the folder, so a caller can then run one that is not coalesced.
    private func waitForSyncToFinish(folderID: Int64) async {
        while syncing.contains(folderID) {
            await withCheckedContinuation { syncWaiters[folderID, default: []].append($0) }
        }
    }

    /// Caches the text of the newest messages so they open instantly and show a preview line.
    private func prefetchBodies(folderID: Int64, limit: Int) async {
        let ids = store.messagesNeedingBody(folderID: folderID, limit: limit)
        guard !ids.isEmpty else { return }
        let t0 = Date()
        await prefetch(ids: ids)
        Debug.log("prefetched \(ids.count) bodies: \(Debug.ms(since: t0))")
        NotificationCenter.default.postMailDataChanged(.folder(folderID))
        // Prefetch runs after the sync's own relief; hand its freed pages back too.
        if syncingFolders == 0 { Memory.relieve() }
    }

    /// Caches message text for several messages at once: messages that share the same text part numbers
    /// (most do: "1", or "1" + "2") are fetched together, 10 per round trip instead of one each.
    /// Each batch is a separate turn on the fetch connection, so a click waits for at most one batch.
    func prefetch(ids: [Int64]) async {
        guard !isDemo else { return }
        struct Item: Sendable { let id: Int64; let uid: UInt32; let html: BodyPart?; let text: BodyPart? }
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
                // Transfer decoding, charset conversion, the snippet and the index text all run off the
                // main actor (O-03); only the SQLite writes come back to it.
                let decoded = await Task.detached(priority: .utility) { () -> [(Int64, String?, String?, String, String)] in
                    var out: [(Int64, String?, String?, String, String)] = []
                    for item in chunk {
                        guard let parts = raw[item.uid] else { continue }
                        autoreleasepool {
                            var html: String?
                            var text: String?
                            if let h = item.html, let r = parts[h.partID] {
                                html = MIME.string(from: MIME.decode(r, encoding: h.encoding), charset: h.charset)
                            }
                            if let t = item.text, let r = parts[t.partID] {
                                text = MIME.string(from: MIME.decode(r, encoding: t.encoding), charset: t.charset)
                            }
                            // Nothing came back: leave it uncached so opening it fetches again.
                            guard html != nil || text != nil else { return }
                            out.append((item.id, html, text, MIME.snippet(html: html, text: text),
                                        Store.indexText(html: html, text: text)))
                        }
                    }
                    return out
                }.value
                for (id, html, text, snippet, index) in decoded where !store.hasBody(id) {
                    store.saveBody(id, html: html, text: text, snippet: snippet, indexText: index)
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
                // Walk backwards from the oldest cached UID in growing windows (each reply stays well under
                // the line limit) and take the newest 200 below it. The old single `UID 1:min-1` search
                // returned the whole mailbox on one line and then kept its *oldest* 200 messages.
                var found: [UInt32] = []
                var hi = Int(minUID) - 1
                var window = 2_000
                while hi >= 1 && found.count < 200 {
                    let lo = max(1, hi - window + 1)
                    found += try await c.uidSearch("UID \(lo):\(hi)").filter { Int($0) <= hi }
                    hi = lo - 1
                    window = min(window * 2, 20_000)
                }
                let removed = self.locallyRemovedUIDs(folderID: folderID, folder: folder)
                let older = found.filter { !removed.contains($0) }.sorted(by: >).prefix(200)
                guard !older.isEmpty else { return [] }
                return try await c.fetchHeaders(imapUIDSet(older))
            }
            try store.insertChecked(folderID: folderID, headers)
            NotificationCenter.default.postMailDataChanged(.folder(folderID))
            return headers.count
        } catch {
            report(error)
            return 0
        }
    }

    // MARK: Push (IDLE)

    func startIdle() {
        guard idleTask == nil, !isDemo, !stopped else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let inbox = self.store.folder(account: self.account.id, role: .inbox) else {
                    // The startup folder list failed (e.g. launched before the network was up): retry it
                    // instead of waiting forever, then catch the Inbox up once it exists (S3).
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { return }
                    await self.refreshFolders()
                    if let inbox = self.store.folder(account: self.account.id, role: .inbox) {
                        await self.sync(folderID: inbox.id)
                    }
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
            // A reply without the item is "nothing arrived", not an empty body: returning empty data here
            // cached a blank message for good.
            guard let raw = r.first(where: { $0.uid == d.uid })?.items["BODY[TEXT]"]?.data else { return [:] }
            return ["TEXT": raw]
        }
        let hc = h?.charset, tc = t?.charset
        let hp = h?.partID, tp = t?.partID
        // Charset conversion, snippet and index text off the main actor (O-03).
        let (dh, dt, snippet, index) = await Task.detached(priority: .userInitiated) { () -> (String?, String?, String, String) in
            var html: String?
            var text: String?
            if let hp, let raw = data[hp] { html = MIME.string(from: raw, charset: hc) }
            if let tp, let raw = data[tp] { text = MIME.string(from: raw, charset: tc) }
            if let raw = data["TEXT"] { text = MIME.string(from: raw, charset: nil) }
            return (html, text, MIME.snippet(html: html, text: text), Store.indexText(html: html, text: text))
        }.value
        html = dh
        text = dt
        if html == nil && text == nil {
            // The server returned no text part (rare, usually a transient hiccup). Don't cache it; try again on next open.
            if (h == nil && t == nil) || d.size < 2_000 { return StoredBody(html: nil, text: "") }
            throw NetError.server("The message text didn't arrive from the server. Select the message again to retry.")
        }
        store.saveBody(messageID, html: html, text: text, snippet: snippet, indexText: index)
        return StoredBody(html: html, text: text)
    }

    /// The complete original message (RFC 822 source) for Save As / Print to .eml (F-17).
    func rawMessage(messageID: Int64) async throws -> Data {
        guard !isDemo else {
            guard let d = store.detail(messageID) else { throw NetError.server("This message is no longer in the cache.") }
            return DemoData.rawMessage(d, body: store.body(messageID))
        }
        guard let d = store.detail(messageID), let folder = store.folder(d.folderID) else {
            throw NetError.server("This message is no longer in the cache.")
        }
        return try await downloadGate.run { () async throws -> Data in
            let c = try await client(.download)
            try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
            let r = try await c.fetch("\(d.uid)", items: "(UID BODY.PEEK[])", timeout: 300)
            guard let data = r.first(where: { $0.uid == d.uid })?.items["BODY[]"]?.data, !data.isEmpty else {
                throw NetError.server("The server didn't return the message. Try again.")
            }
            return data
        }
    }

    // MARK: Folder management (F-10, F-12, F-14, F-27)

    private func delimiter() -> String {
        store.folders(account: account.id).first?.delimiter ?? "/"
    }

    /// Creates a folder on the server (and locally, so it's usable at once). `parent` nests it.
    @discardableResult
    func createFolder(name: String, parent: Folder? = nil, role: FolderRole = .none) async throws -> Folder {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw NetError.server("Enter a folder name.") }
        let delim = parent?.delimiter ?? delimiter()
        // An empty delimiter is a flat namespace (LIST answered NIL): no nesting, and no reserved character.
        if parent != nil, delim.isEmpty { throw NetError.server("This mail server doesn't support folders inside folders.") }
        guard delim.isEmpty || !clean.contains(delim) else { throw NetError.server("Folder names can't contain \"\(delim)\".") }
        let path = parent.map { $0.path + delim + clean } ?? clean
        try await syncGate.run {
            let c = try await client(.sync)
            try await c.createMailbox(path)
        }
        let f = store.addFolder(account: account.id, path: path, name: clean, role: role, delimiter: delim)
        NotificationCenter.default.post(name: .mailFoldersChanged, object: self)
        guard let f else { throw NetError.server("The folder was created but couldn't be cached.") }
        return f
    }

    func renameFolder(_ folder: Folder, to name: String) async throws {
        guard folder.role == .none else { throw NetError.server("System folders can't be renamed.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let delim = folder.delimiter
        guard !clean.isEmpty, delim.isEmpty || !clean.contains(delim) else { throw NetError.server("Enter a valid folder name.") }
        // Queued actions name the folder by its current path; they are sent before it changes.
        try await settleOps(for: folder)
        var comps = delim.isEmpty ? [folder.path] : folder.path.components(separatedBy: delim)
        comps[comps.count - 1] = clean
        let newPath = comps.joined(separator: delim)
        try await syncGate.run {
            let c = try await client(.sync)
            try await c.renameMailbox(folder.path, to: newPath)
        }
        let saved = store.renameFolder(folder.id, path: newPath, name: isGmail ? Store.displayName(ListedFolder(path: newPath, delimiter: folder.delimiter, attributes: []), isGmail: true) : clean)
        NotificationCenter.default.post(name: .mailFoldersChanged, object: self)
        await refreshFolders()
        if !saved { throw NetError.server("The folder was renamed on the server, but the mail cache couldn't be updated.") }
    }

    func deleteFolder(_ folder: Folder) async throws {
        guard folder.role == .none else { throw NetError.server("System folders can't be deleted.") }
        // Queued actions go first: a message just moved out of this folder must have left it before
        // the server deletes the folder with everything in it.
        try await settleOps(for: folder)
        try await syncGate.run {
            let c = try await client(.sync)
            try await c.deleteMailbox(folder.path)
        }
        let removed = store.deleteFolder(folder.id)
        NotificationCenter.default.post(name: .mailFoldersChanged, object: self)
        NotificationCenter.default.postMailDataChanged(.all)
        if !removed { throw NetError.server("The folder was deleted on the server, but the mail cache couldn't be updated.") }
    }

    func setSubscribed(_ folder: Folder, _ on: Bool) async throws {
        try await syncGate.run {
            let c = try await client(.sync)
            try await c.setSubscribed(folder.path, on)
        }
    }

    /// Permanently deletes everything in Trash or Spam (F-10). Refuses any other folder.
    func emptyFolder(_ folder: Folder) async throws {
        guard folder.role == .trash || folder.role == .spam else { throw NetError.server("Only Trash and Spam can be emptied.") }
        // Queued actions go first: a message just moved here must be emptied with the rest, and one
        // just rescued from here must have left before the folder is wiped.
        try await settleOps(for: folder)
        try await syncGate.run {
            let c = try await client(.sync)
            // A fresh SELECT, not the "already selected" shortcut: the emptying works from the
            // message count and MODSEQ the server reports now, not from an earlier sync.
            guard let info = try await c.select(folder.path, readOnly: false) else { throw NetError.closed }
            try self.verifySelection(info, folder: folder)
            guard !info.readOnly else { throw NetError.server("\"\(folder.name)\" is read-only on the server.") }
            try await c.expungeAll()
        }
        guard store.deleteMessages(folderID: folder.id, uids: store.localUIDs(folderID: folder.id)) else {
            throw NetError.server("The folder was emptied on the server, but the mail cache couldn't be updated.")
        }
        store.setServerUnread(folderID: folder.id, 0)
        NotificationCenter.default.postMailDataChanged(.folder(folder.id))
    }

    /// Sends the queued actions and waits until none concern this folder (as source or as the
    /// destination of a move). Throws when they can't be sent right now.
    private func settleOps(for folder: Folder) async throws {
        // Only failures from here on count: one reported earlier already put its messages back on screen.
        unsettledSources.remove(folder.id)
        for _ in 0..<40 {
            await flushOps()
            let waiting = store.ops(account: account.id).contains { op in
                op.folderID == folder.id || (op.folderID == 0 && op.folderPath == folder.path)
                    || (op.kind == "move" && op.arg == folder.path)
            }
            if !waiting {
                // "Nothing waiting" is not "everything left": a move or delete the server refused for good
                // (or one that couldn't even be queued) is gone from the queue while its message is still
                // in the folder. Deleting or emptying the folder now would destroy it (H-12).
                guard unsettledSources.remove(folder.id) == nil else {
                    throw NetError.server("A message couldn't be moved out of \"\(folder.name)\", so the folder was left as it is. Check the folder and try again.")
                }
                return
            }
            // Our own flush gave up (offline, or the server refused): don't wait for it.
            if !flushing { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw NetError.server("Some actions for \"\(folder.name)\" haven't reached the server yet. Try again in a moment.")
    }

    /// Mailbox storage use (KB used, KB limit), nil when the server doesn't support QUOTA (F-27).
    func quota() async -> (used: Int, limit: Int)? {
        guard !isDemo else { return (1_843_200, 15_728_640) }
        return try? await syncGate.run { () async throws -> (used: Int, limit: Int)? in
            let c = try await client(.sync)
            return try await c.quota()
        }
    }

    /// The account's Archive folder, created on the server when it has none (B-03 / F-14). Gmail archives
    /// into All Mail. Never Trash.
    func archiveFolder() async throws -> Folder {
        if let f = store.folder(account: account.id, role: isGmail ? .all : .archive) { return f }
        if let f = store.folders(account: account.id).first(where: { $0.name.lowercased() == "archive" && $0.selectable }) { return f }
        return try await createFolder(name: "Archive", role: .archive)
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
    /// Cancels the previous search and shares the click connection's gate, so it can never interleave its
    /// SELECT with the SELECT of a message being opened on the same lane.
    func serverSearch(_ query: SearchQuery, folder: Folder? = nil) async throws -> [Int64] {
        guard !isDemo, !query.isEmpty else { return [] }
        guard let scope = folder ?? store.folder(account: account.id, role: .all) ?? store.folder(account: account.id, role: .inbox) else { return [] }
        searchTask?.cancel()
        let known = Set(store.localUIDs(folderID: scope.id))
        let t0 = Date()
        let task = Task { [weak self] () async throws -> [Int64] in
            guard let self else { return [] }
            return try await self.fetchGate.run { () async throws -> [Int64] in
                try Task.checkCancellation()
                let c = try await self.client(.fetch)
                try self.verifySelection(try await c.ensureSelected(scope.path, readOnly: true), folder: scope)
                let uids: [UInt32]
                if await c.isGmail {
                    uids = try await c.uidSearch(prefix: "X-GM-RAW", text: query.gmailRaw)
                } else {
                    // Unrepresentable criteria (has:attachment, server-only operators, non-ASCII) must not
                    // widen to "ALL": leave the results to the local cache search instead.
                    guard query.isIMAPRepresentable else { return [] }
                    uids = try await c.uidSearch(query.imapCriteria)
                }
                let newest = Array(uids.sorted(by: >).prefix(200))
                let removed = self.locallyRemovedUIDs(folderID: scope.id, folder: scope)
                let missing = newest.filter { !known.contains($0) && !removed.contains($0) }
                try Task.checkCancellation()
                let headers = missing.isEmpty ? [] : try await c.fetchHeaders(imapUIDSet(missing))
                try self.store.insertChecked(folderID: scope.id, headers)
                Debug.log("server search '\(query.gmailRaw)' in \(scope.name): \(newest.count) hits, \(headers.count) new, \(Debug.ms(since: t0))")
                return self.store.ids(folderID: scope.id, uids: newest)
            }
        }
        searchTask = task
        return try await task.value
    }

    // MARK: Actions (optimistic locally, queued for the server)

    /// Folders a move or delete could not leave: the server refused it for good, or it could not be
    /// queued. settleOps reads this before a folder is deleted or emptied (H-12).
    private var unsettledSources: Set<Int64> = []

    /// `validity` is each source folder's UIDVALIDITY when the rows were read (an action that waited out
    /// its Undo window passes it): the queued UIDs belong to that numbering, not to whatever the folder
    /// has by now, so a folder renumbered in between makes the action stale instead of misdirected.
    func queue(_ op: PendingOpKind, rows: [MessageRow], validity: [Int64: UInt32] = [:]) {
        let (kind, arg) = op.stored
        // The demo mailbox has no server: local changes are the whole action, nothing waits to be sent.
        if isDemo || stopped { return }
        let byFolder = Dictionary(grouping: rows, by: { $0.folderID })
        for (fid, list) in byFolder {
            guard let f = store.folder(fid) else {
                // The folder left the cache (deleted, or pruned after the server stopped listing it):
                // its messages went with it, so there is nothing to act on. Said, not swallowed.
                report(NetError.server("An action couldn't be sent because its folder is no longer on the server."))
                continue
            }
            let recorded = validity[fid].flatMap { $0 != 0 ? $0 : nil } ?? f.uidValidity
            let queued = store.addOp(account: account.id, kind: kind, folderPath: f.path, uids: list.map { $0.uid }, arg: arg,
                                     folderID: f.id, uidvalidity: recorded)
            if !queued {
                // The local change already happened; say so instead of letting the server action vanish
                // (C-10), and bring back rows that were removed for an action that will never be sent.
                report(NetError.server("A queued action couldn't be saved to disk and won't reach the server."))
                if op.needsRefetchOnRefusal {
                    unsettledSources.insert(f.id)
                    let uids = list.map { $0.uid }
                    Task { _ = await self.refetchHeaders(folder: f, uids: uids) }
                }
            }
        }
        Task { await flushOps() }
    }

    /// Thrown inside flushOps when the server's UIDVALIDITY is not the one an action was queued under.
    private struct StaleOp: Error {}

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
        guard !isDemo, !stopped else { return }
        // A second caller just returns: the loop below re-reads the queue until it is empty, so whatever
        // was queued meanwhile is picked up by the flush already running.
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        var attempts: [Int64: Int] = [:]
        // Ops left queued by this flush (their folder can't be selected right now); retried next time.
        var skipped = Set<Int64>()
        while !stopped {
            guard let op = store.ops(account: account.id).first(where: { !skipped.contains($0.id) }) else { break }
            // Resolve by folder id first: a queued action must follow its folder across a rename (C-28).
            // Ops queued by older builds have no id and still rely on the path they recorded.
            let byID = op.folderID != 0 ? store.folder(op.folderID) : nil
            guard let f = byID ?? store.folder(account: account.id, path: op.folderPath) else {
                store.removeOp(op.id) // Folder is gone; its ops were already reset with it.
                continue
            }
            guard f.selectable else {
                // The folder still exists but can't be opened right now (\Noselect): the action stays
                // queued. Dropping it would leave rows removed here that the server still has.
                skipped.insert(op.id)
                continue
            }
            if op.uidvalidity != 0, f.uidValidity != 0, op.uidvalidity != f.uidValidity {
                store.removeOp(op.id) // Stale UIDs would land on the wrong messages.
                continue
            }
            guard let opKind = PendingOpKind(op) else {
                store.removeOp(op.id) // Unknown kind (older cache): dropping beats skipping forever.
                continue
            }
            do {
                try await syncGate.run {
                    let c = try await client(.sync)
                    let info = try await c.ensureSelected(f.path, readOnly: false)
                    try self.verifySelection(info, folder: f)
                    // Checked against the server, not only the cache: right after a reset the cached
                    // value is 0 and would let UIDs from the old numbering through.
                    if op.uidvalidity != 0, info.uidValidity != 0, op.uidvalidity != info.uidValidity { throw StaleOp() }
                    switch opKind {
                    case .flag(let set, let flag): try await c.store(op.uids, "\(set ? "+" : "-")FLAGS.SILENT (\(flag))")
                    case .move(let dest): try await c.move(op.uids, to: dest)
                    case .expunge: try await c.expungeUIDs(op.uids)
                    }
                }
                store.removeOp(op.id)
                attempts[op.id] = nil
            } catch is StaleOp {
                // The folder was renumbered: these UIDs name other messages now. The next sync of the
                // folder lists what it really holds.
                store.removeOp(op.id)
                continue
            } catch let e as NetError {
                if case .server(let m) = e, !Self.isTemporaryRefusal(m) {
                    // The server refused it for good; don't retry forever.
                    store.removeOp(op.id)
                    report(e)
                    if opKind.needsRefetchOnRefusal {
                        unsettledSources.insert(f.id)
                        await refetchHeaders(folder: f, uids: op.uids)
                    }
                    continue
                }
                report(e)
                // Only a server refusal says something about the op. A dropped or timed-out connection
                // must leave it queued and must not count toward the three-strike drop.
                guard case .server = e else { return }
                let n = (attempts[op.id] ?? 0) + 1
                if n >= 3 {
                    // Temporary refusal that won't clear: give up and undo the optimistic local delete.
                    store.removeOp(op.id)
                    if opKind.needsRefetchOnRefusal {
                        unsettledSources.insert(f.id)
                        await refetchHeaders(folder: f, uids: op.uids)
                    }
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
    @discardableResult
    func refetchHeaders(folder: Folder, uids: [UInt32]) async -> Bool {
        guard !uids.isEmpty else { return true }
        do {
            let headers = try await syncGate.run { () async throws -> [ParsedHeader] in
                let c = try await client(.sync)
                try self.verifySelection(try await c.ensureSelected(folder.path, readOnly: true), folder: folder)
                return try await c.fetchHeaders(imapUIDSet(uids))
            }
            try store.insertChecked(folderID: folder.id, headers)
            NotificationCenter.default.postMailDataChanged(.folder(folder.id))
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Saves a draft to the server's Drafts folder and returns the new row, found by the Message-ID the
    /// draft was built with (B-09) — never by subject, which other drafts may share.
    @discardableResult
    func saveDraft(_ data: Data, messageID: String? = nil) async throws -> Int64? {
        guard let drafts = store.folder(account: account.id, role: .drafts) else {
            throw NetError.server("This account has no Drafts folder.")
        }
        try await syncGate.run {
            _ = try await client(.sync).append(drafts.path, flags: "\\Draft \\Seen", message: data)
        }
        await sync(folderID: drafts.id, prefetch: false)
        guard let messageID else { return nil }
        if let id = store.messageID(folderID: drafts.id, messageIDHeader: messageID) { return id }
        // That sync may have coalesced with one already running and returned at once, before the
        // appended draft was fetched. Wait for it, then sync once more if the row is still missing.
        await waitForSyncToFinish(folderID: drafts.id)
        if let id = store.messageID(folderID: drafts.id, messageIDHeader: messageID) { return id }
        await sync(folderID: drafts.id, prefetch: false)
        return store.messageID(folderID: drafts.id, messageIDHeader: messageID)
    }

    var smtpEndpoint: SMTPClient.Endpoint {
        get async throws {
            SMTPClient.Endpoint(host: account.smtpHost, port: account.smtpPort, security: account.smtpSecurity,
                                username: account.smtpLogin, password: try await appPassword())
        }
    }

    /// Files a copy of a sent message (non-Gmail servers; Gmail files its own).
    func appendCopy(_ data: Data, to folder: Folder) async throws {
        try await syncGate.run {
            _ = try await client(.sync).append(folder.path, flags: "\\Seen", message: data)
        }
    }

    /// Sends through SMTP. Gmail files a copy in Sent itself; other servers get an APPEND.
    func send(_ message: OutgoingMessage, progress: ((SMTPClient.Stage) -> Void)? = nil) async throws {
        let endpoint = try await smtpEndpoint
        // MIME building (attachment reads + base64) runs off the main actor (O-04).
        let data = try await Task.detached(priority: .userInitiated) { try MessageBuilder.build(message) }.value
        try await SMTPClient.send(endpoint, from: account.email, recipients: message.allRecipients, message: data,
                                  progress: progress)
        await fileSentCopy(data)
    }

    /// After SMTP accepted a message: files the copy in Sent where the server doesn't do it itself, and
    /// refreshes Sent. Used by the direct send and by the outbox, so both report a copy that couldn't be filed.
    func fileSentCopy(_ data: Data) async {
        guard let sent = store.folder(account: account.id, role: .sent) else { return }
        if !isGmail {
            do {
                try await appendCopy(data, to: sent)
            } catch {
                // The message went out; failing to file the copy must not read as a failed send.
                report(NetError.server("The message was sent, but filing it in \"\(sent.name)\" failed: "
                                       + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)))
            }
        }
        // Gmail (and other servers) need a moment to file the sent copy before the Sent sync runs.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.sync(folderID: sent.id)
        }
    }
}

/// What kind of failure the engine last reported.
enum MailErrorKind {
    case auth
    case network
    case temporary
    case permanent
}

/// A queued server action, typed here at the engine boundary. `Store.PendingOp` keeps the string
/// form in SQLite (it survives relaunch); everything the engine does with an op goes through this.
enum PendingOpKind: Equatable {
    case flag(set: Bool, flag: String)
    case move(toPath: String)
    case expunge

    init?(_ op: Store.PendingOp) {
        switch op.kind {
        case "flag+": self = .flag(set: true, flag: op.arg)
        case "flag-": self = .flag(set: false, flag: op.arg)
        case "move": self = .move(toPath: op.arg)
        case "expunge": self = .expunge
        default: return nil
        }
    }

    /// How the op is persisted in pending_ops (kind, arg); `init?(_:)` reads it back.
    var stored: (kind: String, arg: String) {
        switch self {
        case .flag(let set, let flag): return (set ? "flag+" : "flag-", flag)
        case .move(let path): return ("move", path)
        case .expunge: return ("expunge", "")
        }
    }

    var isFlagChange: Bool {
        if case .flag = self { return true }
        return false
    }

    /// A refusal of these ops must re-fetch the source headers so the messages reappear locally.
    var needsRefetchOnRefusal: Bool {
        switch self {
        case .move, .expunge: return true
        case .flag: return false
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
