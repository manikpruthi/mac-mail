import AppKit

enum MailSource: Equatable {
    case unified
    case folder(Int64)
    case search(String)
}

final class SidebarItem: NSObject {
    enum Kind: Equatable { case unified, account(String), folder(Int64) }
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
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
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
        updateStatus()
    }

    func reload() {
        let service = MailService.shared
        let store = service.store
        let selected = selectedKind
        var items: [SidebarItem] = []
        if service.accounts.count > 1 {
            items.append(SidebarItem(kind: .unified, title: "All Inboxes", symbol: "tray.2"))
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
        for r in roots {
            if r.kind == .unified { r.unread = store.unifiedUnreadCount() }
            switch r.kind {
            case .account(let id):
                // Broken account / offline queue state surfaces on the account row.
                r.hasError = service.engines[id]?.lastError != nil
                r.pendingOps = store.ops(account: id).count
            default: break
            }
            for c in r.children {
                if case .folder(let id) = c.kind {
                    // Server unread count (STATUS) adjusted by local changes; no network per refresh.
                    c.unread = store.unreadCount(folderID: id)
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
        let pending = service.accounts.reduce(0) { $0 + store.ops(account: $1.id).count }
        let last = status.stringValue
        if let err = service.statusError {
            status.stringValue = err
            status.textColor = .systemRed
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
    }

    /// Picks All Inboxes, or the first account's Inbox.
    func selectDefault() {
        if roots.first?.kind == .unified { select(kind: .unified); return }
        if let first = roots.first?.children.first { select(kind: first.kind) }
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
        for root in roots {
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
        (NSApp.delegate as? AppDelegate)?.showSettings(addAccount: false)
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
        if case .account = (item as? SidebarItem)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Accounts are selectable rows too (context menu: Sync Now, Sign in again, Remove).
        true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if case .account = item.kind {
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
        case .folder(let id): onSelect?(.folder(id))
        case .account: break
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? SidebarItem, let id = item.accountID else { return }
        let sync = NSMenuItem(title: "Sync Now", action: #selector(syncAccount(_:)), keyEquivalent: "")
        sync.target = self
        sync.representedObject = id
        menu.addItem(sync)
        let signIn = NSMenuItem(title: "Sign in again…", action: #selector(signInAgain(_:)), keyEquivalent: "")
        signIn.target = self
        menu.addItem(signIn)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove…", action: #selector(removeAccount(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        menu.addItem(remove)
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
