import AppKit

enum MailSource: Equatable {
    /// All Inboxes.
    case unified
    /// Every account's folder with this role, merged (unified Sent, Drafts, Archive, Trash — F-13).
    case unifiedRole(FolderRole)
    /// Flagged messages across every account (F-13).
    case flagged
    case folder(Int64)
    case search(String)

    var isUnified: Bool {
        switch self {
        case .unified, .unifiedRole, .flagged: return true
        default: return false
        }
    }
}

final class SidebarItem: NSObject {
    enum Kind: Equatable {
        case unified, account(String), folder(Int64)
        /// Unified role sources (F-13) and the group rows that hold them.
        case unifiedRole(FolderRole), flagged, group(String)
        /// A saved search (F-29), keyed by its name.
        case saved(String)
    }
    let kind: Kind
    let title: String
    let symbol: String
    var children: [SidebarItem] = []
    var unread = 0
    var hasError = false
    var pendingOps = 0

    init(kind: Kind, title: String, symbol: String) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
    }

    var accountID: String? {
        if case .account(let id) = kind { return id }
        return nil
    }
}

/// Accounts and their folders (Gmail labels), plus a Unified Inbox when there is more than one account.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = NSOutlineView()
    private var roots: [SidebarItem] = []
    private let status = NSTextField(labelWithString: "")
    private let statusSpinner = NSProgressIndicator()
    var onSelect: ((MailSource) -> Void)?
    /// A saved search was picked: run it in the search field (F-29).
    var onSavedSearch: ((String) -> Void)?
    private var suppressSelection = false

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let col = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = ProcessInfo.processInfo.environment["MAC_MAIL_SNAPSHOT"] != nil ? .plain : .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 10
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = false
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        status.maximumNumberOfLines = 2
        status.cell?.wraps = true
        status.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(status)
        root.addSubview(statusSpinner)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            statusSpinner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusSpinner.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            // Fixed height (two lines): the status text changes with every sync, and a label that grew
            // and shrank between one and two lines nudged the whole folder list up and down.
            status.heightAnchor.constraint(equalToConstant: 30),
        ])
        view = root
        reload()
        let click = NSClickGestureRecognizer(target: self, action: #selector(statusClicked))
        status.addGestureRecognizer(click)
        status.setAccessibilityElement(true)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reloadNote), name: .mailFoldersChanged, object: nil)
        nc.addObserver(self, selector: #selector(reloadNote), name: .mailAccountsChanged, object: nil)
        nc.addObserver(self, selector: #selector(countsNote), name: .mailDataChanged, object: nil)
        nc.addObserver(self, selector: #selector(countsNote), name: .mailCountsChanged, object: nil)
        nc.addObserver(self, selector: #selector(statusNote), name: .mailStatusChanged, object: nil)
        nc.addObserver(self, selector: #selector(statusNote), name: .mailOutboxChanged, object: nil)
        nc.addObserver(self, selector: #selector(reloadNote), name: .mailSavedSearchesChanged, object: nil)
    }

    @objc private func reloadNote() { reload() }

    /// Unread recounts run per folder on every data change; coalesce bursts (P10) behind 250 ms.
    private var countsWork: DispatchWorkItem?
    @objc private func countsNote() {
        countsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshCounts() }
        countsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    @objc private func statusNote() { updateStatus() }

    @objc private func statusClicked() {
        MailService.shared.flushAll()
        MailService.shared.flushOutbox()
        updateStatus()
    }

    func reload() {
        let service = MailService.shared
        let store = service.store
        let selected = selectedKind
        var items: [SidebarItem] = []
        if service.accounts.count > 1 {
            // Smart folders across every account (F-13).
            let smart = SidebarItem(kind: .group("smart"), title: "All Accounts", symbol: "tray.2")
            smart.children = [
                SidebarItem(kind: .unified, title: "All Inboxes", symbol: "tray.2"),
                SidebarItem(kind: .flagged, title: "Flagged", symbol: "flag"),
                SidebarItem(kind: .unifiedRole(.sent), title: "Sent", symbol: FolderRole.sent.symbol),
                SidebarItem(kind: .unifiedRole(.drafts), title: "Drafts", symbol: FolderRole.drafts.symbol),
                SidebarItem(kind: .unifiedRole(.archive), title: "Archive", symbol: FolderRole.archive.symbol),
                SidebarItem(kind: .unifiedRole(.trash), title: "Trash", symbol: FolderRole.trash.symbol),
            ]
            items.append(smart)
        }
        let saved = SavedSearches.all
        if !saved.isEmpty {
            let group = SidebarItem(kind: .group("saved"), title: "Saved Searches", symbol: "magnifyingglass")
            group.children = saved.map { SidebarItem(kind: .saved($0.name), title: $0.name, symbol: "magnifyingglass") }
            items.append(group)
        }
        for a in service.accounts {
            let acct = SidebarItem(kind: .account(a.id), title: a.email, symbol: "person.crop.circle")
            for f in store.folders(account: a.id) where f.selectable {
                acct.children.append(SidebarItem(kind: .folder(f.id), title: f.name, symbol: f.role.symbol))
            }
            items.append(acct)
        }
        roots = items
        refreshCounts(reloadOutline: false)
        suppressSelection = true
        outline.reloadData()
        for r in roots where !r.children.isEmpty { outline.expandItem(r) }
        if let selected { select(kind: selected) }
        Debug.log("sidebar roots=\(roots.count) rows=\(outline.numberOfRows)")
        suppressSelection = false
        updateStatus()
    }

    private func refreshCounts(reloadOutline: Bool = true) {
        let service = MailService.shared
        let store = service.store
        // Two aggregate queries instead of several per folder (O-06).
        let counts = store.unreadCounts()
        let ops = store.opCounts()
        for r in roots {
            switch r.kind {
            case .account(let id):
                // Broken account / offline queue state surfaces on the account row.
                r.hasError = service.engines[id]?.lastError != nil
                r.pendingOps = ops[id] ?? 0
            default: break
            }
            for c in r.children {
                switch c.kind {
                case .folder(let id):
                    // Server unread count (STATUS) adjusted by local changes; no network per refresh.
                    c.unread = counts[id] ?? 0
                case .unified:
                    c.unread = store.unifiedUnreadCount()
                default: break
                }
            }
        }
        if reloadOutline {
            for row in 0..<outline.numberOfRows {
                guard let item = outline.item(atRow: row) as? SidebarItem else { continue }
                if case .account = item.kind, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? AccountCell {
                    cell.configure(item)
                } else if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell {
                    cell.configure(item)
                }
            }
        }
        updateStatus()
    }

    private func updateStatus() {
        let service = MailService.shared
        let store = service.store
        let pending = store.opCounts().values.reduce(0, +)
        let outbox = service.outbox.items
        let last = status.stringValue
        if let err = service.statusError {
            status.stringValue = err
            status.textColor = .systemRed
        } else if let failed = outbox.first(where: { $0.lastError != nil }) {
            status.stringValue = "Outbox: “\(failed.subject)” wasn't sent — \(failed.lastError ?? "")"
            status.textColor = .systemRed
        } else if !outbox.isEmpty {
            // Offline outbox (F-07): sent automatically when the connection is back.
            status.stringValue = "\(outbox.count) message\(outbox.count == 1 ? "" : "s") in Outbox — Retry"
            status.textColor = .systemOrange
        } else if pending > 0 {
            // Offline queue: "N actions waiting — click to retry" (the queue is flushed after syncs too).
            status.stringValue = "\(pending) action\(pending == 1 ? "" : "s") waiting — Retry"
            status.textColor = .systemOrange
        } else if service.isSyncing {
            status.stringValue = "Syncing…"
            status.textColor = .secondaryLabelColor
        } else {
            status.stringValue = service.accounts.isEmpty ? "" : "Up to date"
            status.textColor = .secondaryLabelColor
        }
        status.toolTip = status.stringValue
        if service.isSyncing { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
        if status.stringValue != last {
            NSAccessibility.post(element: status, notification: .announcementRequested,
                                 userInfo: [.announcement: status.stringValue])
        }
    }

    private var selectedKind: SidebarItem.Kind? {
        (outline.item(atRow: outline.selectedRow) as? SidebarItem)?.kind
    }

    func select(kind: SidebarItem.Kind) {
        for row in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: row) as? SidebarItem, item.kind == kind {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
        // The folder vanished (deleted or renamed elsewhere): fall back instead of leaving a stale
        // list on screen with nothing highlighted (B-37).
        selectDefault()
    }

    /// Picks All Inboxes, or the first account's Inbox.
    func selectDefault() {
        if roots.first?.kind == .group("smart") { selectIfPresent(.unified); return }
        if let acct = roots.first(where: { $0.accountID != nil }), let first = acct.children.first { selectIfPresent(first.kind) }
    }

    private func selectIfPresent(_ kind: SidebarItem.Kind) {
        for row in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: row) as? SidebarItem, item.kind == kind {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                return
            }
        }
    }

    /// The selected folder, for menu commands (Empty Trash, folder actions).
    var selectedFolder: Folder? {
        guard case .folder(let id) = selectedKind else { return nil }
        return MailService.shared.store.folder(id)
    }

    func clearSelectionForSearch() {
        suppressSelection = true
        outline.deselectAll(nil)
        suppressSelection = false
    }

    /// Folders for the "Move to" menu.
    func moveTargets(account: String) -> [Folder] {
        MailService.shared.store.folders(account: account).filter { $0.selectable }
    }

    /// The nth selectable folder in display order, for the ⌘1…⌘9 Go-to-folder shortcuts.
    func folderSource(at index: Int) -> MailSource? {
        var folders: [Int64] = []
        for root in roots where root.accountID != nil {
            for child in root.children {
                if case .folder(let id) = child.kind { folders.append(id) }
            }
        }
        guard index >= 0, index < folders.count else { return nil }
        return .folder(folders[index])
    }

    func focus() { view.window?.makeFirstResponder(outline) }

    // MARK: Account row menu

    @objc private func syncAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let inbox = MailService.shared.store.folder(account: id, role: .inbox) else { return }
        MailService.shared.sync(folderID: inbox.id)
        if let e = MailService.shared.engines[id] { Task { await e.refreshFolders(); await e.flushOps() } }
    }

    @objc private func signInAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.showSettings(addAccount: false, editAccount: id)
    }

    @objc private func toggleNotifications(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.setNotifications(!Prefs.notifications(for: id), for: id)
    }

    // MARK: Folder management (F-10, F-12)

    private func ask(_ title: String, value: String = "", button: String, then: @escaping (String) -> Void) {
        guard let w = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn { then(field.stringValue) }
        }
    }

    private func run(_ what: String, _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("\(what) failed: \(msg)")
            }
        }
    }

    @objc private func newFolder(_ sender: NSMenuItem) {
        let service = MailService.shared
        let parent = (sender.representedObject as? NSNumber).flatMap { service.store.folder($0.int64Value) }
        guard let acct = parent?.accountID ?? (sender.representedObject as? String), let e = service.engine(acct) else { return }
        ask(parent.map { "New folder inside “\($0.name)”" } ?? "New folder", button: "Create") { [weak self] name in
            self?.run("Creating the folder") { _ = try await e.createFolder(name: name, parent: parent) }
        }
    }

    @objc private func renameFolder(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value, let f = MailService.shared.store.folder(id),
              let e = MailService.shared.engine(f.accountID) else { return }
        let leaf = f.path.components(separatedBy: f.delimiter).last ?? f.name
        ask("Rename “\(f.name)”", value: leaf, button: "Rename") { [weak self] name in
            self?.run("Renaming the folder") { try await e.renameFolder(f, to: name) }
        }
    }

    @objc private func deleteFolder(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value, let f = MailService.shared.store.folder(id),
              let e = MailService.shared.engine(f.accountID), let w = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the folder “\(f.name)”?"
        alert.informativeText = "The folder and every message in it are deleted from the server. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.run("Deleting the folder") { try await e.deleteFolder(f) }
        }
    }

    @objc func emptyFolder(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.int64Value, let f = MailService.shared.store.folder(id) else { return }
        Self.confirmEmpty(f, in: view.window)
    }

    /// Empty Trash / Empty Spam with a confirmation (F-10).
    static func confirmEmpty(_ f: Folder, in window: NSWindow?) {
        guard f.role == .trash || f.role == .spam, let window else { return }
        let n = MailService.shared.store.messageCount(folderID: f.id)
        let alert = NSAlert()
        alert.messageText = "Empty \(f.name)?"
        alert.informativeText = "\(n > 0 ? "\(n) cached message\(n == 1 ? "" : "s") and everything else" : "Everything") in \(f.name) on the server will be deleted permanently. This can't be undone."
        alert.addButton(withTitle: "Empty \(f.name)")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            Task {
                do {
                    try await MailService.shared.emptyFolder(f)
                    (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("\(f.name) emptied")
                } catch {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Couldn't empty \(f.name): \(msg)")
                }
            }
        }
    }

    @objc private func deleteSavedSearch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        SavedSearches.remove(name)
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let a = MailService.shared.account(id), let w = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(a.email)?"
        alert.informativeText = "Its offline mail is deleted from this Mac. Nothing is deleted from the server."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn { MailService.shared.removeAccount(id) }
        }
    }

    // MARK: Data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        switch (item as? SidebarItem)?.kind {
        case .account, .group: return true
        default: return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Account and group headers aren't sources; their actions live in the context menu (B-37).
        switch (item as? SidebarItem)?.kind {
        case .account, .group: return false
        default: return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if item.accountID != nil || { if case .group = item.kind { return true }; return false }() {
            let id = NSUserInterfaceItemIdentifier("account")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? AccountCell) ?? AccountCell(identifier: id)
            cell.configure(item)
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("folder")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell) ?? SidebarCell(identifier: id)
        cell.configure(item)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let item = outline.item(atRow: outline.selectedRow) as? SidebarItem else { return }
        switch item.kind {
        case .unified: onSelect?(.unified)
        case .unifiedRole(let role): onSelect?(.unifiedRole(role))
        case .flagged: onSelect?(.flagged)
        case .folder(let id): onSelect?(.folder(id))
        case .saved(let name):
            if let q = SavedSearches.all.first(where: { $0.name == name })?.query { onSavedSearch?(q) }
        case .account, .group: break
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem else { return }
        func add(_ title: String, _ sel: Selector, _ obj: Any?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.representedObject = obj
            menu.addItem(i)
            return i
        }
        switch item.kind {
        case .account(let id):
            _ = add("Sync Now", #selector(syncAccount(_:)), id)
            _ = add("Edit Account / Sign in again…", #selector(signInAgain(_:)), id)
            let notify = add("Notify About New Mail", #selector(toggleNotifications(_:)), id)
            notify.state = Prefs.notifications(for: id) ? .on : .off
            _ = add("New Folder…", #selector(newFolder(_:)), id)
            // Mailbox usage (F-27), filled in when the server answers.
            let quota = NSMenuItem(title: "Storage: checking…", action: nil, keyEquivalent: "")
            quota.isEnabled = false
            menu.addItem(quota)
            if let e = MailService.shared.engine(id) {
                Task {
                    if let q = await e.quota() {
                        quota.title = "Storage: \(MIME.formatSize(q.used * 1024)) of \(MIME.formatSize(q.limit * 1024))"
                    } else {
                        quota.title = "Storage: not reported by the server"
                    }
                }
            }
            menu.addItem(.separator())
            _ = add("Remove…", #selector(removeAccount(_:)), id)
        case .folder(let fid):
            guard let f = MailService.shared.store.folder(fid) else { return }
            if f.role == .trash || f.role == .spam { _ = add("Empty \(f.name)…", #selector(emptyFolder(_:)), NSNumber(value: fid)) }
            _ = add("New Folder Inside…", #selector(newFolder(_:)), NSNumber(value: fid))
            if f.role == .none {
                _ = add("Rename…", #selector(renameFolder(_:)), NSNumber(value: fid))
                _ = add("Delete Folder…", #selector(deleteFolder(_:)), NSNumber(value: fid))
            }
        case .saved(let name):
            _ = add("Delete Saved Search", #selector(deleteSavedSearch(_:)), name)
        default:
            break
        }
    }
}

/// The account row: name, a warning icon when sign-in/sync is failing, and the offline-queue count.
final class AccountCell: NSTableCellView {
    private let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Account needs attention") ?? NSImage())
    private let ops = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        warning.contentTintColor = .systemOrange
        warning.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        ops.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        ops.textColor = .systemOrange
        for v in [label, warning, ops] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = label
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: warning.leadingAnchor, constant: -4),
            warning.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            warning.centerYAnchor.constraint(equalTo: centerYAnchor),
            ops.leadingAnchor.constraint(equalTo: warning.trailingAnchor, constant: 3),
            ops.centerYAnchor.constraint(equalTo: centerYAnchor),
            ops.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: SidebarItem) {
        textField?.stringValue = item.title
        if let id = item.accountID, let a = MailService.shared.account(id) {
            toolTip = "\(a.email) — IMAP \(a.imapHost):\(a.imapPort) (\(a.imapSecurity.label)), SMTP \(a.smtpHost):\(a.smtpPort) (\(a.smtpSecurity.label))"
        }
        warning.isHidden = !item.hasError
        ops.stringValue = item.pendingOps > 0 ? "✉\(item.pendingOps)" : ""
        ops.isHidden = item.pendingOps == 0
    }
}

final class SidebarCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        imageView = icon
        textField = label
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: SidebarItem) {
        imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
        textField?.stringValue = item.title
        badge.stringValue = item.unread > 0 ? "\(item.unread)" : ""
    }
}

extension Notification.Name {
    static let mailSavedSearchesChanged = Notification.Name("MacMail.savedSearchesChanged")
}

/// Named searches shown in the sidebar (F-29), kept in the store's prefs table.
@MainActor
enum SavedSearches {
    struct Entry: Codable, Equatable { var name: String; var query: String }

    static var all: [Entry] {
        guard let raw = MailService.shared.store.pref("savedSearches"), let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Entry]) {
        let data = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
        MailService.shared.store.setPref("savedSearches", String(decoding: data, as: UTF8.self))
        NotificationCenter.default.post(name: .mailSavedSearchesChanged, object: nil)
    }

    static func add(name: String, query: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !query.isEmpty else { return }
        save(all.filter { $0.name != clean } + [Entry(name: clean, query: query)])
    }

    static func remove(_ name: String) { save(all.filter { $0.name != name }) }
}
