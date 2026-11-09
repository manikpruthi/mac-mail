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
    private let olderSpinner = NSProgressIndicator()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var allCaughtUp = false
    private var nodes: [ListNode] = []
    private(set) var source: MailSource = .unified
    private(set) var grouped = false
    private var searchRows: [MessageRow] = []
    /// Message ids the last finished server search contributed; re-merged on live refreshes so
    /// a cache-only refresh doesn't drop server hits (F-16).
    private var serverHitIDs: [Int64] = []
    private var serverSearching = false
    private var serverSearchError: String?
    private let filterBar = SearchFilterBar()
    private var filterCollapsed: NSLayoutConstraint!
    private var searchText = ""
    /// Folder the search started from ("This folder" scope); nil when started from All Inboxes.
    private var searchFolderID: Int64?
    private var searchToken = 0
    private var reloadScheduled = false
    /// Guards "Load older" button updates from a folder the user has since left (W-17).
    private var loadToken = 0
    /// Rows loaded per folder/unified view (O-05); "Show more" grows it before asking the server for older mail.
    private static let pageSize = 1000
    private var fetchLimit = MessageListViewController.pageSize
    private var moreLocalRows = false
    /// Message id → the top-level node that shows it, so flag changes patch O(k) rows (O-12).
    private var nodeIndex: [Int64: ListNode] = [:]
    /// The next `.all` data change was already handled by an explicit reload (B-24 / O-18).
    var skipNextFullReload = false

    var onSelectionChange: (([MessageRow], _ userInitiated: Bool) -> Void)?
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
        outline.rowHeight = Prefs.compactRows ? 50 : 68
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
        outline.onRedundantClick = { [weak self] in
            // Clicking the row that was auto-selected at launch: treat it as an explicit open.
            guard let self, let r = self.focusedRow else { return }
            self.onSelectionChange?([r], true)
        }
        scroll.documentView = outline

        olderButton.bezelStyle = .inline
        olderButton.controlSize = .small
        olderButton.target = self
        olderButton.action = #selector(loadOlder)
        olderSpinner.style = .spinning
        olderSpinner.controlSize = .small
        olderSpinner.isDisplayedWhenStopped = false
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isEditable = false
        emptyLabel.drawsBackground = false
        emptyLabel.isBordered = false
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.isHidden = true

        filterBar.isHidden = true
        filterBar.onChange = { [weak self] _ in self?.filtersChanged() }
        for v in [titleLabel, subtitle, groupToggle, filterBar, scroll, olderButton, olderSpinner, emptyLabel] as [NSView] {
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
            olderSpinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            olderSpinner.centerYAnchor.constraint(equalTo: olderButton.centerYAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        filterCollapsed = filterBar.heightAnchor.constraint(equalToConstant: 0)
        filterCollapsed.isActive = true
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(dataChanged(_:)), name: .mailDataChanged, object: nil)
    }

    // MARK: Loading

    func show(_ source: MailSource) {
        self.source = source
        allCaughtUp = false
        fetchLimit = Self.pageSize
        setFilterBarVisible(false)
        if case .search = source {} else { searchRows = []; serverHitIDs = [] }
        grouped = Prefs.groupByConversation(folderKey: folderKey)
        groupToggle.state = grouped ? .on : .off
        // A "Load older" still in flight belongs to the folder being left (W-17).
        loadToken += 1
        olderSpinner.stopAnimation(nil)
        reload(keepSelection: false)
        // An empty folder has no row 0 to scroll to (W-17).
        if outline.numberOfRows > 0 { outline.scrollRowToVisible(0) }
    }

    private var folderKey: String {
        switch source {
        case .unified: return "unified"
        case .unifiedRole(let r): return "unified." + r.rawValue
        case .flagged: return "unified.flagged"
        case .folder(let id): return "\(id)"
        case .search: return "search"
        }
    }

    @objc private func dataChanged(_ note: Notification) {
        let change = note.mailDataChange
        // An explicit reload may already cover this `.all` change (B-24 / O-18). Consume the marker before
        // the early returns below, so a change handled here can't swallow a later, unrelated one (C-12).
        let coveredByExplicitReload = skipNextFullReload
        skipNextFullReload = false
        // Read/flag changes: patch the affected rows in place, unless the view filters on those flags (C-11).
        if case .flags(let ids) = change {
            if updateFlagsInPlace(Set(ids)) { return }
            refreshSearchRows()
            reload(keepSelection: true)
            return
        }
        if case .search = source {
            // Moves/deletes/new mail must be reflected in the live results: refresh the local search
            // (cheap FTS query), keeping selection and expansion via reload(keepSelection:).
            refreshSearchRows()
            reload(keepSelection: true)
            return
        }
        if case .folder(let fid) = change, case .folder(let current) = source, fid != current { return }
        if case .all = change, coveredByExplicitReload { return }
        // Coalesce bursts (initial sync posts once per chunk).
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload(keepSelection: true)
        }
    }

    /// Re-runs the local search for the live results and re-merges the server hits. Search rows come
    /// from here, not from reload(), because a finished server search replaces them with its merged result.
    private func refreshSearchRows() {
        guard case .search = source else { return }
        var merged = MailService.shared.store.search(currentQuery, folderID: scopeFolderID)
            // Server hits are kept by id, so they must pass the live read/flag filter again.
            + MailService.shared.store.rows(ids: serverHitIDs).filter { flagsMatchSource($0.flags) }
        merged.sort { $0.date > $1.date }
        searchRows = Array(Self.dedupe(merged).prefix(2000))
    }

    /// Whether the current view's membership depends on read/flag state (All Flagged, is:unread, is:starred).
    private var viewDependsOnFlags: Bool {
        switch source {
        case .flagged:
            return true
        case .search:
            let q = currentQuery
            return q.unread || q.flagged
        default:
            return false
        }
    }

    private func flagsMatchSource(_ flags: MessageFlags) -> Bool {
        switch source {
        case .flagged:
            return flags.contains(.flagged)
        case .search:
            let q = currentQuery
            if q.unread && flags.contains(.seen) { return false }
            if q.flagged && !flags.contains(.flagged) { return false }
            return true
        default:
            return true
        }
    }

    /// Patches read/flag changes into the displayed rows. Returns false without touching anything when the
    /// view filters on flags and the change adds or removes a row, so the caller reloads instead (C-11).
    @discardableResult
    private func updateFlagsInPlace(_ ids: Set<Int64>) -> Bool {
        let t0 = Date()
        let fresh = MailService.shared.store.flags(ids: Array(ids))
        if viewDependsOnFlags {
            for id in ids {
                guard let f = fresh[id] else { continue }
                // Displayed (nodeIndex) and still matching, or hidden and still not matching: no reload.
                if flagsMatchSource(f) == (nodeIndex[id] != nil) { continue }
                return false
            }
        }
        var changedRows = IndexSet()
        // Only the touched messages, their thread header and (if expanded) their own child row (O-12).
        for id in ids {
            guard let node = nodeIndex[id], let f = fresh[id] else { continue }
            let child = node.children?.first { $0.row.id == id }
            if node.row.id == id {
                node.row.flags = f
            } else if let child {
                child.row.flags = f
            } else {
                continue
            }
            let r = outline.row(forItem: node)
            if r >= 0 { changedRows.insert(r) }
            if let child {
                let cr = outline.row(forItem: child)
                if cr >= 0 { changedRows.insert(cr) }
            }
        }
        if !changedRows.isEmpty { outline.reloadData(forRowIndexes: changedRows, columnIndexes: [0]) }
        updateSubtitle()
        Debug.log("flags patched in place (\(changedRows.count) rows): \(Debug.ms(since: t0))")
        return true
    }

    private func updateSubtitle() {
        var total = 0, unread = 0
        for n in nodes {
            if let children = n.children {
                total += children.count
                unread += children.reduce(0) { $0 + ($1.row.flags.contains(.seen) ? 0 : 1) }
            } else {
                total += 1
                if !n.row.flags.contains(.seen) { unread += 1 }
            }
        }
        var sub = "\(total) message\(total == 1 ? "" : "s")"
        if unread > 0 { sub += " · \(unread) unread" }
        if case .search = source {
            if serverSearching { sub += " · searching the server…" }
            else if let e = serverSearchError { sub += " · server search failed: \(e)" }
        }
        subtitle.stringValue = sub
    }

    /// The order to ask SQL for: nil for sender/subject, whose localized comparison happens in memory.
    private var sqlAscending: Bool? {
        switch Prefs.sortOrder {
        case .dateAsc: return true
        case .dateDesc: return false
        case .sender, .subject: return nil
        }
    }

    /// Upper bound for the widening below, so a duplicate-heavy unified view can't keep growing the probe.
    private static let maxProbeRows = 20_000

    /// The visible page plus whether the cache holds more. One extra row is fetched; duplicates are removed
    /// before counting (C-36), and the window grows when duplicate Gmail copies swallowed the probe row.
    private func page(_ fetch: (Int) -> [MessageRow]) -> (rows: [MessageRow], more: Bool) {
        var window = fetchLimit + 1
        while true {
            let raw = fetch(window)
            let unique = source.isUnified ? Self.dedupe(raw) : raw
            if unique.count > fetchLimit { return (Array(unique.prefix(fetchLimit)), true) }
            if raw.count < window || window >= Self.maxProbeRows { return (unique, false) }
            window = min(Self.maxProbeRows, window + raw.count - unique.count + 1)
        }
    }

    func reload(keepSelection: Bool) {
        let t0 = Date()
        defer { Debug.log("list reload (\(nodes.count) rows): \(Debug.ms(since: t0))") }
        let store = MailService.shared.store
        // Rebuilding the nodes changes item identity, so remember which threads were expanded and which
        // rows were selected, then restore them by id.
        var expandedThreads = Set<String>()
        var selectedThreads = Set<Int64>()
        var selectedMessages = Set<Int64>()
        var previousFocus: Int64?
        var previousCount = 0
        if keepSelection {
            previousFocus = focusedRow?.id
            previousCount = selectedRows.count
            for r in 0..<outline.numberOfRows {
                guard let n = outline.item(atRow: r) as? ListNode else { continue }
                // Keyed by conversation, not by the header message, which changes when newer mail arrives.
                if n.children != nil && outline.isItemExpanded(n) { expandedThreads.insert(Self.threadKey(n.row)) }
                // Only rows that were actually selected are restored (Y-r-list-1).
                guard outline.selectedRowIndexes.contains(r) else { continue }
                if outline.parent(forItem: n) != nil { selectedMessages.insert(n.row.id) }
                else { selectedThreads.insert(n.row.id) }
            }
        }
        var rows: [MessageRow]
        var more = false
        let ascending = sqlAscending ?? false
        switch source {
        case .unified:
            (rows, more) = page { store.listUnifiedRows(role: .inbox, limit: $0, ascending: ascending) }
            titleLabel.stringValue = "All Inboxes"
        case .unifiedRole(let role):
            (rows, more) = page { store.listUnifiedRows(role: role, limit: $0, ascending: ascending) }
            titleLabel.stringValue = "All " + Self.roleTitle(role)
        case .flagged:
            (rows, more) = page { store.listFlaggedRows(limit: $0, ascending: ascending) }
            titleLabel.stringValue = "All Flagged"
        case .folder(let id):
            (rows, more) = page { store.listRows(folderID: id, limit: $0, ascending: ascending) }
            titleLabel.stringValue = store.folder(id)?.name ?? "Folder"
        case .search(let q):
            titleLabel.stringValue = "Search: \(q)"
            // Search rows are already in memory (newest first): order them here, then page locally (C-36).
            let ordered = Prefs.sortOrder == .dateAsc ? Array(searchRows.reversed()) : searchRows
            (rows, more) = page { _ in ordered }
        }
        moreLocalRows = more
        func caughtUp(_ hiddenWhenNotCaughtUp: Bool) {
            if allCaughtUp {
                olderButton.isHidden = false
                olderButton.title = "All caught up"
                olderButton.isEnabled = false
            } else if moreLocalRows {
                olderButton.isHidden = false
                olderButton.title = "Show more messages"
                olderButton.isEnabled = true
            } else {
                olderButton.isHidden = hiddenWhenNotCaughtUp
                olderButton.title = "Load older messages"
                olderButton.isEnabled = true
            }
        }
        switch source {
        case .folder: caughtUp(rows.count < 50)
        default: caughtUp(true)
        }
        var fresh = grouped ? Self.group(rows) : rows.map { ListNode(row: $0) }
        fresh = Self.sorted(fresh, by: Prefs.sortOrder)
        // Same messages in the same order (most syncs and prefetches): patch the changed rows in place.
        // A full reloadData re-creates and re-lays-out every visible row, which showed as a stutter.
        if keepSelection, patchInPlace(with: fresh) {
            updateSubtitle()
            updateEmptyLabel(rows: rows)
            return
        }
        nodes = fresh
        nodeIndex = [:]
        for n in nodes {
            if let children = n.children {
                for c in children { nodeIndex[c.row.id] = n }
            } else {
                nodeIndex[n.row.id] = n
            }
        }
        updateSubtitle()
        updateEmptyLabel(rows: rows)
        // A folder/query switch must not keep a stale selection: reloadData can preserve row indexes, and
        // the caller then selects explicitly.
        if !keepSelection {
            suppressSelection = true
            outline.deselectAll(nil)
            suppressSelection = false
        }
        outline.reloadData()
        // Expand by conversation from the model, not a row range captured before rows were inserted (B-17).
        for n in nodes where n.children != nil && expandedThreads.contains(Self.threadKey(n.row)) {
            outline.expandItem(n)
        }
        if keepSelection {
            restoreSelection(threads: selectedThreads, messages: selectedMessages,
                             previousFocus: previousFocus, previousCount: previousCount)
        }
    }

    /// Restores the selection after a rebuild. A thread's child row wins over its header and the header is
    /// selected instead only when that child isn't visible, so one message is never selected twice (C-05).
    private func restoreSelection(threads: Set<Int64>, messages: Set<Int64>,
                                  previousFocus: Int64?, previousCount: Int) {
        guard !threads.isEmpty || !messages.isEmpty else { return }
        var idx = IndexSet()
        var covered = Set<Int64>() // top-level nodes that already show a selected row
        var matched = Set<Int64>() // selected message ids whose own row is visible
        let headerIDs = Set(nodes.map { $0.row.id })
        for r in 0..<outline.numberOfRows {
            guard let n = outline.item(atRow: r) as? ListNode else { continue }
            if outline.parent(forItem: n) != nil {
                // A selected header whose thread got a newer message is now that thread's child row.
                guard messages.contains(n.row.id) || (threads.contains(n.row.id) && !headerIDs.contains(n.row.id)) else { continue }
                idx.insert(r)
                matched.insert(n.row.id)
                if let top = nodeIndex[n.row.id] { covered.insert(top.row.id) }
            } else if threads.contains(n.row.id) {
                idx.insert(r)
                matched.insert(n.row.id)
                covered.insert(n.row.id)
            }
        }
        // A selected message whose own row isn't visible (collapsed thread) selects its thread header.
        for id in messages.union(threads) where !matched.contains(id) {
            guard let n = nodeIndex[id], !covered.contains(n.row.id) else { continue }
            let r = outline.row(forItem: n)
            if r >= 0 {
                idx.insert(r)
                covered.insert(n.row.id)
            }
        }
        suppressSelection = true
        outline.selectRowIndexes(idx, byExtendingSelection: false)
        suppressSelection = false
        // Everything that was selected is gone (moved or deleted elsewhere): the preview must not keep
        // showing it with no selection in the list (B-07).
        if idx.isEmpty {
            onSelectionChange?([], false)
        } else if focusedRow?.id != previousFocus || selectedRows.count != previousCount {
            // The selection survived but changed shape (a message left it, or a multi-selection narrowed):
            // the pane must not keep describing the old one.
            onSelectionChange?(selectedRows, false)
        }
    }

    /// Fields that can't be patched into an existing row: a change means the row must be re-created (B-35).
    private static func sameHeader(_ a: MessageRow, _ b: MessageRow) -> Bool {
        a.id == b.id && a.folderID == b.folderID && a.date == b.date && a.subject == b.subject
            && a.fromName == b.fromName && a.fromAddr == b.fromAddr && a.toList == b.toList
            && a.hasAttachments == b.hasAttachments && a.folderRole == b.folderRole
    }

    /// If `fresh` lists exactly the messages already shown (same headers, same thread shape, same order),
    /// copies the changed flags/snippets into the existing row objects and redraws only those rows.
    /// Returns false when the structure changed and a full reload is needed.
    private func patchInPlace(with fresh: [ListNode]) -> Bool {
        guard fresh.count == nodes.count, !nodes.isEmpty else { return false }
        var changed = IndexSet()
        for (old, new) in zip(nodes, fresh) {
            guard old.isThread == new.isThread, Self.sameHeader(old.row, new.row) else { return false }
            switch (old.children, new.children) {
            case (nil, nil):
                if old.row.flags != new.row.flags || old.row.snippet != new.row.snippet {
                    old.row.flags = new.row.flags
                    old.row.snippet = new.row.snippet
                    let r = outline.row(forItem: old)
                    if r >= 0 { changed.insert(r) }
                }
            case let (oldChildren?, newChildren?):
                guard oldChildren.count == newChildren.count,
                      !zip(oldChildren, newChildren).contains(where: { !Self.sameHeader($0.row, $1.row) })
                else { return false }
                var touched = false
                for (o, n) in zip(oldChildren, newChildren) where o.row.flags != n.row.flags || o.row.snippet != n.row.snippet {
                    o.row.flags = n.row.flags
                    o.row.snippet = n.row.snippet
                    touched = true
                    let cr = outline.row(forItem: o)
                    if cr >= 0 { changed.insert(cr) }
                }
                if touched {
                    let r = outline.row(forItem: old)
                    if r >= 0 { changed.insert(r) }
                }
            default:
                return false
            }
        }
        if !changed.isEmpty { outline.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
        return true
    }

    static func roleTitle(_ role: FolderRole) -> String {
        switch role {
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .archive: return "Archive"
        case .trash: return "Trash"
        case .spam: return "Spam"
        case .all: return "Mail"
        default: return role.rawValue.capitalized
        }
    }

    /// Applies the View ▸ Sort By order (F-24). The date orders are already applied by the query and keep
    /// each thread's children in the same direction, so only the localized sorts happen here (C-13).
    static func sorted(_ nodes: [ListNode], by order: Prefs.SortOrder) -> [ListNode] {
        switch order {
        case .dateDesc, .dateAsc: return nodes
        case .sender:
            return nodes.sorted {
                let a = $0.row.senderDisplay.localizedLowercase, b = $1.row.senderDisplay.localizedLowercase
                return a == b ? $0.row.date > $1.row.date : a < b
            }
        case .subject:
            return nodes.sorted {
                let a = MIME.normalizedSubject($0.row.subject).localizedLowercase
                let b = MIME.normalizedSubject($1.row.subject).localizedLowercase
                return a == b ? $0.row.date > $1.row.date : a < b
            }
        }
    }

    func applyViewOptions() {
        outline.rowHeight = Prefs.compactRows ? 50 : 68
        reload(keepSelection: true)
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
    }

    /// Contextual empty state: blank folders, zero search results and in-flight server searches.
    private func updateEmptyLabel(rows: [MessageRow]) {
        if case .search(let q) = source {
            if rows.isEmpty {
                emptyLabel.stringValue = serverSearching ? "Searching…" : "No results for “\(q)”"
                emptyLabel.isHidden = false
            } else {
                emptyLabel.isHidden = true
            }
        } else {
            emptyLabel.stringValue = "No messages"
            emptyLabel.isHidden = !rows.isEmpty
        }
    }

    static func group(_ rows: [MessageRow]) -> [ListNode] {
        var order: [String] = []
        var buckets: [String: [MessageRow]] = [:]
        for r in rows {
            let key = threadKey(r)
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]!.append(r)
        }
        return order.map { key in
            let list = buckets[key]!
            if list.count == 1 { return ListNode(row: list[0]) }
            return ListNode(row: list[0], children: list.map { ListNode(row: $0) })
        }
    }

    /// A conversation's identity, independent of which message currently heads it.
    static func threadKey(_ row: MessageRow) -> String { "\(row.accountID):\(row.threadID)" }

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
        // The superseded server search returns early without resetting this (B-18).
        serverSearching = false
        allCaughtUp = false
        // A "Load older" still in flight belongs to the folder being left (W-17).
        loadToken += 1
        olderSpinner.stopAnimation(nil)
        // A new query starts a new page window.
        fetchLimit = Self.pageSize
        // Any query change invalidates an in-flight server search for the older query.
        searchToken += 1
        serverHitIDs = []
        searchRows = Self.dedupe(MailService.shared.store.search(currentQuery, folderID: scopeFolderID))
        grouped = Prefs.groupByConversation(folderKey: "search")
        groupToggle.state = grouped ? .on : .off
        let hadSelection = !outline.selectedRowIndexes.isEmpty
        reload(keepSelection: false)
        // Nothing is open until the user picks a result: the preview must not keep showing a message the
        // new results no longer list (C-14).
        if hadSelection { onSelectionChange?([], false) }
    }

    private var filterWork: DispatchWorkItem?

    private func filtersChanged() {
        guard case .search = source else { return }
        // A filter change invalidates an in-flight server search for the old filters (B-18).
        searchToken += 1
        serverSearching = false
        serverHitIDs = []
        fetchLimit = Self.pageSize
        searchRows = Self.dedupe(MailService.shared.store.search(currentQuery, folderID: scopeFolderID))
        let hadSelection = !outline.selectedRowIndexes.isEmpty
        reload(keepSelection: false)
        if hadSelection { onSelectionChange?([], false) }
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
            // Every exit, including a superseded search, clears the "searching the server…" state (B-18).
            defer { if token == searchToken { serverSearching = false; updateSubtitle() } }
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
            serverHitIDs = ids
            // Local results are fetched with a wide window and capped only after merging, so older local
            // matches aren't dropped in favour of server hits (O-20).
            // Server hits come back by id, so they pass the same live read/flag filter as a re-merge:
            // a read message must not show under is:unread.
            var merged = store.search(q, folderID: scopeID, limit: 2000)
                + store.rows(ids: ids).filter { flagsMatchSource($0.flags) }
            merged.sort { $0.date > $1.date }
            searchRows = Array(Self.dedupe(merged).prefix(2000))
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
    /// Programmatic selections (launch, folder switch, data reloads) must not count as opening a message.
    private var selectionIsProgrammatic = false

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
        let userInitiated = !selectionIsProgrammatic
        selectionIsProgrammatic = false
        onSelectionChange?(selectedRows, userInitiated)
    }

    /// Selects the first row. Auto-selections pass userInitiated: false so the message isn't marked read.
    func selectFirst(userInitiated: Bool = false) {
        guard outline.numberOfRows > 0 else { onSelectionChange?([], userInitiated); return }
        selectionIsProgrammatic = !userInitiated
        outline.selectRowIndexes([0], byExtendingSelection: false)
        selectionIsProgrammatic = false
    }

    /// After a move/delete: keep the cursor near where it was. The demo/benchmark hooks use the
    /// user-initiated default; the real cursor move after archive/delete passes false (never marks read).
    func selectAfterRemoval(previousIndex: Int, userInitiated: Bool = true) {
        let n = outline.numberOfRows
        guard n > 0 else { onSelectionChange?([], userInitiated); return }
        selectionIsProgrammatic = !userInitiated
        outline.selectRowIndexes([min(previousIndex, n - 1)], byExtendingSelection: false)
        selectionIsProgrammatic = false
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
        if moreLocalRows {
            // More is already cached: page it in before going to the server (O-05). Works for search too (C-36).
            fetchLimit += Self.pageSize
            reload(keepSelection: true)
            return
        }
        guard case .folder(let id) = source, let f = MailService.shared.store.folder(id),
              let engine = MailService.shared.engine(f.accountID) else { return }
        loadToken += 1
        let token = loadToken
        olderButton.isHidden = true
        olderSpinner.startAnimation(nil)
        Task {
            let n = await engine.loadOlder(folderID: id)
            // The user may have switched folders meanwhile: that folder's button state is not ours to set (W-17).
            guard token == loadToken, case .folder(let current) = source, current == id else { return }
            olderSpinner.stopAnimation(nil)
            olderButton.isHidden = false
            if n == 0 {
                allCaughtUp = true
                olderButton.title = "All caught up"
                olderButton.isEnabled = false
                showToast?("All caught up")
            } else {
                olderButton.title = "Load older messages"
                olderButton.isEnabled = true
            }
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
        // An empty folder has no row 0 to select (B-16).
        guard outline.numberOfRows > 0 else { return }
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
        cell.configure(node, isChild: isChild, showAccount: source.isUnified && MailService.shared.accounts.count > 1)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        outlineView.parent(forItem: item) != nil ? 50 : (Prefs.compactRows ? 50 : 68)
    }

    // MARK: Swipe actions

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        guard let node = outline.item(atRow: row) as? ListNode else { return [] }
        // Same rule as the context menu: a collapsed thread acts on all its messages, an expanded header
        // only on the message the row shows.
        let rows = node.isThread && !outline.isItemExpanded(node) ? node.allRows : [node.row]
        let app = NSApp.delegate as? AppDelegate
        func action(_ title: String, _ color: NSColor, _ symbol: String, _ handler: @escaping () -> Void) -> NSTableViewRowAction {
            let a = NSTableViewRowAction(style: .regular, title: title) { _, _ in handler() }
            a.backgroundColor = color
            a.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return a
        }
        switch edge {
        case .trailing:
            return [action("Archive", .systemGray, "archivebox") { app?.mainWindow?.moveRows(rows, to: .archive) }]
        case .leading:
            let anyUnread = rows.contains { !$0.flags.contains(.seen) }
            let anyUnflagged = rows.contains { !$0.flags.contains(.flagged) }
            let read = action(anyUnread ? "Read" : "Unread", .systemBlue, anyUnread ? "envelope.open" : "envelope.badge") {
                MailService.shared.setFlag(rows, flag: .seen, on: anyUnread)
            }
            let flag = action(anyUnflagged ? "Flag" : "Unflag", .systemOrange, "flag") {
                MailService.shared.setFlag(rows, flag: .flagged, on: anyUnflagged)
            }
            return [read, flag]
        @unknown default:
            return []
        }
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
    /// Clicking the already-selected row (e.g. the one auto-selected at launch) — an explicit open.
    var onRedundantClick: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let before = selectedRowIndexes
        // A click on the disclosure triangle expands or collapses a thread; it is not an open.
        let disclosure = row >= 0 ? frameOfOutlineCell(atRow: row) : .zero
        super.mouseDown(with: event)
        // Only a plain click that leaves an already-selected row selected is an explicit open: anything that
        // changes the selection is already reported by its notification, and a modified click must not mark
        // a message read just because it adjusted the selection.
        guard row >= 0, before.contains(row), selectedRowIndexes == before,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              disclosure.isEmpty || !disclosure.contains(point) else { return }
        onRedundantClick?()
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
    private let answered = NSImageView(image: NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: "Replied") ?? NSImage())
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
        answered.contentTintColor = .secondaryLabelColor
        answered.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        count.textColor = .secondaryLabelColor
        icons.orientation = .horizontal
        icons.spacing = 4
        for v in [count, clip, flag, answered] { icons.addArrangedSubview(v) }
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
        // allRows builds an array for threads; compute it once per configure (O-13).
        let rows = node.allRows
        let unread = rows.contains { !$0.flags.contains(.seen) }
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
        clip.isHidden = !rows.contains { $0.hasAttachments }
        flag.isHidden = !rows.contains { $0.flags.contains(.flagged) }
        answered.isHidden = !rows.contains { $0.flags.contains(.answered) }
        // Compact density: sender + subject only (F-24).
        if Prefs.compactRows && !isChild { snippet.isHidden = true }
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
        updateAccessibility(node: node, who: who, unread: unread)
    }

    /// One combined label for VoiceOver: state first, then who, what and when.
    private func updateAccessibility(node: ListNode, who: String, unread: Bool) {
        var parts: [String] = []
        if unread { parts.append("Unread") }
        if !flag.isHidden { parts.append("Flagged") }
        if !answered.isHidden { parts.append("Replied") }
        if !clip.isHidden { parts.append("Attachment") }
        if node.isThread, let n = node.children?.count { parts.append("\(n) messages") }
        parts.append("from \(who)")
        parts.append(subject.stringValue)
        parts.append(date.stringValue)
        setAccessibilityLabel(parts.joined(separator: ", "))
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
            answered.contentTintColor = .alternateSelectedControlTextColor
        } else {
            sender.textColor = .labelColor
            date.textColor = isUnread ? .controlAccentColor : .secondaryLabelColor
            snippet.textColor = .secondaryLabelColor
            count.textColor = .secondaryLabelColor
            answered.contentTintColor = .secondaryLabelColor
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
