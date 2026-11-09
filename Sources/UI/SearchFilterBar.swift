import AppKit

/// Filters chosen in the search filter bar, merged into the typed query.
struct SearchFilters: Equatable {
    enum Scope: Equatable { case all, folder }
    var scope: Scope = .all
    var withinDays: Int?
    var unread = false
    var flagged = false
    var attachments = false
    var from = ""
    var to = ""
    var subject = ""

    var moreCount: Int { [from, to, subject].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count }

    func apply(to q: SearchQuery) -> SearchQuery {
        var q = q
        if unread { q.unread = true }
        if flagged { q.flagged = true }
        if attachments { q.hasAttachment = true }
        if let d = withinDays { q.withinDays = min(q.withinDays ?? d, d) }
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        let s = subject.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty { q.from.append(f) }
        if !t.isEmpty { q.to.append(t) }
        if !s.isEmpty { q.subject.append(s) }
        return q
    }
}

/// Outlook-style search filters shown under the list header while searching:
/// scope, date range, Unread / Flagged / Attachments, and From / To / Subject in a popover.
final class SearchFilterBar: NSView, NSPopoverDelegate {
    var onChange: ((SearchFilters) -> Void)?
    private(set) var filters = SearchFilters()

    private let scope = NSPopUpButton()
    private let date = NSPopUpButton()
    private let unread = NSButton(title: "Unread", target: nil, action: nil)
    private let flagged = NSButton(title: "Flagged", target: nil, action: nil)
    private let attachments = NSButton(title: "Attachments", target: nil, action: nil)
    private let more = NSButton(title: "More", target: nil, action: nil)
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private let subjectField = NSTextField()
    private var popover: NSPopover?
    private static let dayChoices: [(String, Int?)] = [("Any time", nil), ("Past week", 7), ("Past month", 30),
                                                       ("Past 6 months", 182), ("Past year", 365)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for p in [scope, date] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.target = self
            p.action = #selector(changed)
        }
        scope.addItems(withTitles: ["All folders", "This folder"])
        for (t, _) in Self.dayChoices { date.addItem(withTitle: t) }
        for b in [unread, flagged, attachments] {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
            b.action = #selector(changed)
        }
        unread.image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: nil)
        flagged.image = NSImage(systemSymbolName: "flag", accessibilityDescription: nil)
        attachments.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        for b in [unread, flagged, attachments] { b.imagePosition = .imageLeading }
        unread.toolTip = "Only unread (is:unread)"
        flagged.toolTip = "Only flagged / starred (is:starred)"
        attachments.toolTip = "Only with attachments (has:attachment)"
        for b in [more, clear] {
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
        }
        more.action = #selector(showMore)
        more.toolTip = "Filter by sender, recipient or subject"
        clear.action = #selector(clearAll)

        let row1 = NSStackView(views: [scope, date, NSView(), clear])
        row1.spacing = 6
        let row2 = NSStackView(views: [unread, flagged, attachments, more])
        row2.spacing = 6
        let stack = NSStackView(views: [row1, row2])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row1.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "This folder" only makes sense when the search started in a folder.
    func configure(folderName: String?) {
        scope.item(at: 1)?.title = folderName.map { "In \($0)" } ?? "This folder"
        scope.item(at: 1)?.isEnabled = folderName != nil
        scope.autoenablesItems = false
        if folderName == nil, filters.scope == .folder {
            filters.scope = .all
            scope.selectItem(at: 0)
        }
    }

    func reset() {
        filters = SearchFilters()
        scope.selectItem(at: 0)
        date.selectItem(at: 0)
        for b in [unread, flagged, attachments] { b.state = .off }
        fromField.stringValue = ""
        toField.stringValue = ""
        subjectField.stringValue = ""
        updateMoreTitle()
    }

    @objc private func changed() {
        filters.scope = scope.indexOfSelectedItem == 1 ? .folder : .all
        filters.withinDays = Self.dayChoices[max(0, date.indexOfSelectedItem)].1
        filters.unread = unread.state == .on
        filters.flagged = flagged.state == .on
        filters.attachments = attachments.state == .on
        onChange?(filters)
    }

    @objc private func clearAll() {
        reset()
        onChange?(filters)
    }

    private func updateMoreTitle() {
        let n = filters.moreCount
        more.title = n > 0 ? "More (\(n))" : "More"
        clear.isHidden = filters == SearchFilters()
    }

    override func layout() {
        super.layout()
        clear.isHidden = filters == SearchFilters()
    }

    // MARK: From / To / Subject popover

    private var didConfigureWidths = false

    @objc private func showMore() {
        let vc = NSViewController()
        let root = NSView()
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        for (f, p) in [(fromField, "Name or address"), (toField, "Name or address"), (subjectField, "Words in the subject")] {
            f.placeholderString = p
            f.target = self
            f.action = #selector(applyMore)
            // The fields outlive the popover: their width constraint is added once, not per opening (B-19).
            if !didConfigureWidths { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        }
        didConfigureWidths = true
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyMore))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let grid = NSGridView(views: [[label("From:"), fromField], [label("To:"), toField], [label("Subject:"), subjectField],
                                      [NSGridCell.emptyContentView, apply]])
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        vc.view = root
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.delegate = self
        popover = p
        p.show(relativeTo: more.bounds, of: more, preferredEdge: .maxY)
        root.window?.makeFirstResponder(fromField)
    }

    @objc private func applyMore() {
        filters.from = fromField.stringValue
        filters.to = toField.stringValue
        filters.subject = subjectField.stringValue
        updateMoreTitle()
        popover?.performClose(nil)
        onChange?(filters)
    }

    func popoverDidClose(_ notification: Notification) { popover = nil }
}
