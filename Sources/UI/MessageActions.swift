import AppKit
import WebKit

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
                    // The window may have closed during the download; the failure is still shown.
                    a.present(in: window)
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
        alert.present(in: window) { resp in
            if resp == .alertFirstButtonReturn { then() }
        }
    }
}

extension NSAlert {
    /// Shows the alert as a sheet on `window`, or as an app-level alert when that window is gone,
    /// closed or hidden: a sheet on a window that isn't on screen is never seen, and its completion
    /// handler never runs.
    func present(in window: NSWindow?, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window, window.isVisible, !window.isMiniaturized {
            beginSheetModal(for: window) { completion?($0) }
        } else {
            let response = runModal()
            completion?(response)
        }
    }
}

extension WKWebView {
    /// Lets the window's own background show through until the page paints. WebKit has no public switch
    /// for this, only the long-standing `drawsBackground` key; it is used only while WebKit still
    /// answers to it, so a release that drops it costs a white flash, not an exception.
    func makeBackgroundTransparent() {
        guard responds(to: NSSelectorFromString("_setDrawsBackground:"))
            || responds(to: NSSelectorFromString("setDrawsBackground:")) else { return }
        setValue(false, forKey: "drawsBackground")
    }
}
