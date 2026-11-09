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
        sidebar.onSavedSearch = { [weak self] q in self?.runSearch(q) }
        list.onSelectionChange = { [weak self] rows, userInitiated in self?.selectionChanged(rows, userInitiated: userInitiated) }
        list.onOpen = { [weak self] row in self?.openRow(row) }
        list.showToast = { [weak self] s in self?.toast.show(s) }
        preview.showToast = { [weak self] s in self?.toast.show(s) }
        preview.onAddAccount = { [weak self] in self?.addAccount() }
        preview.onEditDraft = { [weak self] d in self?.editDraft(d) }

        // The demo has its own saved frame so screenshot runs never move or resize the real window.
        let frameName = AppPaths.isDemo ? "MacMailMainWindowDemo" : "MacMailMainWindow"
        Self.discardCollapsedSavedFrame(frameName, min: window.minSize)
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) { window.center() }
        // Older builds could save a collapsed frame (the reading pane used to shrink the window to ~200 pt);
        // never restore anything smaller than the minimum size.
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.center()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(accountsChanged), name: .mailAccountsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foldersChanged), name: .mailFoldersChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(searchFiltersChanged(_:)), name: .mailSearchFiltersChanged, object: nil)
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

    /// Mirrors the list's filter bar so Save Search captures the full query (C-19). A filter change
    /// also reloads the results without a selection, so the preview must not keep showing a message
    /// the visible list no longer contains (C-14).
    @objc private func searchFiltersChanged(_ note: Notification) {
        liveFilters = (note.object as? SearchFilters) ?? SearchFilters()
        if case .search = list.source { preview.showEmpty(text: "No message selected") }
    }
    private var liveFilters = SearchFilters()

    // MARK: Navigation

    private func showSource(_ source: MailSource) {
        // The folder a search was started from can be deleted while searching; never restore a dead source.
        var target = source
        if case .folder(let id) = source, MailService.shared.store.folder(id) == nil { target = .unified }
        // Every source change selects the sidebar row, so ⌘1…9 and clearing the search keep the
        // highlight and the list in sync (C-15). A row that vanished meanwhile (the last second account
        // removed during a search, …) makes the sidebar fall back; the list follows the highlight.
        if let actual = sidebar.select(source: target), actual != target { target = actual }
        lastSource = target
        searchField?.stringValue = ""
        list.show(target)
        preview.showEmpty(text: "No message selected")
        syncSource(target)
        list.selectFirst()
    }

    private func syncSource(_ source: MailSource) {
        switch source {
        case .folder(let id): MailService.shared.sync(folderID: id)
        case .unified: MailService.shared.syncAllInboxes()
        case .unifiedRole(let role): MailService.shared.syncAll(role: role)
        case .flagged, .search: break
        }
    }

    private func selectionChanged(_ rows: [MessageRow], userInitiated: Bool) {
        if rows.isEmpty {
            preview.showEmpty(text: "No message selected")
        } else if let r = list.focusedRow {
            // Only an explicit open (click, j/k, Return) marks the message read; launch, folder-switch,
            // search and post-archive auto-selections show it without touching its flags.
            preview.show(messageID: r.id, markRead: userInitiated)
            prefetchNeighbors(of: r)
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
        syncSource(list.source)
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
        let save = NSMenuItem(title: "Save This Search…", action: #selector(saveCurrentSearch(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        let help = NSMenuItem(title: "Search syntax help", action: #selector(showSearchHelp(_:)), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        return menu
    }

    /// Keeps the current query — text plus filter-bar choices and scope — as a sidebar smart folder (F-29 / C-19).
    @objc func saveCurrentSearch(_ sender: Any?) {
        guard case .search = list.source,
              let q = searchField?.stringValue.trimmingCharacters(in: .whitespaces), !q.isEmpty,
              let w = window else { NSSound.beep(); return }
        var filters = liveFilters
        var scopeID: Int64?
        if filters.scope == .folder {
            if case .folder(let id) = lastSource, MailService.shared.store.folder(id) != nil { scopeID = id }
            else { filters.scope = .all } // the scoped folder is gone; the saved search covers all folders
        }
        let saved = SavedSearches.Entry.Saved(filters: filters, scopeFolderID: scopeID)
        let alert = NSAlert()
        alert.messageText = "Save search"
        alert.informativeText = "“\(q)” will appear under Saved Searches in the sidebar."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = q
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn { SavedSearches.add(name: field.stringValue, query: q, structured: saved) }
        }
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
        // reload(keepSelection: false) drops the selection silently; the preview must follow (C-14).
        preview.showEmpty(text: "No message selected")
        let work = DispatchWorkItem { [weak self] in self?.list.runServerSearch() }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Starts a search from a clean filter-bar context: selecting a saved search while another search is
    /// open must not inherit its filters or its "This folder" scope (C-19). The list only resets and
    /// reconfigures the bar when it was not already searching, so leave the search first.
    private func beginSearch(_ text: String, from origin: MailSource) {
        searchDebounce?.cancel()
        var target = origin
        if case .folder(let id) = origin, MailService.shared.store.folder(id) == nil { target = .unified }
        if case .search = list.source { list.show(target) }
        // The bar's "This folder" scope is resolved from lastSource, so a saved search's scope must become
        // the origin too — otherwise re-saving it would store a different folder (C-19).
        lastSource = target
        searchField?.stringValue = text
        sidebar.clearSelectionForSearch()
        list.showSearch(text, from: target)
        preview.showEmpty(text: "No message selected")
    }

    /// Same as typing in the search field (used by the demo hook).
    func runSearch(_ text: String) {
        beginSearch(text, from: lastSource)
        list.selectFirst(userInitiated: false)
        list.runServerSearch()
    }

    /// Runs a saved search, restoring the filter-bar state and scope it was saved with (C-19).
    func runSearch(_ entry: SavedSearches.Entry) {
        guard let saved = entry.structured else { runSearch(entry.query); return }
        var filters = saved.filters
        var origin = lastSource
        if let id = saved.scopeFolderID, MailService.shared.store.folder(id) != nil {
            origin = .folder(id)
        } else if filters.scope == .folder {
            filters.scope = .all // the scoped folder is gone; search everywhere
        }
        beginSearch(entry.query, from: origin)
        if let bar = searchFilterBar {
            bar.apply(filters) // updates the controls and re-runs the search with them
        } else {
            list.runServerSearch()
        }
        list.selectFirst(userInitiated: false)
    }

    /// The list's filter bar, found in the view hierarchy (it is owned by the list controller).
    private var searchFilterBar: SearchFilterBar? {
        var found: SearchFilterBar?
        func walk(_ v: NSView) {
            guard found == nil else { return }
            if let bar = v as? SearchFilterBar { found = bar; return }
            for s in v.subviews { walk(s) }
        }
        walk(list.view)
        return found
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
        preview.showEmpty(text: "No message selected")
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
        // One picker at a time, released when its sheet ends (B-25).
        folderPicker = FolderPicker(account: acct, onPick: { [weak self] path in
            self?.move(rows, to: .folder(path))
        }, onFinish: { [weak self] in self?.folderPicker = nil })
        folderPicker?.beginSheet(on: window)
    }

    /// Older builds could save a collapsed window (~150–200 pt tall), including as the "untiled" size macOS
    /// keeps for a tiled window. Such a frame is dropped once so the window opens at its default size.
    private static func discardCollapsedSavedFrame(_ name: String, min: NSSize) {
        let key = "NSWindow Frame \(name)"
        guard let saved = UserDefaults.standard.string(forKey: key) else { return }
        // "x y w h sx sy sw sh {json with untiledFrame "{{x, y}, {w, h}}"}"
        let parts = saved.split(separator: " ").prefix(4).compactMap { Double($0) }
        var sizes: [(Double, Double)] = parts.count == 4 ? [(parts[2], parts[3])] : []
        if let r = saved.range(of: #"untiledFrame":"\{\{[-0-9.]+, [-0-9.]+\}, \{([0-9.]+), ([0-9.]+)\}\}"#, options: .regularExpression) {
            let nums = saved[r].split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
            if nums.count >= 4 { sizes.append((nums[2], nums[3])) }
        }
        if sizes.contains(where: { $0.0 < Double(min.width) || $0.1 < Double(min.height) }) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // Reading-pane zoom (View menu) works wherever focus is in this window, not only inside the web view.
    @objc func zoomInReading(_ sender: Any?) { preview.zoomIn() }
    @objc func zoomOutReading(_ sender: Any?) { preview.zoomOut() }
    @objc func resetReadingZoom(_ sender: Any?) { preview.resetZoom() }

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
        // MailService.move posts a full data change; this reload already covers it (B-24 / O-18).
        // In search results the list refreshes from that notification instead (its .search branch),
        // so the skip flag must stay clear or it would swallow the next genuine change (C-12).
        if case .search = list.source {} else { list.skipNextFullReload = true }
        if let result = MailService.shared.move(rows, to: target) {
            if touchesSelection {
                list.reload(keepSelection: false)
                // The cursor move after archive/delete never marks the next message read.
                list.selectAfterRemoval(previousIndex: index, userInitiated: false)
            } else {
                list.reload(keepSelection: true)
            }
            if let undoID = result.undoID {
                // The server isn't told until the Undo window closes (F-08).
                toast.show(result.label, action: ("Undo", { [weak self] in
                    if MailService.shared.undo(undoID) { self?.list.reload(keepSelection: true) }
                }), duration: MailService.undoWindow)
            } else {
                toast.show(result.label)
            }
        } else {
            list.skipNextFullReload = false
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

    /// File ▸ Save As… (F-17): the original message as a standard .eml file that Mac Mail, Apple Mail,
    /// Outlook and Thunderbird all open.
    @objc func saveMessageAs(_ sender: Any?) {
        guard let row = list.focusedRow ?? targets.first else { NSSound.beep(); return }
        MessageActions.saveAs(row, in: window) { [weak self] s in self?.toast.show(s) }
    }

    @objc func printMessage(_ sender: Any?) {
        guard list.focusedRow != nil else { NSSound.beep(); return }
        preview.printMessage()
    }

    /// Mailbox ▸ Empty Trash / Empty Spam for the selected folder's account (F-10); from a unified
    /// view it covers that role in every account, with an aggregate count (C-04).
    @objc func emptyTrash(_ sender: Any?) { emptyRole(.trash) }
    @objc func emptySpam(_ sender: Any?) { emptyRole(.spam) }

    private func emptyRole(_ role: FolderRole) {
        if list.source.isUnified {
            let store = MailService.shared.store
            let folders = MailService.shared.accounts.compactMap { store.folder(account: $0.id, role: role) }
            guard !folders.isEmpty else { NSSound.beep(); return }
            confirmEmptyAll(folders, in: window)
            return
        }
        guard let f = emptyTarget(role) else { NSSound.beep(); return }
        SidebarViewController.confirmEmpty(f, in: window)
    }

    /// The folder Empty Trash / Empty Spam acts on for the current view (W-16).
    private func emptyTarget(_ role: FolderRole) -> Folder? {
        let account = sidebar.selectedFolder?.accountID ?? list.focusedRow?.accountID ?? MailService.shared.defaultAccount?.id
        guard let account else { return nil }
        return MailService.shared.store.folder(account: account, role: role)
    }

    /// Whether there is anything for Empty Trash / Empty Spam to act on in the current view (W-16).
    private func canEmpty(_ role: FolderRole) -> Bool {
        if list.source.isUnified {
            let store = MailService.shared.store
            return MailService.shared.accounts.contains { store.folder(account: $0.id, role: role) != nil }
        }
        return emptyTarget(role) != nil
    }

    /// One confirmation for emptying a role across every account (unified views — C-04).
    private func confirmEmptyAll(_ folders: [Folder], in window: NSWindow?) {
        guard let window, let role = folders.first?.role else { return }
        let store = MailService.shared.store
        let name = MessageListViewController.roleTitle(role)
        let n = folders.reduce(0) { $0 + store.messageCount(folderID: $1.id) }
        let alert = NSAlert()
        alert.messageText = "Empty \(name) in all accounts?"
        alert.informativeText = "\(n > 0 ? "\(n) cached message\(n == 1 ? "" : "s") and everything else" : "Everything") in \(folders.count) account\(folders.count == 1 ? "'s" : "s'") \(name) on the server will be deleted permanently. This can't be undone."
        alert.addButton(withTitle: "Empty All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            Task {
                var failure: String?
                for f in folders {
                    do { try await MailService.shared.emptyFolder(f) }
                    catch { failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; break }
                }
                if let failure {
                    self?.toast.show("Couldn't empty \(name): \(failure)")
                } else {
                    self?.toast.show("All \(name) emptied")
                }
            }
        }
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
        case #selector(saveMessageAs(_:)), #selector(printMessage(_:)):
            return list.focusedRow != nil
        case #selector(saveAttachments(_:)):
            // Nothing to save unless the open message actually has attachments (W-16).
            return preview.currentDetail?.structure?.attachments().isEmpty == false
        case #selector(emptyTrash(_:)):
            return canEmpty(.trash)
        case #selector(emptySpam(_:)):
            return canEmpty(.spam)
        case #selector(syncNow(_:)):
            return !MailService.shared.accounts.isEmpty
        case #selector(saveCurrentSearch(_:)):
            if case .search = list.source { return true }
            return false
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
    private let onFinish: () -> Void
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Folder]
    private var shown: [Folder] = []
    private var sheet: NSWindow?

    init(account: String, onPick: @escaping (String) -> Void, onFinish: @escaping () -> Void = {}) {
        self.onPick = onPick
        self.onFinish = onFinish
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
        onFinish()
    }

    @objc private func dismiss() {
        if let s = sheet { s.sheetParent?.endSheet(s) }
        sheet = nil
        onFinish()
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
