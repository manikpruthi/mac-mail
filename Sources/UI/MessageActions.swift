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
            do {
                guard let engine = MailService.shared.engine(row.accountID) else { throw NetError.server("Account not found") }
                open(kind, d, try await engine.loadBody(messageID: row.id))
            } catch {
                // Never open a reply silently missing the original (B-22): say why, and let the user choose.
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showProgress("Couldn't load the original message")
                let alert = NSAlert()
                alert.messageText = "The original message couldn't be loaded"
                alert.informativeText = msg
                alert.addButton(withTitle: kind == .forward ? "Forward Without Text" : "Reply Without Original")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { open(kind, d, nil) }
            }
        }
    }

    /// Save As (F-17): fetches the original RFC 822 source and writes it as .eml, which opens in Mac Mail
    /// (offline, see EMLWindowController) and in any other mail app.
    static func saveAs(_ row: MessageRow, in window: NSWindow?, toast: @escaping (String) -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        let base = row.subject.isEmpty ? "Message" : String(row.subject.prefix(80))
        panel.nameFieldStringValue = (BodyPart.safeFilename(base) ?? "Message") + ".eml"
        panel.allowedContentTypes = [EMLDocument.type]
        panel.canCreateDirectories = true
        panel.message = "Saved messages open in Mac Mail, Apple Mail, Outlook and Thunderbird."
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            toast("Saving \(url.lastPathComponent)…")
            Task {
                do {
                    guard let engine = MailService.shared.engine(row.accountID) else { throw NetError.server("Account not found") }
                    let data = try await engine.rawMessage(messageID: row.id)
                    // Write off the main thread: a large message must not stall the UI.
                    try await Task.detached { try data.write(to: url, options: .atomic) }.value
                    toast("Saved \(url.lastPathComponent)")
                } catch {
                    let a = NSAlert(error: error)
                    a.messageText = "Couldn't save the message"
                    a.beginSheetModal(for: window, completionHandler: nil)
                }
            }
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
