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

    init(kind: Kind, title: String, symbol: String) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
    }
}

/// Accounts and their folders (Gmail labels), plus a Unified Inbox when there is more than one account.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
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
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reloadNote), name: .mailFoldersChanged, object: nil)
        nc.addObserver(self, selector: #selector(reloadNote), name: .mailAccountsChanged, object: nil)
        nc.addObserver(self, selector: #selector(countsNote), name: .mailDataChanged, object: nil)
        nc.addObserver(self, selector: #selector(statusNote), name: .mailStatusChanged, object: nil)
    }

    @objc private func reloadNote() { reload() }
    @objc private func countsNote() { refreshCounts() }
    @objc private func statusNote() { updateStatus() }

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
        let store = MailService.shared.store
        for r in roots {
            if r.kind == .unified { r.unread = store.unifiedUnreadCount() }
            for c in r.children {
                if case .folder(let id) = c.kind, let f = store.folder(id) {
                    // Counts only where they help: Inbox and user labels, like Gmail.
                    c.unread = (f.role == .inbox || f.role == .none) ? store.unreadCount(folderID: id) : 0
                }
            }
        }
        if reloadOutline {
            for row in 0..<outline.numberOfRows {
                if let item = outline.item(atRow: row) as? SidebarItem,
                   let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell {
                    cell.configure(item)
                }
            }
        }
    }

    private func updateStatus() {
        let service = MailService.shared
        if let err = service.statusError {
            status.stringValue = err
            status.textColor = .systemRed
        } else if service.isSyncing {
            status.stringValue = "Syncing…"
            status.textColor = .secondaryLabelColor
        } else {
            status.stringValue = service.accounts.isEmpty ? "" : "Up to date"
            status.textColor = .secondaryLabelColor
        }
        if service.isSyncing { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
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
        if case .account = (item as? SidebarItem)?.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        if case .account = item.kind {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let t = NSTextField(labelWithString: "")
                t.font = .systemFont(ofSize: 11, weight: .semibold)
                t.textColor = .secondaryLabelColor
                t.lineBreakMode = .byTruncatingTail
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([
                    t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = item.title
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
