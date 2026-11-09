import AppKit

/// Reply / forward / delete behavior shared by the main window and the message window,
/// so both validate and load the same way.
@MainActor
enum MessageActions {
    enum Response { case reply, replyAll, forward }

    /// Opens the composer for `row`, fetching the original body from the server first when it
    /// isn't cached (reply quotes it, forward needs it entirely). Shows progress and keeps the
    /// UI responsive while the body loads.
    static func respond(_ kind: Response, row: MessageRow, showProgress: @escaping (String) -> Void) {
        guard let d = MailService.shared.store.detail(row.id) else { NSSound.beep(); return }
        if let body = MailService.shared.store.body(row.id) {
            open(kind, d, body)
            return
        }
        showProgress("Loading message…")
        Task {
            let body = try? await MailService.shared.engine(row.accountID)?.loadBody(messageID: row.id)
            open(kind, d, body)
        }
    }

    private static func open(_ kind: Response, _ d: MessageDetail, _ body: StoredBody?) {
        switch kind {
        case .reply: ComposeWindowController.open(.reply(d, body, all: false))
        case .replyAll: ComposeWindowController.open(.reply(d, body, all: true))
        case .forward: ComposeWindowController.open(.forward(d, body))
        }
    }

    /// Permanent-delete confirmation for rows already in Trash or Spam.
    static func confirmPermanentDelete(_ rows: [MessageRow], in window: NSWindow?, then: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = rows.count == 1 ? "Delete this message permanently?" : "Delete \(rows.count) messages permanently?"
        alert.informativeText = "Messages deleted from Trash or Spam can't be recovered."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertFirstButtonReturn { then() }
        }
    }
}
