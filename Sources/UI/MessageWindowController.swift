import AppKit

/// A message in its own window (double-click or Return in the list), like Outlook.
/// Reuses the reading pane; the toolbar and the usual shortcuts act on this message.
@MainActor
final class MessageWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation,
                                     NSToolbarItemValidation {
    private static var open: [Int64: MessageWindowController] = [:]

    /// Opens the message, or brings its existing window forward.
    static func show(messageID: Int64) {
        if let existing = open[messageID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = MessageWindowController(messageID: messageID)
        open[messageID] = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    static var openCount: Int { open.count }

    private let messageID: Int64
    private let preview = PreviewViewController()
    private let toast = ToastView()

    private init(messageID: Int64) {
        self.messageID = messageID
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 520, height: 420)
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        super.init(window: w)
        w.delegate = self
        w.contentViewController = preview
        w.setContentSize(NSSize(width: 860, height: 760))
        let toolbar = NSToolbar(identifier: "MacMailMessageWindow")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        w.toolbar = toolbar
        toast.translatesAutoresizingMaskIntoConstraints = false
        preview.view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: preview.view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: preview.view.bottomAnchor, constant: -18),
        ])
        preview.showToast = { [weak self] s in self?.toast.show(s) }
        preview.onEditDraft = { d in ComposeWindowController.open(.draft(d, MailService.shared.store.body(d.id))) }
        preview.show(messageID: messageID)
        let subject = MailService.shared.store.detail(messageID)?.subject ?? ""
        w.title = subject.isEmpty ? "(no subject)" : subject
        // Cascade from the last message window so several don't stack exactly.
        if let last = Self.open.values.compactMap({ $0.window }).last {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            w.center()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(dataChanged), name: .mailDataChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var row: MessageRow? { MailService.shared.store.rows(ids: [messageID]).first }

    /// Closes the window if the message left its folder (archived, deleted, moved here or elsewhere).
    @objc private func dataChanged() {
        if MailService.shared.store.detail(messageID) == nil { window?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        preview.releaseWebView()
        NotificationCenter.default.removeObserver(self)
        Self.open[messageID] = nil
    }

    // MARK: Actions (same selectors as the main window, so menu shortcuts work here too)

    @objc func reply(_ sender: Any?) { respond(.reply) }
    @objc func replyAll(_ sender: Any?) { respond(.replyAll) }
    @objc func forward(_ sender: Any?) { respond(.forward) }

    private enum Response { case reply, replyAll, forward }

    private func respond(_ kind: Response) {
        let store = MailService.shared.store
        guard let d = store.detail(messageID) else { return }
        let body = store.body(messageID)
        switch kind {
        case .reply: ComposeWindowController.open(.reply(d, body, all: false))
        case .replyAll: ComposeWindowController.open(.reply(d, body, all: true))
        case .forward: ComposeWindowController.open(.forward(d, body))
        }
    }

    @objc func toggleRead(_ sender: Any?) {
        guard let r = row else { return }
        MailService.shared.setFlag([r], flag: .seen, on: !r.flags.contains(.seen))
        toast.show(r.flags.contains(.seen) ? "Marked as read" : "Marked as unread")
    }

    @objc func toggleFlag(_ sender: Any?) {
        guard let r = row else { return }
        MailService.shared.setFlag([r], flag: .flagged, on: !r.flags.contains(.flagged))
    }

    @objc func archiveMessages(_ sender: Any?) { move(.archive) }
    @objc func toggleSpam(_ sender: Any?) {
        guard let r = row else { return }
        move(r.folderRole == .spam ? .inbox : .spam)
    }

    @objc func deleteMessages(_ sender: Any?) {
        guard let r = row else { return }
        if r.folderRole == .trash || r.folderRole == .spam, let w = window {
            let alert = NSAlert()
            alert.messageText = "Delete this message permanently?"
            alert.informativeText = "Messages deleted from Trash or Spam can't be recovered."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            alert.beginSheetModal(for: w) { [weak self] resp in
                if resp == .alertFirstButtonReturn { self?.move(.trash) }
            }
            return
        }
        move(.trash)
    }

    private func move(_ target: MailService.MoveTarget) {
        guard let r = row else { return }
        if let label = MailService.shared.move([r], to: target) {
            (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast(label)
            window?.close()
        } else {
            NSSound.beep()
        }
    }

    @objc func saveAttachments(_ sender: Any?) { preview.saveAllAttachments() }
    @objc func toggleLightBackground(_ sender: Any?) { preview.toggleLight() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { row != nil }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { row != nil }

    // MARK: Toolbar

    private enum TB {
        static let reply = NSToolbarItem.Identifier("m.reply")
        static let replyAll = NSToolbarItem.Identifier("m.replyAll")
        static let forward = NSToolbarItem.Identifier("m.forward")
        static let archive = NSToolbarItem.Identifier("m.archive")
        static let delete = NSToolbarItem.Identifier("m.delete")
        static let spam = NSToolbarItem.Identifier("m.spam")
        static let read = NSToolbarItem.Identifier("m.read")
        static let flag = NSToolbarItem.Identifier("m.flag")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.reply, TB.replyAll, TB.forward, .space, TB.archive, TB.delete, TB.spam, .flexibleSpace, TB.read, TB.flag]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case TB.reply: return button("Reply", "arrowshape.turn.up.left", #selector(reply(_:)))
        case TB.replyAll: return button("Reply All", "arrowshape.turn.up.left.2", #selector(replyAll(_:)))
        case TB.forward: return button("Forward", "arrowshape.turn.up.right", #selector(forward(_:)))
        case TB.archive: return button("Archive", "archivebox", #selector(archiveMessages(_:)))
        case TB.delete: return button("Delete", "trash", #selector(deleteMessages(_:)))
        case TB.spam: return button("Spam", "xmark.bin", #selector(toggleSpam(_:)))
        case TB.read: return button("Read/Unread", "envelope.badge", #selector(toggleRead(_:)))
        case TB.flag: return button("Flag", "flag", #selector(toggleFlag(_:)))
        default: return nil
        }
    }
}
