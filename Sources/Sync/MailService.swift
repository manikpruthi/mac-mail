import AppKit
import Network
import UserNotifications

/// App-wide hub: owns the store and one engine per account, and runs actions the UI asks for.
@MainActor
final class MailService {
    static let shared = MailService()

    let store: Store
    private(set) var engines: [String: AccountEngine] = [:]
    private(set) var accounts: [Account] = []
    let outbox = Outbox()

    private init() {
        do {
            store = try Store()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Mac Mail can't open its mail cache"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }

    func start() {
        if AppPaths.isDemo {
            DemoData.seed(store: store)
            // Older demo builds queued actions that can never be sent; clear them.
            for op in store.ops(account: DemoData.account.id) { store.removeOp(op.id) }
        }
        store.repairEmptyBodies()
        accounts = AppPaths.isDemo ? [DemoData.account] : Prefs.accounts
        for a in accounts { makeEngine(a) }
        // First prune shortly after launch, then every 6 hours for long-running sessions (B-15, O-08).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MailService.shared.pruneNow() }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { MailService.shared.pruneNow() }
        }
        // Coming back to the app pushes queued offline actions and outbox messages to the server.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MailService.shared.flushAll()
                MailService.shared.flushOutbox()
            }
        }
        NotificationCenter.default.addObserver(forName: .mailCountsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MailService.shared.updateBadge() }
        }
        // Tapping a notification opens the message it refers to (BUG-35); its buttons act on it (F-23).
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationTapHandler.shared
        center.setNotificationCategories([NotificationTapHandler.category])
        // Network back: send the outbox (F-07).
        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { MailService.shared.flushOutbox() } }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MailService.shared.flushOutbox() }
        updateBadge()
    }

    private var pruneTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private(set) var lastPrune: Date?

    /// Prunes the cache on a utility queue with its own connection (O-09), then refreshes the lists.
    func pruneNow() {
        let path = store.path
        let days = Prefs.offlineDays
        DispatchQueue.global(qos: .utility).async {
            let removed = Store.prune(path: path, offlineDays: days)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MailService.shared.lastPrune = Date()
                    if removed > 0 { NotificationCenter.default.postMailDataChanged(.all) }
                    // Hand back pages freed by the prune connection and by whatever launch work preceded it,
                    // so a one-off startup peak doesn't stay in the footprint.
                    Memory.relieve()
                }
            }
        }
        ImageLoader.pruneCache()
    }

    /// Sends any queued offline actions for every account (used on app activation).
    func flushAll() {
        for e in engines.values { Task { await e.flushOps() } }
    }

    private func makeEngine(_ a: Account) {
        let e = AccountEngine(account: a, store: store)
        e.onNewMail = { [weak self] engine, folderID, headers in self?.notifyNewMail(engine, folderID: folderID, headers) }
        engines[a.id] = e
        e.start()
    }

    func engine(_ accountID: String) -> AccountEngine? { engines[accountID] }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    var defaultAccount: Account? {
        if let id = Prefs.defaultAccountID, let a = account(id) { return a }
        return accounts.first
    }

    // MARK: Accounts

    /// Signs in to IMAP and SMTP (F-05) before anything is saved; reports which side failed.
    func verify(_ account: Account, password: String) async throws {
        let probe = IMAPClient(host: account.imapHost, port: account.imapPort, username: account.username,
                               password: password, security: account.imapSecurity)
        do {
            try await probe.connect()
            await probe.disconnect()
        } catch {
            throw AccountCheckError(side: "Incoming mail (IMAP)", underlying: error)
        }
        do {
            try await SMTPClient.verify(SMTPClient.Endpoint(host: account.smtpHost, port: account.smtpPort,
                                                            security: account.smtpSecurity, username: account.smtpLogin,
                                                            password: password))
        } catch {
            throw AccountCheckError(side: "Outgoing mail (SMTP)", underlying: error)
        }
    }

    /// Verifies the credentials by signing in, then saves the account and starts syncing.
    func addAccount(_ account: Account, password: String) async throws {
        try await verify(account, password: password)
        // A refused Keychain write stops the add instead of leaving an account without a password (B-08).
        try Keychain.set(password, for: account.id)
        accounts.append(account)
        Prefs.accounts = accounts.filter { $0.provider != .demo }
        makeEngine(account)
        // Ask for notification permission when the first account is added, not at first delivery (UX-09).
        if accounts.count == 1 { requestNotificationPermission() }
        NotificationCenter.default.post(name: .mailAccountsChanged, object: nil)
    }

    func updateAccount(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        engines[account.id]?.update(account: account)
        Prefs.accounts = accounts.filter { $0.provider != .demo }
        NotificationCenter.default.post(name: .mailAccountsChanged, object: nil)
    }

    /// Account editor / "Sign in again" (F-04): checks the new servers and password, stores the password,
    /// then resets the account's connections so everything reconnects with the new settings (B-11).
    /// An empty password keeps the saved one.
    func updateCredentials(_ account: Account, password: String?) async throws {
        let pass: String
        if let password, !password.isEmpty { pass = password }
        else if let saved = Keychain.get(account.id) { pass = saved }
        else { throw NetError.auth("enter the password for \(account.email).") }
        try await verify(account, password: pass)
        if let password, !password.isEmpty { try Keychain.set(password, for: account.id) }
        // updateAccount() already resets the connections when the servers changed (W-16); a changed
        // password needs one too, and doing both would tear down connections that just started.
        let connectionChanged = accounts.first { $0.id == account.id }.map { account.connectionDiffers(from: $0) } ?? false
        updateAccount(account)
        if !connectionChanged { engines[account.id]?.resetConnections() }
    }

    func removeAccount(_ id: String) {
        engines[id]?.shutdown()
        engines[id] = nil
        accounts.removeAll { $0.id == id }
        Prefs.accounts = accounts.filter { $0.provider != .demo }
        if Prefs.defaultAccountID == id { Prefs.defaultAccountID = nil }
        Keychain.delete(id)
        store.deleteAccount(id)
        outbox.remove(account: id)
        NotificationCenter.default.post(name: .mailAccountsChanged, object: nil)
        updateBadge()
    }

    func shutdown() {
        // Actions still inside their Undo window are committed to the queue, so they survive the quit (F-08).
        commitAllUndoables()
        for e in engines.values { e.shutdown() }
    }

    // MARK: Sync

    func sync(folderID: Int64) {
        guard let f = store.folder(folderID), let e = engines[f.accountID] else { return }
        Task { await e.sync(folderID: folderID) }
    }

    func syncAllInboxes() {
        syncAll(role: .inbox)
    }

    func syncAll(role: FolderRole) {
        for e in engines.values {
            if let f = store.folder(account: e.account.id, role: role) { Task { await e.sync(folderID: f.id) } }
        }
    }

    var isSyncing: Bool { engines.values.contains { $0.syncingFolders > 0 } }

    var statusError: String? {
        for e in engines.values { if let err = e.lastError { return "\(e.account.email): \(err)" } }
        return nil
    }

    // MARK: Actions

    func setFlag(_ rows: [MessageRow], flag: MessageFlags, on: Bool) {
        let imapFlag: String
        switch flag {
        case .seen: imapFlag = "\\Seen"
        case .flagged: imapFlag = "\\Flagged"
        case .answered: imapFlag = "\\Answered"
        default: return
        }
        let changing = rows.filter { $0.flags.contains(flag) != on }
        guard !changing.isEmpty else { return }
        // A write the cache refused changes nothing: no row, no queued server action.
        guard store.setFlag(messageIDs: changing.map { $0.id }, flag: flag, on: on) else { NSSound.beep(); return }
        for r in changing { if on { r.flags.insert(flag) } else { r.flags.remove(flag) } }
        for (acct, list) in Dictionary(grouping: changing, by: { $0.accountID }) {
            engines[acct]?.queue(.flag(set: on, flag: imapFlag), rows: list)
        }
        updateBadge()
        NotificationCenter.default.postMailDataChanged(.flags(ids: changing.map { $0.id }))
    }

    enum MoveTarget { case archive, trash, spam, inbox, folder(String) }

    /// The result of a move: the toast text and, while the action can still be undone, its id.
    struct MoveResult {
        var label: String
        var undoID: UUID?
    }

    /// An optimistic local change whose server operation waits out the Undo window (F-08).
    private struct Undoable {
        let snapshot: Store.Snapshot
        let commit: () -> Void
        let timer: DispatchWorkItem
    }

    private var undoables: [UUID: Undoable] = [:]
    /// How long Archive / Delete / Move / Spam can be undone before the server is told.
    static let undoWindow: TimeInterval = 8

    /// Moves messages; returns the toast text (and an undo id), or nil if nothing happened.
    @discardableResult
    func move(_ rows: [MessageRow], to target: MoveTarget) -> MoveResult? {
        var done = 0
        var label = ""
        var commits: [() -> Void] = []
        var removedIDs: [Int64] = []
        var creatingArchive: [(AccountEngine, [MessageRow])] = []
        for (acct, list) in Dictionary(grouping: rows, by: { $0.accountID }) {
            guard let engine = engines[acct] else { continue }
            let destination: Folder?
            switch target {
            case .archive:
                label = "Archived"
                // Gmail archives into All Mail; elsewhere the Archive folder. Never Trash (B-03): when the
                // account has no Archive folder it is created on the server first (F-14).
                // The demo mailbox is laid out like Gmail.
                destination = store.folder(account: acct, role: engine.isGmail || engine.isDemo ? .all : .archive)
                    ?? store.folders(account: acct).first { $0.name.lowercased() == "archive" && $0.selectable }
                if destination == nil, !engine.isDemo {
                    creatingArchive.append((engine, list))
                    continue
                }
            case .trash:
                label = "Moved to Trash"
                destination = store.folder(account: acct, role: .trash)
            case .spam:
                label = "Marked as spam"
                destination = store.folder(account: acct, role: .spam)
            case .inbox:
                label = "Moved to Inbox"
                destination = store.folder(account: acct, role: .inbox)
            case .folder(let path):
                destination = store.folder(account: acct, path: path)
                label = "Moved to \(destination?.name ?? path)"
            }
            // Deleting from Trash (or Spam) removes the message for good.
            if case .trash = target, list.allSatisfy({ $0.folderRole == .trash || $0.folderRole == .spam }) {
                commits.append { engine.queue(.expunge, rows: list) }
                removedIDs += list.map { $0.id }
                label = "Deleted permanently"
                done += list.count
                continue
            }
            guard let dest = destination else { continue }
            let movable = list.filter { $0.folderID != dest.id }
            guard !movable.isEmpty else { continue }
            commits.append { engine.queue(.move(toPath: dest.path), rows: movable) }
            removedIDs += movable.map { $0.id }
            done += movable.count
        }
        for (engine, list) in creatingArchive {
            Task {
                do {
                    let folder = try await engine.archiveFolder()
                    _ = MailService.shared.move(list, to: .folder(folder.path))
                    (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Created an Archive folder and archived")
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Couldn't create an Archive folder: \(msg)")
                }
            }
        }
        var undoID: UUID?
        if !removedIDs.isEmpty {
            let snapshot = store.snapshot(ids: removedIDs)
            // Rows the cache couldn't remove stay where they are, and the server is told nothing.
            guard store.deleteMessages(ids: removedIDs) else { return nil }
            let id = UUID()
            let commitAll = { for c in commits { c() } }
            let timer = DispatchWorkItem { MainActor.assumeIsolated { MailService.shared.commitUndoable(id) } }
            undoables[id] = Undoable(snapshot: snapshot, commit: commitAll, timer: timer)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: timer)
            undoID = id
        }
        updateBadge()
        NotificationCenter.default.postMailDataChanged(.all)
        guard done > 0 else {
            if !creatingArchive.isEmpty { return MoveResult(label: "Creating an Archive folder…", undoID: nil) }
            // Everything already lives in the destination (e.g. archiving from All Mail): say so.
            if case .archive = target { return MoveResult(label: "Already archived", undoID: nil) }
            return nil
        }
        return MoveResult(label: done == 1 ? label : "\(label) · \(done) messages", undoID: undoID)
    }

    /// Puts the messages back and cancels the server operation (F-08). False once it was committed.
    @discardableResult
    func undo(_ id: UUID) -> Bool {
        guard let u = undoables.removeValue(forKey: id) else { return false }
        u.timer.cancel()
        store.restore(u.snapshot)
        updateBadge()
        NotificationCenter.default.postMailDataChanged(.all)
        return true
    }

    private func commitUndoable(_ id: UUID) {
        guard let u = undoables.removeValue(forKey: id) else { return }
        u.commit()
    }

    func commitAllUndoables() {
        for id in Array(undoables.keys) {
            undoables[id]?.timer.cancel()
            commitUndoable(id)
        }
    }

    /// Mark everything in a folder read — F-11 is deliberately not offered (risky bulk action).

    /// Empty Trash / Empty Spam (F-10).
    func emptyFolder(_ folder: Folder) async throws {
        guard let e = engines[folder.accountID] else { throw NetError.server("Account not found") }
        if e.isDemo {
            guard store.deleteMessages(folderID: folder.id, uids: store.localUIDs(folderID: folder.id)) else {
                throw NetError.server("The mail cache couldn't be updated.")
            }
            NotificationCenter.default.postMailDataChanged(.folder(folder.id))
        } else {
            try await e.emptyFolder(folder)
        }
        updateBadge()
    }

    // MARK: Sending with undo

    struct PendingSend {
        let id = UUID()
        let accountID: String
        let message: OutgoingMessage
        let replyTo: MessageRow?
        let draftToDelete: MessageRow?
    }

    /// Where a queued send is. Undo is only possible while `waiting` (B-04).
    enum SendState: Equatable { case waiting, uploading, done }

    /// How a send ended, for the composer.
    enum SendOutcome {
        case sent
        /// Couldn't reach the server: the message is in the outbox and goes out when the network is back (F-07).
        case queued
        case failed(Error)
    }

    /// Shown when the final "." went out but no reply confirmed it: the server may have delivered the
    /// message, so it must not be queued or retried automatically (F-01).
    nonisolated static let deliveryUncertain =
        "Delivery uncertain: the server didn't confirm the message, so it may already have been sent. Check Sent before trying again."

    /// A send whose outcome the server never confirmed (F-01).
    struct DeliveryUncertainError: Error, LocalizedError {
        var errorDescription: String? { MailService.deliveryUncertain }
    }

    private var pendingSends: [UUID: Task<Void, Never>] = [:]
    private var sendStates: [UUID: SendState] = [:]
    private var undoHandlers: [UUID: () -> Void] = [:]
    private var sendOrder: [UUID] = []

    /// Queues a send behind the Undo delay. Returns the id the UI uses to cancel it.
    /// The pending entry stays until send() returns, so a quit during the upload still waits.
    func queueSend(_ p: PendingSend, onUndo: @escaping () -> Void, onResult: @escaping (SendOutcome) -> Void) -> UUID {
        let delay = max(0, Prefs.undoSendSeconds)
        sendStates[p.id] = .waiting
        undoHandlers[p.id] = onUndo
        sendOrder.append(p.id)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self else { return }
            // Past this line nothing can undo the send: the state flips before any network work starts.
            guard !Task.isCancelled, self.sendStates[p.id] == .waiting else { self.forgetSend(p.id); return }
            self.sendStates[p.id] = .uploading
            NotificationCenter.default.post(name: .mailSendStateChanged, object: nil)
            defer { self.forgetSend(p.id) }
            guard let engine = self.engines[p.accountID] else { onResult(.failed(NetError.server("Account not found"))); return }
            if engine.isDemo { onResult(.sent); return }
            // A draft copy is written while the send runs so a quit or a failure can't lose the message
            // (the composer is hidden by then); it is deleted once SMTP accepts (V2-08).
            var message = p.message
            if message.messageID == nil { message.messageID = MessageBuilder.newMessageID(for: message.from) }
            var safetyDraftID: Int64?
            var mime: Data?
            do {
                let data = try await Task.detached { try MessageBuilder.build(message) }.value
                mime = data
                safetyDraftID = try await engine.saveDraft(data, messageID: message.messageID)
            } catch {
                // The safety copy failed; the send itself can still go out.
            }
            let safetyDraft = safetyDraftID.flatMap { self.store.rows(ids: [$0]).first }
            var finishing = false
            do {
                try await engine.send(message, progress: { if case .finishing = $0 { finishing = true } })
                self.afterSent(engine: engine, safetyDraft: safetyDraft, replyTo: p.replyTo, draftToDelete: p.draftToDelete)
                onResult(.sent)
            } catch {
                if finishing, Self.isOffline(error) {
                    // The final "." went out but the reply never came: queueing the same MIME could deliver
                    // it twice (F-01). Keep the safety draft and tell the user to check Sent.
                    onResult(.failed(DeliveryUncertainError()))
                } else if Self.isOffline(error) {
                    // Network trouble, not a refusal: park it in the outbox instead of failing (F-07).
                    do {
                        try self.outbox.add(message, accountID: p.accountID, replyToID: p.replyTo?.id,
                                            draftToDeleteID: p.draftToDelete?.id, safetyDraftID: safetyDraft?.id,
                                            mime: mime)
                        onResult(.queued)
                    } catch {
                        onResult(.failed(error))
                    }
                } else {
                    onResult(.failed(error))
                }
            }
        }
        pendingSends[p.id] = task
        return p.id
    }

    private func afterSent(engine: AccountEngine, safetyDraft: MessageRow?, replyTo: MessageRow?, draftToDelete: MessageRow?) {
        // The server copies are expunged either way. A draft row the cache couldn't drop is recorded,
        // and goes when the next Drafts sync sees it missing on the server.
        var cacheOK = true
        if let d = safetyDraft { engine.queue(.expunge, rows: [d]); cacheOK = store.deleteMessages(ids: [d.id]) && cacheOK }
        if let r = replyTo { setFlag([r], flag: .answered, on: true) }
        if let d = draftToDelete { engine.queue(.expunge, rows: [d]); cacheOK = store.deleteMessages(ids: [d.id]) && cacheOK }
        if !cacheOK {
            DiagnosticsLog.record("\(engine.account.email): the sent message's draft couldn't be removed from the mail cache; it will go on the next Drafts sync.")
        }
    }

    /// Connection-level failures (no route, timeout, closed) mean "try later"; refusals and auth errors don't.
    static func isOffline(_ error: Error) -> Bool {
        if let e = error as? NetError { return e.isConnectionProblem }
        if error is NWError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain || ns.domain == NSPOSIXErrorDomain || ns.domain == "kCFErrorDomainCFNetwork"
    }

    private func forgetSend(_ id: UUID) {
        pendingSends[id] = nil
        sendStates[id] = nil
        undoHandlers[id] = nil
        sendOrder.removeAll { $0 == id }
        NotificationCenter.default.post(name: .mailSendStateChanged, object: nil)
    }

    /// Cancels a send that is still waiting out its Undo delay. Once the upload started it is too late,
    /// and this returns false so the UI never claims an undo that didn't happen (B-04).
    func cancelSend(_ id: UUID) -> Bool {
        guard sendStates[id] == .waiting, let t = pendingSends[id] else { return false }
        sendStates[id] = .done
        t.cancel()
        forgetSend(id)
        return true
    }

    /// The newest send still inside its Undo window (Edit ▸ Undo Send, ⌘Z / Esc — F-09).
    var undoableSendID: UUID? { sendOrder.last { sendStates[$0] == .waiting } }

    /// Undoes the newest waiting send and reopens its composer.
    @discardableResult
    func undoLatestSend() -> Bool {
        guard let id = undoableSendID, let handler = undoHandlers[id], cancelSend(id) else { return false }
        handler()
        return true
    }

    var hasPendingSends: Bool { !pendingSends.isEmpty }

    // MARK: Outbox (F-07)

    private var flushingOutbox = false

    /// Sends what's waiting in the outbox. Network failures leave it for the next try; refusals keep it
    /// with the error recorded and are surfaced in the sidebar status.
    func flushOutbox() {
        guard !flushingOutbox, !outbox.items.isEmpty else { return }
        flushingOutbox = true
        Task {
            defer { flushingOutbox = false }
            var sent = 0
            for item in outbox.items where item.lastError == nil || item.attempts < Outbox.maxAttempts {
                guard let engine = engines[item.accountID], let account = account(item.accountID) else {
                    // The account is gone, so the message can never go out on its own: show it as failed
                    // instead of skipping it forever (F-23).
                    outbox.markNeedsDecision(item.id, reason: "The account this message belongs to was removed.")
                    continue
                }
                var finishing = false
                do {
                    let data = try outbox.data(item)
                    let endpoint = try await engine.smtpEndpoint
                    try await SMTPClient.send(endpoint, from: account.email, recipients: item.recipients, message: data,
                                              progress: { if case .finishing = $0 { finishing = true } })
                    if !engine.isGmail, let sentFolder = store.folder(account: account.id, role: .sent) {
                        Task { try? await engine.appendCopy(data, to: sentFolder) }
                    }
                    let rows = store.rows(ids: [item.safetyDraftID, item.replyToID, item.draftToDeleteID].compactMap { $0 })
                    afterSent(engine: engine, safetyDraft: rows.first { $0.id == item.safetyDraftID },
                              replyTo: rows.first { $0.id == item.replyToID },
                              draftToDelete: rows.first { $0.id == item.draftToDeleteID })
                    outbox.remove(item.id)
                    sent += 1
                } catch {
                    if finishing, Self.isOffline(error) {
                        // The server may already have accepted this message: a retry could deliver it twice
                        // (F-01). Keep it for Retry/Delete, and stop on what is probably a dead connection.
                        outbox.markNeedsDecision(item.id, reason: Self.deliveryUncertain)
                        break
                    }
                    outbox.recordFailure(item.id, error: Self.isOffline(error) ? nil : error)
                    if Self.isOffline(error) { break }
                }
            }
            if sent > 0 {
                (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast(sent == 1 ? "Outbox message sent" : "\(sent) outbox messages sent")
            }
        }
    }

    // MARK: Badge and notifications

    func updateBadge() {
        // "Show unread count on Dock icon" preference (default on).
        guard Prefs.d.object(forKey: "showDockBadge") == nil
            || Prefs.d.bool(forKey: "showDockBadge") else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let n = store.unifiedUnreadCount()
        NSApp.dockTile.badgeLabel = n > 0 ? (n > 999 ? "999+" : "\(n)") : nil
    }

    /// Asks for notification permission up front (when the first account is added), not at first delivery.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private var askedForNotifications = false

    /// Whether the user is looking at the mail window right now (then a banner would be noise).
    private var userIsLookingAtMail: Bool {
        guard NSApp.isActive, let w = (NSApp.delegate as? AppDelegate)?.mainWindow?.window else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    private func notifyNewMail(_ engine: AccountEngine, folderID: Int64, _ headers: [ParsedHeader]) {
        updateBadge()
        // Per-account switch (F-23); alerts also appear while the app is active but its window is hidden,
        // minimised or on another Space.
        guard Prefs.notifyNewMail, Prefs.notifications(for: engine.account.id), !headers.isEmpty, !userIsLookingAtMail else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            for h in headers.prefix(3) {
                let content = UNMutableNotificationContent()
                content.title = h.from.display
                content.subtitle = h.subject
                content.sound = .default
                content.categoryIdentifier = NotificationTapHandler.categoryID
                // The row id of this exact message (folder + UID), never a UID lookup across folders (B-05).
                content.userInfo = ["messageID": MailService.shared.store.messageID(folderID: folderID, uid: h.uid) ?? 0]
                content.threadIdentifier = engine.account.id
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            if headers.count > 3 {
                let content = UNMutableNotificationContent()
                content.title = "\(headers.count - 3) more new messages"
                content.body = engine.account.email
                content.threadIdentifier = engine.account.id
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
        if askedForNotifications {
            post()
        } else {
            askedForNotifications = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted { DispatchQueue.main.async { post() } }
            }
        }
    }
}

/// Which side of an account check failed (F-05), so the sheet can say "Outgoing mail (SMTP): …".
struct AccountCheckError: Error, LocalizedError {
    let side: String
    let underlying: Error
    var errorDescription: String? {
        "\(side): " + ((underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription)
    }
}

extension Notification.Name {
    /// A send moved between waiting / uploading / done (Edit ▸ Undo Send validation).
    static let mailSendStateChanged = Notification.Name("MacMail.sendStateChanged")
}

/// Opens the message a notification refers to when the user taps it (BUG-35), and runs its
/// Mark as Read / Archive buttons (F-23).
final class NotificationTapHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationTapHandler()
    static let categoryID = "macmail.newMail"
    static let markReadID = "macmail.markRead"
    static let archiveID = "macmail.archive"

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: markReadID, title: "Mark as Read", options: []),
            UNNotificationAction(identifier: archiveID, title: "Archive", options: []),
        ], intentIdentifiers: [], options: [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        let id = (response.notification.request.content.userInfo["messageID"] as? NSNumber)?.int64Value ?? 0
        guard id != 0 else { return }
        let action = response.actionIdentifier
        // UNUserNotificationCenter calls its delegate on the main thread.
        MainActor.assumeIsolated {
            let service = MailService.shared
            switch action {
            case Self.markReadID:
                service.setFlag(service.store.rows(ids: [id]), flag: .seen, on: true)
            case Self.archiveID:
                let rows = service.store.rows(ids: [id])
                if !rows.isEmpty { service.move(rows, to: .archive) }
            default:
                NSApp.activate(ignoringOtherApps: true)
                MessageWindowController.show(messageID: id)
            }
        }
    }
}
