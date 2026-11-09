import AppKit

/// The three-pane window: sidebar, message list and preview pane, with an Outlook-style toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSWindowDelegate {
    let sidebar = SidebarViewController()
    let list = MessageListViewController()
    let preview = PreviewViewController()
    private let split = NSSplitViewController()
    private let toast = ToastView()
    private var searchField: NSSearchField?
    private var searchDebounce: DispatchWorkItem?
    private var lastSource: MailSource = .unified

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Mac Mail"
        window.minSize = NSSize(width: 900, height: 520)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        // Snapshot mode uses an opaque sidebar because translucent materials can't be captured offscreen.
        let snapshotting = ProcessInfo.processInfo.environment["MAC_MAIL_SNAPSHOT"] != nil
        let sidebarItem = snapshotting ? NSSplitViewItem(viewController: sidebar) : NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = 300
        listItem.maximumThickness = 560
        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 380
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(listItem)
        split.addSplitViewItem(previewItem)
        split.splitView.autosaveName = "MacMailSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 800))

        let toolbar = NSToolbar(identifier: "MacMailToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        toast.translatesAutoresizingMaskIntoConstraints = false
        split.view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: split.view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: split.view.bottomAnchor, constant: -18),
        ])

        sidebar.onSelect = { [weak self] source in self?.showSource(source) }
        list.onSelectionChange = { [weak self] rows, userInitiated in self?.selectionChanged(rows, userInitiated: userInitiated) }
        list.onOpen = { [weak self] row in self?.openRow(row) }
        list.showToast = { [weak self] s in self?.toast.show(s) }
        preview.showToast = { [weak self] s in self?.toast.show(s) }
        preview.onAddAccount = { [weak self] in self?.addAccount() }
        preview.onEditDraft = { [weak self] d in self?.editDraft(d) }

        window.setFrameAutosaveName("MacMailMainWindow")
        if !window.setFrameUsingName("MacMailMainWindow") { window.center() }

        NotificationCenter.default.addObserver(self, selector: #selector(accountsChanged), name: .mailAccountsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foldersChanged), name: .mailFoldersChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        sidebar.reload()
        sidebar.selectDefault()
        if MailService.shared.accounts.isEmpty { preview.showEmpty(text: "") }
    }

    @objc private func accountsChanged() {
        if case .folder(let id) = list.source, MailService.shared.store.folder(id) == nil { sidebar.selectDefault() }
        if MailService.shared.accounts.isEmpty { list.show(.unified); preview.showEmpty(text: "") }
    }

    @objc private func foldersChanged() {
        // First folder list for a new account: jump to its Inbox.
        if list.source == .unified, MailService.shared.accounts.count == 1 { sidebar.selectDefault() }
    }

    // MARK: Navigation

    private func showSource(_ source: MailSource) {
        lastSource = source
        searchField?.stringValue = ""
        list.show(source)
        preview.showEmpty(text: "No message selected")
        switch source {
        case .folder(let id): MailService.shared.sync(folderID: id)
        case .unified: MailService.shared.syncAllInboxes()
        case .search: break
        }
        list.selectFirst()
    }

    private func selectionChanged(_ rows: [MessageRow], userInitiated: Bool) {
        if rows.isEmpty {
            preview.showEmpty(text: "No message selected")
        } else if let r = list.focusedRow {
            if userInitiated {
                // Only an explicit open (click, j/k, Return) marks the message read in the preview.
                preview.show(messageID: r.id)
                prefetchNeighbors(of: r)
            } else {
                // Launch / folder-switch auto-selection: the row is highlighted but not opened,
                // so nothing is marked read or queued to the server.
                preview.showEmpty(text: "Not opened yet — press Return to read")
            }
        } else {
            preview.showEmpty(text: "\(rows.count) messages selected")
        }
    }

    private var neighborWork: DispatchWorkItem?

    /// Once the selection settles, fetch the next few messages' text so arrowing down is instant.
    private func prefetchNeighbors(of row: MessageRow) {
        neighborWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let store = MailService.shared.store
            let rows = self.list.neighborRows(of: row).filter { !store.hasBody($0.id) }
            for (acct, list) in Dictionary(grouping: rows, by: { $0.accountID }) {
                guard let engine = MailService.shared.engine(acct) else { continue }
                Task { await engine.prefetch(ids: list.map { $0.id }) }
            }
        }
        neighborWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Double-click / Return: drafts open in the editor, everything else in its own window (like Outlook).
    func openRow(_ row: MessageRow) {
        if row.folderRole == .drafts, let d = MailService.shared.store.detail(row.id) {
            editDraft(d)
        } else {
            MessageWindowController.show(messageID: row.id)
        }
    }

    func showToast(_ text: String, action: (String, () -> Void)? = nil, duration: TimeInterval = 4) {
        toast.show(text, action: action, duration: duration)
    }

    /// Re-sync when the user comes back to the app (cheap: a delta check).
    func appBecameActive() {
        switch list.source {
        case .folder(let id): MailService.shared.sync(folderID: id)
        case .unified: MailService.shared.syncAllInboxes()
        case .search: break
        }
    }

    // MARK: Toolbar

    private enum TB {
        static let compose = NSToolbarItem.Identifier("compose")
        static let reply = NSToolbarItem.Identifier("reply")
        static let replyAll = NSToolbarItem.Identifier("replyAll")
        static let forward = NSToolbarItem.Identifier("forward")
        static let archive = NSToolbarItem.Identifier("archive")
        static let delete = NSToolbarItem.Identifier("delete")
        static let spam = NSToolbarItem.Identifier("spam")
        static let flag = NSToolbarItem.Identifier("flag")
        static let read = NSToolbarItem.Identifier("read")
        static let move = NSToolbarItem.Identifier("move")
        static let search = NSToolbarItem.Identifier("search")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, TB.compose, .flexibleSpace, TB.reply, TB.replyAll, TB.forward, .space,
         TB.archive, TB.delete, TB.spam, TB.move, .space, TB.read, TB.flag, .flexibleSpace, TB.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case TB.compose: return button("New Message", "square.and.pencil", #selector(newMessage(_:)), "New message (⌘N)")
        case TB.reply: return button("Reply", "arrowshape.turn.up.left", #selector(reply(_:)), "Reply (⌘R)")
        case TB.replyAll: return button("Reply All", "arrowshape.turn.up.left.2", #selector(replyAll(_:)), "Reply all (⇧⌘R)")
        case TB.forward: return button("Forward", "arrowshape.turn.up.right", #selector(forward(_:)), "Forward (⌘J)")
        case TB.archive: return button("Archive", "archivebox", #selector(archiveMessages(_:)), "Archive (E)")
        case TB.delete: return button("Delete", "trash", #selector(deleteMessages(_:)), "Delete (⌫)")
        case TB.spam: return button("Spam", "xmark.bin", #selector(toggleSpam(_:)), "Report spam / Not spam (⇧⌘J)")
        case TB.flag: return button("Flag", "flag", #selector(toggleFlag(_:)), "Flag (⇧⌘L)")
        case TB.read: return button("Read/Unread", "envelope.badge", #selector(toggleRead(_:)), "Mark read / unread (⇧⌘U)")
        case TB.move:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Move"
            item.toolTip = "Move to folder"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Move")
            item.showsIndicator = true
            item.menu = NSMenu()
            item.menu.delegate = self
            return item
        case TB.search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search — from:, subject:, has:attachment"
            item.searchField.setAccessibilityLabel("Search mail")
            item.searchField.delegate = self
            item.searchField.sendsWholeSearchString = false
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.target = self
            item.searchField.action = #selector(searchSubmitted(_:))
            item.searchField.searchMenuTemplate = searchMenu()
            item.preferredWidthForSearchField = 260
            searchField = item.searchField
            return item
        default: return nil
        }
    }

    // MARK: Search

    /// Recent searches (kept small; persisted in the store's prefs table).
    private var recentSearches: [String] {
        get { (MailService.shared.store.pref("searchRecents") ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
        set { MailService.shared.store.setPref("searchRecents", newValue.prefix(5).joined(separator: "\n")) }
    }

    /// The magnifier's menu: recent searches plus query syntax help.
    private func searchMenu() -> NSMenu {
        let menu = NSMenu()
        for q in recentSearches {
            let item = NSMenuItem(title: q, action: #selector(useRecentSearch(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q
            item.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !recentSearches.isEmpty { menu.addItem(.separator()) }
        let help = NSMenuItem(title: "Search syntax help", action: #selector(showSearchHelp(_:)), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        return menu
    }

    @objc private func useRecentSearch(_ sender: NSMenuItem) {
        guard let q = sender.representedObject as? String else { return }
        searchField?.stringValue = q
        searchSubmitted(searchField)
    }

    @objc private func showSearchHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Search syntax"
        alert.informativeText = """
        from:name — from a sender
        to:name — to a recipient
        subject:word — words in the subject
        is:unread · is:starred — by state
        has:attachment — with attachments
        Combine freely: from:jane is:unread has:attachment
        """
        alert.addButton(withTitle: "OK")
        window?.makeKeyAndOrderFront(nil)
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        let q = field.stringValue
        searchDebounce?.cancel()
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            if case .search = list.source { showSource(lastSource) }
            return
        }
        // Local results while typing; the server search runs once typing pauses.
        // No auto-select while typing: the preview must not mark results read per keystroke.
        sidebar.clearSelectionForSearch()
        list.showSearch(q, from: lastSource)
        let work = DispatchWorkItem { [weak self] in self?.list.runServerSearch() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Same as typing in the search field (used by the demo hook).
    func runSearch(_ text: String) {
        searchField?.stringValue = text
        sidebar.clearSelectionForSearch()
        list.showSearch(text, from: lastSource)
        list.selectFirst(userInitiated: true)
        list.runServerSearch()
    }

    @objc private func searchSubmitted(_ sender: Any?) {
        let q = (sender as? NSSearchField)?.stringValue ?? searchField?.stringValue ?? ""
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Remember the search (deduped, newest first) and refresh the magnifier menu.
        var recents = recentSearches.filter { $0 != q }
        recents.insert(q, at: 0)
        recentSearches = recents
        searchField?.searchMenuTemplate = searchMenu()
        searchDebounce?.cancel()
        sidebar.clearSelectionForSearch()
        list.showSearch(q, from: lastSource)
        list.runServerSearch()
    }

    @objc func focusSearch(_ sender: Any?) {
        if let f = searchField { window?.makeFirstResponder(f) }
    }

    // MARK: Actions

    private var targets: [MessageRow] { list.selectedRows }

    /// Rows a command acts on: the right-clicked rows for context-menu items, otherwise the selection.
    private func rows(for sender: Any?) -> [MessageRow] {
        if let item = sender as? NSMenuItem {
            if let c = item.representedObject as? ContextRows { return c.rows }
            if let m = item.representedObject as? MoveChoice { return m.rows }
        }
        return targets
    }

    @objc func newMessage(_ sender: Any?) { ComposeWindowController.open(.new) }

    @objc func reply(_ sender: Any?) { respond(.reply, sender) }
    @objc func replyAll(_ sender: Any?) { respond(.replyAll, sender) }
    @objc func forward(_ sender: Any?) { respond(.forward, sender) }

    private func respond(_ kind: MessageActions.Response, _ sender: Any?) {
        let contextRow = ((sender as? NSMenuItem)?.representedObject as? ContextRows)?.rows.first
        guard let row = contextRow ?? list.focusedRow ?? targets.first else {
            NSSound.beep(); return
        }
        MessageActions.respond(kind, row: row) { [weak self] s in self?.toast.show(s) }
    }

    private func editDraft(_ d: MessageDetail) {
        ComposeWindowController.open(.draft(d, MailService.shared.store.body(d.id)))
    }

    @objc func toggleRead(_ sender: Any?) {
        let rows = rows(for: sender)
        guard !rows.isEmpty else { return }
        let anyUnread = rows.contains { !$0.flags.contains(.seen) }
        MailService.shared.setFlag(rows, flag: .seen, on: anyUnread)
    }

    @objc func markUnread(_ sender: Any?) {
        MailService.shared.setFlag(rows(for: sender), flag: .seen, on: false)
    }

    @objc func toggleFlag(_ sender: Any?) {
        let rows = rows(for: sender)
        guard !rows.isEmpty else { return }
        let anyUnflagged = rows.contains { !$0.flags.contains(.flagged) }
        MailService.shared.setFlag(rows, flag: .flagged, on: anyUnflagged)
    }

    @objc func archiveMessages(_ sender: Any?) { move(rows(for: sender), to: .archive) }
    @objc func deleteMessages(_ sender: Any?) {
        let rows = rows(for: sender)
        if !rows.isEmpty, rows.allSatisfy({ $0.folderRole == .trash || $0.folderRole == .spam }) {
            MessageActions.confirmPermanentDelete(rows, in: window) { [weak self] in
                self?.move(rows, to: .trash)
            }
            return
        }
        move(rows, to: .trash)
    }

    @objc func toggleSpam(_ sender: Any?) {
        let rows = rows(for: sender)
        move(rows, to: rows.allSatisfy({ $0.folderRole == .spam }) ? .inbox : .spam)
    }

    /// Toolbar Move menu items carry a MoveChoice; the Message ▸ Move to… item opens a searchable picker.
    @objc func moveToFolder(_ sender: Any?) {
        if let choice = (sender as? NSMenuItem)?.representedObject as? MoveChoice {
            move(choice.rows, to: .folder(choice.path))
            return
        }
        let rows = rows(for: sender)
        guard !rows.isEmpty, let acct = rows.first?.accountID, rows.allSatisfy({ $0.accountID == acct }) else {
            NSSound.beep(); return
        }
        folderPicker = FolderPicker(account: acct) { [weak self] path in
            self?.move(rows, to: .folder(path))
        }
        folderPicker?.beginSheet(on: window)
    }

    /// Menu key equivalents ⌘1…⌘9: select the nth folder in the sidebar.
    @objc func selectFolderAtIndex(_ sender: NSMenuItem) {
        guard (1...9).contains(sender.tag), let source = sidebar.folderSource(at: sender.tag - 1) else { return }
        showSource(source)
    }

    /// Cycles keyboard focus: sidebar → list → preview → sidebar.
    @objc func focusNextPane(_ sender: Any?) {
        guard let w = window else { return }
        func pane(of responder: NSResponder?) -> Int {
            var view = responder as? NSView
            while let v = view {
                if v === list.view { return 1 }
                if v === preview.view { return 2 }
                view = v.superview
            }
            return 0
        }
        switch pane(of: w.firstResponder) {
        case 0: list.focusList()
        case 1:
            if let web = Self.firstFocusable(in: preview.view) { w.makeFirstResponder(web) }
            else { sidebar.focus() }
        default: sidebar.focus()
        }
    }

    private static func firstFocusable(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder && view.canBecomeKeyView { return view }
        for sub in view.subviews {
            if let hit = firstFocusable(in: sub) { return hit }
        }
        return nil
    }

    private var folderPicker: FolderPicker?

    /// Move entry point for the swipe actions (they act on a row, not the selection).
    func moveRows(_ rows: [MessageRow], to target: MailService.MoveTarget) {
        move(rows, to: target)
    }

    private func move(_ rows: [MessageRow], to target: MailService.MoveTarget) {
        guard !rows.isEmpty else { NSSound.beep(); return }
        let index = max(0, list.selectedIndex)
        // Only move the cursor when the open/selected message is the one that left the list.
        let selectedIDs = Set(list.selectedRows.map { $0.id })
        let touchesSelection = rows.contains { selectedIDs.contains($0.id) }
        if let label = MailService.shared.move(rows, to: target) {
            if touchesSelection {
                list.reload(keepSelection: false)
                // The cursor move after archive/delete never marks the next message read.
                list.selectAfterRemoval(previousIndex: index, userInitiated: false)
            } else {
                list.reload(keepSelection: true)
            }
            toast.show(label)
        } else {
            NSSound.beep()
        }
    }

    func moveMenu(for rows: [MessageRow]) -> NSMenu {
        let menu = NSMenu()
        guard let acct = rows.first?.accountID, rows.allSatisfy({ $0.accountID == acct }) else {
            menu.addItem(withTitle: "Select messages from one account", action: nil, keyEquivalent: "")
            return menu
        }
        let current = Set(rows.map { $0.folderID })
        for f in sidebar.moveTargets(account: acct) where !current.contains(f.id) && f.role != .starred && f.role != .important {
            let item = NSMenuItem(title: f.name, action: #selector(moveToFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MoveChoice(rows: rows, path: f.path)
            item.image = NSImage(systemSymbolName: f.role.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc func toggleConversations(_ sender: Any?) { list.toggleGrouping() }

    @objc func toggleLightBackground(_ sender: Any?) { preview.toggleLight() }

    @objc func saveAttachments(_ sender: Any?) {
        preview.saveAllAttachments()
    }

    @objc func syncNow(_ sender: Any?) {
        appBecameActive()
        for e in MailService.shared.engines.values { Task { await e.refreshFolders(); await e.flushOps() } }
    }

    @objc func addAccount() {
        (NSApp.delegate as? AppDelegate)?.showSettings(addAccount: true)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validate(item.action, item: item)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action, item: nil) }

    private func validate(_ action: Selector?, item: NSMenuItem?) -> Bool {
        let rows = rows(for: item)
        switch action {
        case #selector(reply(_:)), #selector(replyAll(_:)), #selector(forward(_:)):
            if item?.representedObject is ContextRows { return !rows.isEmpty }
            return list.focusedRow != nil || rows.count == 1
        case #selector(archiveMessages(_:)), #selector(deleteMessages(_:)), #selector(toggleSpam(_:)),
             #selector(toggleFlag(_:)), #selector(toggleRead(_:)), #selector(markUnread(_:)), #selector(moveToFolder(_:)):
            if action == #selector(toggleConversations(_:)) { return true }
            return !rows.isEmpty
        case #selector(toggleConversations(_:)):
            item?.state = list.grouped ? .on : .off
            return true
        case #selector(newMessage(_:)):
            return !MailService.shared.accounts.isEmpty
        default:
            return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        // Closing the window quits, even with message or compose windows open: pending sends and
        // unsaved drafts get their own prompts from applicationShouldTerminate.
        NSApp.terminate(nil)
    }
}

extension MainWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in moveMenu(for: targets).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// A searchable "Move to folder" sheet for the Message ▸ Move to… command.
@MainActor
final class FolderPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let onPick: (String) -> Void
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Folder]
    private var shown: [Folder] = []
    private var sheet: NSWindow?

    init(account: String, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        all = MailService.shared.store.folders(account: account).filter { $0.selectable }
        super.init()
        shown = all
    }

    func beginSheet(on parent: NSWindow?) {
        guard let parent, sheet == nil else { return }
        field.placeholderString = "Filter folders"
        field.target = self
        field.action = #selector(filterChanged)
        let col = NSTableColumn(identifier: .init("f"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(commit)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let move = NSButton(title: "Move", target: self, action: #selector(commit))
        move.bezelStyle = .rounded
        move.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        for v in [field, scroll, move, cancel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: move.topAnchor, constant: -10),
            move.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            move.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: move.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: move.leadingAnchor, constant: -8),
        ])
        let w = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Move to folder"
        w.contentView = content
        sheet = w
        parent.beginSheet(w)
        parent.makeFirstResponder(field)
    }

    @objc private func filterChanged() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func commit() {
        guard let f = selected, let s = sheet else { return }
        s.sheetParent?.endSheet(s)
        sheet = nil
        onPick(f.path)
    }

    @objc private func dismiss() {
        sheet?.sheetParent?.endSheet(sheet!)
        sheet = nil
    }

    private var selected: Folder? {
        table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: shown[row].name)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A small pill at the bottom of the window ("Archived", "Sending… Undo").
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var handler: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = NSColor.systemBlue.blended(withFraction: 0.35, of: .white)
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.target = self
        button.action = #selector(tapped)
        let stack = NSStackView(views: [label, button])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, action: (String, () -> Void)? = nil, duration: TimeInterval = 3) {
        label.stringValue = text
        handler = action?.1
        button.title = action?.0 ?? ""
        button.isHidden = action == nil
        isHidden = false
        alphaValue = 1
        // VoiceOver hears the toast; the Undo button joins the keyboard loop so it's Tab-reachable.
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text + (action.map { " — \($0.0) available" } ?? "")])
        if action != nil { window?.recalculateKeyViewLoop() }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.animator().alphaValue = 0 }) { self.isHidden = true }
            if self.button.nextKeyView != nil || action != nil { self.window?.recalculateKeyViewLoop() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func tapped() {
        handler?()
        handler = nil
        hideWork?.cancel()
        isHidden = true
    }
}
