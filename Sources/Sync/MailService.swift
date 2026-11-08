import AppKit
import UserNotifications

/// App-wide hub: owns the store and one engine per account, and runs actions the UI asks for.
@MainActor
final class MailService {
    static let shared = MailService()

    let store: Store
    private(set) var engines: [String: AccountEngine] = [:]
    private(set) var accounts: [Account] = []

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
        if AppPaths.isDemo { DemoData.seed(store: store) }
        accounts = AppPaths.isDemo ? [DemoData.account] : Prefs.accounts
        for a in accounts { makeEngine(a) }
        let days = Prefs.offlineDays
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [store] in store.prune(offlineDays: days) }
        updateBadge()
    }

    private func makeEngine(_ a: Account) {
        let e = AccountEngine(account: a, store: store)
        e.onNewMail = { [weak self] engine, headers in self?.notifyNewMail(engine, headers) }
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

    /// Verifies the credentials by signing in, then saves the account and starts syncing.
    func addAccount(_ account: Account, password: String) async throws {
        let probe = IMAPClient(host: account.imapHost, port: account.imapPort, username: account.username, password: password)
        try await probe.connect()
        await probe.disconnect()
        Keychain.set(password, for: account.id)
        accounts.append(account)
        Prefs.accounts = accounts.filter { $0.provider != .demo }
        makeEngine(account)
        NotificationCenter.default.post(name: .mailAccountsChanged, object: nil)
    }

    func updateAccount(_ account: Account) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i] = account
        engines[account.id]?.update(account: account)
        Prefs.accounts = accounts.filter { $0.provider != .demo }
        NotificationCenter.default.post(name: .mailAccountsChanged, object: nil)
    }

    func removeAccount(_ id: String) {
        engines[id]?.shutdown()
        engines[id] = nil
        accounts.removeAll { $0.id == id }
        Prefs.accounts = accounts.filter { $0.provider != .demo }
        Keychain.delete(id)
        store.deleteAccount(id)
        NotificationCenter.default.post(name: .mailAccountsChanged, object: nil)
        updateBadge()
    }

    func shutdown() {
        for e in engines.values { e.shutdown() }
    }

    // MARK: Sync

    func sync(folderID: Int64) {
        guard let f = store.folder(folderID), let e = engines[f.accountID] else { return }
        Task { await e.sync(folderID: folderID) }
    }

    func syncAllInboxes() {
        for e in engines.values {
            if let inbox = store.folder(account: e.account.id, role: .inbox) { Task { await e.sync(folderID: inbox.id) } }
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
        for r in changing { if on { r.flags.insert(flag) } else { r.flags.remove(flag) } }
        store.setFlag(messageIDs: changing.map { $0.id }, flag: flag, on: on)
        for (acct, list) in Dictionary(grouping: changing, by: { $0.accountID }) {
            engines[acct]?.queue(kind: on ? "flag+" : "flag-", rows: list, arg: imapFlag)
        }
        updateBadge()
        NotificationCenter.default.post(name: .mailDataChanged, object: nil,
                                        userInfo: ["flagsOnly": true, "ids": changing.map { $0.id }])
    }

    enum MoveTarget { case archive, trash, spam, inbox, folder(String) }

    /// Moves messages; returns a user-facing label for the toast, or nil if nothing happened.
    @discardableResult
    func move(_ rows: [MessageRow], to target: MoveTarget) -> String? {
        var done = 0
        var label = ""
        for (acct, list) in Dictionary(grouping: rows, by: { $0.accountID }) {
            guard let engine = engines[acct] else { continue }
            let destination: Folder?
            switch target {
            case .archive:
                label = "Archived"
                destination = store.folder(account: acct, role: engine.isGmail ? .all : .archive)
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
                engine.queue(kind: "expunge", rows: list)
                store.deleteMessages(ids: list.map { $0.id })
                label = "Deleted permanently"
                done += list.count
                continue
            }
            guard let dest = destination else { continue }
            let movable = list.filter { $0.folderID != dest.id }
            guard !movable.isEmpty else { continue }
            engine.queue(kind: "move", rows: movable, arg: dest.path)
            store.deleteMessages(ids: movable.map { $0.id })
            done += movable.count
        }
        updateBadge()
        NotificationCenter.default.post(name: .mailDataChanged, object: nil)
        guard done > 0 else { return nil }
        return done == 1 ? label : "\(label) · \(done) messages"
    }

    // MARK: Sending with undo

    struct PendingSend {
        let id = UUID()
        let accountID: String
        let message: OutgoingMessage
        let replyTo: MessageRow?
        let draftToDelete: MessageRow?
        weak var composer: ComposeWindowController?
    }

    private var pendingSends: [UUID: Task<Void, Never>] = [:]

    /// Queues a send behind the Undo delay. Returns the id the UI uses to cancel it.
    func queueSend(_ p: PendingSend, onResult: @escaping (Error?) -> Void) -> UUID {
        let delay = max(0, Prefs.undoSendSeconds)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingSends[p.id] = nil
            guard let engine = self.engines[p.accountID] else { onResult(NetError.server("Account not found")); return }
            do {
                try await engine.send(p.message)
                if let r = p.replyTo { self.setFlag([r], flag: .answered, on: true) }
                if let d = p.draftToDelete { engine.queue(kind: "expunge", rows: [d]); self.store.deleteMessages(ids: [d.id]) }
                onResult(nil)
            } catch {
                onResult(error)
            }
        }
        pendingSends[p.id] = task
        return p.id
    }

    func cancelSend(_ id: UUID) -> Bool {
        guard let t = pendingSends.removeValue(forKey: id) else { return false }
        t.cancel()
        return true
    }

    var hasPendingSends: Bool { !pendingSends.isEmpty }

    // MARK: Badge and notifications

    func updateBadge() {
        let n = store.unifiedUnreadCount()
        NSApp.dockTile.badgeLabel = n > 0 ? (n > 999 ? "999+" : "\(n)") : nil
    }

    private var askedForNotifications = false

    private func notifyNewMail(_ engine: AccountEngine, _ headers: [ParsedHeader]) {
        updateBadge()
        guard Prefs.notifyNewMail, !headers.isEmpty, !NSApp.isActive else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            for h in headers.prefix(3) {
                let content = UNMutableNotificationContent()
                content.title = h.from.display
                content.subtitle = h.subject
                content.sound = .default
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            if headers.count > 3 {
                let content = UNMutableNotificationContent()
                content.title = "\(headers.count - 3) more new messages"
                content.body = engine.account.email
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
