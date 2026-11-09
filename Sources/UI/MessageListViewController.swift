import AppKit

/// A row in the list: one message, or (when grouping by conversation) a thread with its messages as children.
final class ListNode {
    let row: MessageRow
    var children: [ListNode]?
    init(row: MessageRow, children: [ListNode]? = nil) {
        self.row = row
        self.children = children
    }

    var allRows: [MessageRow] { children.map { $0.map { $0.row } } ?? [row] }
    var unreadCount: Int { allRows.filter { !$0.flags.contains(.seen) }.count }
    var isThread: Bool { (children?.count ?? 0) > 1 }
}

/// The message list. Outlook-style: conversation grouping is a per-folder toggle; threads expand in place,
/// and each message is still read on its own in the preview.
@MainActor
final class MessageListViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = MessageOutlineView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let groupToggle = NSButton(checkboxWithTitle: "Conversations", target: nil, action: nil)
    private let olderButton = NSButton(title: "Load older messages", target: nil, action: nil)
    private var nodes: [ListNode] = []
    private(set) var source: MailSource = .unified
    private(set) var grouped = false
    private var searchRows: [MessageRow] = []
    private var serverSearching = false
    private var serverSearchError: String?
    private let filterBar = SearchFilterBar()
    private var filterCollapsed: NSLayoutConstraint!
    private var searchText = ""
    /// Folder the search started from ("This folder" scope); nil when started from All Inboxes.
    private var searchFolderID: Int64?
    private var searchToken = 0
    private var reloadScheduled = false

    var onSelectionChange: (([MessageRow]) -> Void)?
    var onOpen: ((MessageRow) -> Void)?
    var showToast: ((String) -> Void)?

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        groupToggle.controlSize = .small
        groupToggle.font = .systemFont(ofSize: 11)
        groupToggle.target = self
        groupToggle.action = #selector(toggleGroupingTapped)
        groupToggle.toolTip = "Group messages by conversation in this folder (⌥⌘C)"

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("m"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 68
        outline.style = .inset
        outline.allowsMultipleSelection = true
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        scroll.documentView = outline

        olderButton.bezelStyle = .inline
        olderButton.controlSize = .small
        olderButton.target = self
        olderButton.action = #selector(loadOlder)

        filterBar.isHidden = true
        filterBar.onChange = { [weak self] _ in self?.filtersChanged() }
        for v in [titleLabel, subtitle, groupToggle, filterBar, scroll, olderButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: groupToggle.leadingAnchor, constant: -8),
            groupToggle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            groupToggle.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            filterBar.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 4),
            filterBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: olderButton.topAnchor, constant: -4),
            olderButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            olderButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        filterCollapsed = filterBar.heightAnchor.constraint(equalToConstant: 0)
        filterCollapsed.isActive = true
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(dataChanged(_:)), name: .mailDataChanged, object: nil)
    }

    // MARK: Loading

    func show(_ source: MailSource) {
        self.source = source
        setFilterBarVisible(false)
        if case .search = source {} else { searchRows = [] }
        grouped = Prefs.groupByConversation(folderKey: folderKey)
        groupToggle.state = grouped ? .on : .off
        reload(keepSelection: false)
        outline.scrollRowToVisible(0)
    }

    private var folderKey: String {
        switch source {
        case .unified: return "unified"
        case .folder(let id): return "\(id)"
        case .search: return "search"
        }
    }

    @objc private func dataChanged(_ note: Notification) {
        // Read/flag changes: patch the affected rows in place instead of re-querying the whole folder.
        if note.userInfo?["flagsOnly"] != nil, let ids = note.userInfo?["ids"] as? [Int64] {
            updateFlagsInPlace(Set(ids))
            return
        }
        if case .search = source, note.userInfo?["flagsOnly"] == nil { return }
        if let fid = note.object as? Int64, case .folder(let current) = source, fid != current { return }
        // Coalesce bursts (initial sync posts once per chunk).
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload(keepSelection: true)
        }
    }

    private func updateFlagsInPlace(_ ids: Set<Int64>) {
        let t0 = Date()
        let fresh = MailService.shared.store.flags(ids: Array(ids))
        var changedRows = IndexSet()
        for r in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: r) as? ListNode else { continue }
            var hit = false
            for row in node.allRows where ids.contains(row.id) {
                if let f = fresh[row.id] { row.flags = f }
                hit = true
            }
            if hit { changedRows.insert(r) }
        }
        // Collapsed threads: children aren't rows, but their parent row was caught via allRows above.
        if !changedRows.isEmpty { outline.reloadData(forRowIndexes: changedRows, columnIndexes: [0]) }
        updateSubtitle()
        Debug.log("flags patched in place (\(changedRows.count) rows): \(Debug.ms(since: t0))")
    }

    private var allRows: [MessageRow] { nodes.flatMap { $0.allRows } }

    private func updateSubtitle() {
        let rows = allRows
        let unread = rows.filter { !$0.flags.contains(.seen) }.count
        var sub = "\(rows.count) message\(rows.count == 1 ? "" : "s")"
        if unread > 0 { sub += " · \(unread) unread" }
        if case .search = source {
            if serverSearching { sub += " · searching the server…" }
            else if let e = serverSearchError { sub += " · server search failed: \(e)" }
        }
        subtitle.stringValue = sub
    }

    func reload(keepSelection: Bool) {
        let t0 = Date()
        defer { Debug.log("list reload (\(nodes.count) rows): \(Debug.ms(since: t0))") }
        let store = MailService.shared.store
        let selectedIDs = Set(selectedRows.map { $0.id })
        let rows: [MessageRow]
        switch source {
        case .unified:
            rows = store.unifiedInboxRows()
            titleLabel.stringValue = "All Inboxes"
            olderButton.isHidden = true
        case .folder(let id):
            rows = store.rows(folderID: id)
            let f = store.folder(id)
            titleLabel.stringValue = f?.name ?? "Folder"
            olderButton.isHidden = rows.count < 50
        case .search(let q):
            rows = searchRows
            titleLabel.stringValue = "Search: \(q)"
            olderButton.isHidden = true
        }
        nodes = grouped ? Self.group(rows) : rows.map { ListNode(row: $0) }
        updateSubtitle()
        outline.reloadData()
        if keepSelection && !selectedIDs.isEmpty {
            var idx = IndexSet()
            for r in 0..<outline.numberOfRows {
                if let n = outline.item(atRow: r) as? ListNode, selectedIDs.contains(n.row.id) { idx.insert(r) }
            }
            suppressSelection = true
            outline.selectRowIndexes(idx, byExtendingSelection: false)
            suppressSelection = false
        }
    }

    static func group(_ rows: [MessageRow]) -> [ListNode] {
        var order: [String] = []
        var buckets: [String: [MessageRow]] = [:]
        for r in rows {
            let key = "\(r.accountID):\(r.threadID)"
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]!.append(r)
        }
        return order.map { key in
            let list = buckets[key]!
            if list.count == 1 { return ListNode(row: list[0]) }
            return ListNode(row: list[0], children: list.map { ListNode(row: $0) })
        }
    }

    // MARK: Search

    /// The typed text plus the filter bar's choices.
    private var currentQuery: SearchQuery { filterBar.filters.apply(to: SearchQuery.parse(searchText)) }

    private var scopeFolderID: Int64? { filterBar.filters.scope == .folder ? searchFolderID : nil }

    private func setFilterBarVisible(_ visible: Bool) {
        filterBar.isHidden = !visible
        filterCollapsed.isActive = !visible
    }

    /// Instant local results as you type. `from` is where the search started (for the "This folder" scope).
    func showSearch(_ text: String, from origin: MailSource) {
        let starting: Bool
        if case .search = source { starting = false } else { starting = true }
        if starting {
            filterBar.reset()
            if case .folder(let id) = origin {
                searchFolderID = id
                filterBar.configure(folderName: MailService.shared.store.folder(id)?.name)
            } else {
                searchFolderID = nil
                filterBar.configure(folderName: nil)
            }
            setFilterBarVisible(true)
        }
        searchText = text.trimmingCharacters(in: .whitespaces)
        source = .search(searchText)
        serverSearchError = nil
        searchRows = Self.dedupe(MailService.shared.store.search(currentQuery, folderID: scopeFolderID))
        grouped = Prefs.groupByConversation(folderKey: "search")
        groupToggle.state = grouped ? .on : .off
        reload(keepSelection: false)
    }

    private var filterWork: DispatchWorkItem?

    private func filtersChanged() {
        guard case .search = source else { return }
        searchRows = Self.dedupe(MailService.shared.store.search(currentQuery, folderID: scopeFolderID))
        reload(keepSelection: false)
        selectFirst()
        filterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runServerSearch() }
        filterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Runs the server search for every account (or the scoped folder's account) and merges with the local results.
    func runServerSearch() {
        let q = currentQuery
        guard !q.isEmpty, case .search = source else { return }
        searchToken += 1
        let token = searchToken
        let scopeID = scopeFolderID
        let store = MailService.shared.store
        serverSearching = true
        serverSearchError = nil
        updateSubtitle()
        Task {
            var ids: [Int64] = []
            var errors: [String] = []
            for e in MailService.shared.engines.values {
                var folder: Folder?
                if let scopeID {
                    guard let f = store.folder(scopeID), f.accountID == e.account.id else { continue }
                    folder = f
                }
                do { ids += try await e.serverSearch(q, folder: folder) }
                catch { errors.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            }
            guard token == searchToken, case .search = source else { return }
            serverSearching = false
            serverSearchError = errors.first
            var merged = store.search(q, folderID: scopeID) + store.rows(ids: ids)
            merged.sort { $0.date > $1.date }
            searchRows = Self.dedupe(merged)
            reload(keepSelection: true)
        }
    }

    /// Gmail keeps one message in several folders (Inbox and All Mail); show it once.
    static func dedupe(_ rows: [MessageRow]) -> [MessageRow] {
        var seen = Set<String>()
        return rows.filter { r in
            let key = r.gmailID != 0 ? "\(r.accountID):g\(r.gmailID)" : "\(r.accountID):\(r.id)"
            return seen.insert(key).inserted
        }
    }

    // MARK: Grouping

    @objc private func toggleGroupingTapped() { setGrouped(groupToggle.state == .on) }

    func toggleGrouping() { setGrouped(!grouped) }

    func setGrouped(_ on: Bool) {
        grouped = on
        groupToggle.state = on ? .on : .off
        Prefs.setGroupByConversation(on, folderKey: folderKey)
        reload(keepSelection: true)
    }

    // MARK: Selection

    private var suppressSelection = false

    var selectedRows: [MessageRow] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ListNode) }.flatMap { node -> [MessageRow] in
            // A collapsed thread acts on every message in it; an expanded thread's header acts on its latest.
            if node.isThread && !outline.isItemExpanded(node) { return node.allRows }
            return [node.row]
        }
    }

    /// The single message to show in the preview.
    var focusedRow: MessageRow? {
        guard outline.selectedRowIndexes.count == 1, let node = outline.item(atRow: outline.selectedRow) as? ListNode else { return nil }
        return node.row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelectionChange?(selectedRows)
    }

    func selectFirst() {
        guard outline.numberOfRows > 0 else { onSelectionChange?([]); return }
        outline.selectRowIndexes([0], byExtendingSelection: false)
    }

    /// After a move/delete: keep the cursor near where it was.
    func selectAfterRemoval(previousIndex: Int) {
        let n = outline.numberOfRows
        guard n > 0 else { onSelectionChange?([]); return }
        outline.selectRowIndexes([min(previousIndex, n - 1)], byExtendingSelection: false)
    }

    var selectedIndex: Int { outline.selectedRow }

    /// Messages just below (and one above) the selection — the ones you're likely to open next.
    func neighborRows(of row: MessageRow) -> [MessageRow] {
        let i = outline.selectedRow
        guard i >= 0 else { return [] }
        return [i + 1, i + 2, i + 3, i - 1].compactMap { r -> MessageRow? in
            guard r >= 0, r < outline.numberOfRows else { return nil }
            return (outline.item(atRow: r) as? ListNode)?.row
        }
    }

    func focusList() { view.window?.makeFirstResponder(outline) }

    @objc private func doubleClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? ListNode else { return }
        onOpen?(node.row)
    }

    @objc private func loadOlder() {
        guard case .folder(let id) = source, let f = MailService.shared.store.folder(id),
              let engine = MailService.shared.engine(f.accountID) else { return }
        olderButton.isEnabled = false
        olderButton.title = "Loading…"
        Task {
            let n = await engine.loadOlder(folderID: id)
            olderButton.isEnabled = true
            olderButton.title = "Load older messages"
            if n == 0 { showToast?("No older messages") }
        }
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let app = NSApp.delegate as? AppDelegate
        switch e.keyCode {
        case 36, 76: // return, enter: open in its own window
            if let r = focusedRow { onOpen?(r) }
            return true
        case 51, 117: // delete, forward delete
            app?.mainWindow?.deleteMessages(nil)
            return true
        default: break
        }
        switch e.charactersIgnoringModifiers {
        case "j": moveSelection(1); return true
        case "k": moveSelection(-1); return true
        case "e": app?.mainWindow?.archiveMessages(nil); return true
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        let next = max(0, min(outline.numberOfRows - 1, outline.selectedRow + delta))
        outline.selectRowIndexes([next], byExtendingSelection: false)
        outline.scrollRowToVisible(next)
    }

    // MARK: Data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ListNode else { return nodes.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ListNode)?.children?[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ListNode)?.isThread ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ListNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("msg")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? MessageCell) ?? MessageCell(identifier: id)
        let isChild = outlineView.parent(forItem: node) != nil
        cell.configure(node, isChild: isChild, showAccount: source == .unified && MailService.shared.accounts.count > 1)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        outlineView.parent(forItem: item) != nil ? 50 : 68
    }

    // MARK: Context menu

    /// Rows a right-click acts on. Like Outlook, right-clicking never changes the selection or opens the message
    /// (so "Mark as Unread" on another email doesn't mark it read by opening it). Right-clicking inside the
    /// selection acts on the whole selection.
    private func contextRows(clicked: Int) -> [MessageRow] {
        guard clicked >= 0, let node = outline.item(atRow: clicked) as? ListNode else { return selectedRows }
        if outline.selectedRowIndexes.contains(clicked) { return selectedRows }
        return node.isThread && !outline.isItemExpanded(node) ? node.allRows : [node.row]
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu, clickedRow: outline.clickedRow) }

    func populate(_ menu: NSMenu, clickedRow: Int) {
        menu.removeAllItems()
        let rows = contextRows(clicked: clickedRow)
        guard let app = NSApp.delegate as? AppDelegate, let w = app.mainWindow, !rows.isEmpty else { return }
        let context = ContextRows(rows)
        func add(_ title: String, _ sel: Selector, _ symbol: String) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = w
            item.representedObject = context
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Reply", #selector(MainWindowController.reply(_:)), "arrowshape.turn.up.left")
        add("Reply All", #selector(MainWindowController.replyAll(_:)), "arrowshape.turn.up.left.2")
        add("Forward", #selector(MainWindowController.forward(_:)), "arrowshape.turn.up.right")
        menu.addItem(.separator())
        let anyUnread = rows.contains { !$0.flags.contains(.seen) }
        add(anyUnread ? "Mark as Read" : "Mark as Unread", #selector(MainWindowController.toggleRead(_:)), anyUnread ? "envelope.open" : "envelope.badge")
        let anyUnflagged = rows.contains { !$0.flags.contains(.flagged) }
        add(anyUnflagged ? "Flag" : "Remove Flag", #selector(MainWindowController.toggleFlag(_:)), "flag")
        menu.addItem(.separator())
        add("Archive", #selector(MainWindowController.archiveMessages(_:)), "archivebox")
        add("Delete", #selector(MainWindowController.deleteMessages(_:)), "trash")
        let inSpam = rows.allSatisfy { $0.folderRole == .spam }
        add(inSpam ? "Not Spam" : "Report Spam", #selector(MainWindowController.toggleSpam(_:)), "xmark.bin")
        let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        move.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        move.submenu = w.moveMenu(for: rows)
        menu.addItem(move)
    }
}

/// The rows a context-menu command applies to, carried on each menu item.
final class ContextRows {
    let rows: [MessageRow]
    init(_ rows: [MessageRow]) { self.rows = rows }
}

/// A "Move to" choice: destination plus the rows to move.
final class MoveChoice {
    let rows: [MessageRow]
    let path: String
    init(rows: [MessageRow], path: String) { self.rows = rows; self.path = path }
}

final class MessageOutlineView: NSOutlineView {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Three-line row: sender + date, subject, preview text. Unread rows are highlighted Outlook-style:
/// a tinted background with an accent bar on the left, bold sender and an accent-coloured subject.
final class MessageCell: NSTableCellView {
    private var isUnread = false
    private var isChildRow = false
    private let sender = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let subject = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let icons = NSStackView()
    private let clip = NSImageView(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attachment") ?? NSImage())
    private let flag = NSImageView(image: NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Flagged") ?? NSImage())
    private let count = NSTextField(labelWithString: "")
    private var subjectTop: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 1.5
        sender.lineBreakMode = .byTruncatingTail
        subject.lineBreakMode = .byTruncatingTail
        snippet.lineBreakMode = .byTruncatingTail
        snippet.textColor = .secondaryLabelColor
        snippet.font = .systemFont(ofSize: 12)
        date.font = .systemFont(ofSize: 11)
        date.textColor = .secondaryLabelColor
        date.alignment = .right
        clip.contentTintColor = .secondaryLabelColor
        clip.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        flag.contentTintColor = .systemOrange
        flag.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        count.textColor = .secondaryLabelColor
        icons.orientation = .horizontal
        icons.spacing = 4
        for v in [count, clip, flag] { icons.addArrangedSubview(v) }
        for v in [dot, sender, date, subject, snippet, icons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        sender.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        icons.setContentCompressionResistancePriority(.required, for: .horizontal)
        subjectTop = subject.topAnchor.constraint(equalTo: sender.bottomAnchor, constant: 1)
        NSLayoutConstraint.activate([
            // The unread bar runs the full height of the row's left edge.
            dot.widthAnchor.constraint(equalToConstant: 3),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            dot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            sender.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sender.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            sender.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -6),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            date.firstBaselineAnchor.constraint(equalTo: sender.firstBaselineAnchor),
            subjectTop,
            subject.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: icons.leadingAnchor, constant: -6),
            icons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            icons.centerYAnchor.constraint(equalTo: subject.centerYAnchor),
            snippet.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 1),
            snippet.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: ListNode, isChild: Bool, showAccount: Bool) {
        let r = node.row
        let unread = node.unreadCount > 0
        isUnread = unread
        isChildRow = isChild
        dot.isHidden = !unread
        var who = r.senderDisplay
        if showAccount, let a = MailService.shared.account(r.accountID) { who += "  ·  " + a.email }
        sender.stringValue = who
        sender.font = .systemFont(ofSize: isChild ? 12 : 13, weight: unread ? .semibold : .regular)
        subject.stringValue = r.subject.isEmpty ? "(no subject)" : r.subject
        subject.font = .systemFont(ofSize: 12.5, weight: unread ? .semibold : .regular)
        subject.isHidden = isChild
        snippet.stringValue = r.snippet
        snippet.isHidden = false
        subjectTop.constant = 1
        date.stringValue = Self.format(r.date)
        clip.isHidden = !node.allRows.contains { $0.hasAttachments }
        flag.isHidden = !node.allRows.contains { $0.flags.contains(.flagged) }
        if node.isThread, let n = node.children?.count {
            count.stringValue = "\(n)"
            count.isHidden = false
        } else {
            count.isHidden = true
        }
        if isChild {
            // Child rows: sender + one preview line.
            subject.isHidden = false
            subject.stringValue = r.snippet.isEmpty ? (r.subject.isEmpty ? "(no subject)" : r.subject) : r.snippet
            subject.textColor = .secondaryLabelColor
            subject.font = .systemFont(ofSize: 12)
            snippet.isHidden = true
        }
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Unread: tinted row + accent bar + accent subject. Selected rows switch to the selection's text colours.
    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        var tint: NSColor = .clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = NSColor.controlAccentColor.withAlphaComponent(0.13)
            self.dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            self.layer?.backgroundColor = (self.isUnread && !selected) ? tint.cgColor : NSColor.clear.cgColor
        }
        if selected {
            for f in [sender, subject, snippet, date, count] { f.textColor = .alternateSelectedControlTextColor }
            dot.layer?.backgroundColor = NSColor.alternateSelectedControlTextColor.cgColor
        } else {
            sender.textColor = .labelColor
            date.textColor = isUnread ? .controlAccentColor : .secondaryLabelColor
            snippet.textColor = .secondaryLabelColor
            count.textColor = .secondaryLabelColor
            subject.textColor = isChildRow ? .secondaryLabelColor : (isUnread ? .controlAccentColor : .labelColor)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    static func format(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return timeFormatter.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return dayFormatter.string(from: d) }
        return shortFormatter.string(from: d)
    }
}
