import AppKit
import UniformTypeIdentifiers

/// New message / reply / forward / draft editing. Files dropped on the window, passed from Mac Explorer's
/// "Email with Mac Mail", or opened with the app arrive as attachments.
@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSTokenFieldDelegate, NSTextViewDelegate {
    enum Kind {
        case new
        case files([URL])
        case mailto(to: [EmailAddress], cc: [EmailAddress], subject: String, body: String)
        case reply(MessageDetail, StoredBody?, all: Bool)
        case forward(MessageDetail, StoredBody?)
        case draft(MessageDetail, StoredBody?)
    }

    private static var open: Set<ComposeWindowController> = []
    static var openCount: Int { open.count }

    static func open(_ kind: Kind) {
        guard !MailService.shared.accounts.isEmpty else {
            (NSApp.delegate as? AppDelegate)?.showSettings(addAccount: true)
            return
        }
        let c = ComposeWindowController(kind: kind)
        open.insert(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private let kind: Kind
    private let fromPopup = NSPopUpButton()
    private let toField = NSTokenField()
    private let ccField = NSTokenField()
    private let bccField = NSTokenField()
    private let subjectField = NSTextField()
    private let textView = ComposeTextView()
    private let attachmentStack = NSStackView()
    private let attachmentScroll = NSScrollView()
    private let includeOriginal = NSButton(checkboxWithTitle: "Include original message", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var attachments: [OutgoingAttachment] = []
    private var quotedHTML = ""
    private var quotedText = ""
    private var inReplyTo: String?
    private var references: String?
    private var replyRow: MessageRow?
    private var draftRow: MessageRow?
    private var dirty = false
    private var sentOrDiscarded = false
    private var pendingSendID: UUID?
    private var tempDirs: [URL] = []

    init(kind: Kind) {
        self.kind = kind
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "New Message"
        w.minSize = NSSize(width: 520, height: 420)
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self
        w.isReleasedWhenClosed = false
        buildUI()
        prefill()
        w.center()
        w.cascadeTopLeft(from: NSPoint(x: w.frame.minX + CGFloat(Self.open.count * 22), y: w.frame.maxY - CGFloat(Self.open.count * 22)))
        dirty = false
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let service = MailService.shared
        for a in service.accounts {
            fromPopup.addItem(withTitle: a.displayName.isEmpty ? a.email : "\(a.displayName) <\(a.email)>")
            fromPopup.lastItem?.representedObject = a.id
        }
        if let def = service.defaultAccount, let idx = service.accounts.firstIndex(where: { $0.id == def.id }) {
            fromPopup.selectItem(at: idx)
        }
        fromPopup.target = self
        fromPopup.action = #selector(fromChanged)

        for f in [toField, ccField, bccField] {
            f.delegate = self
            f.tokenizingCharacterSet = CharacterSet(charactersIn: ",;")
            f.completionDelay = 0.05
            f.placeholderString = ""
            f.font = .systemFont(ofSize: 13)
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.cell?.wraps = false
            f.cell?.isScrollable = true
        }
        subjectField.isBordered = false
        subjectField.drawsBackground = false
        subjectField.focusRingType = .none
        subjectField.font = .systemFont(ofSize: 13)
        subjectField.target = self
        subjectField.delegate = self

        func row(_ title: String, _ field: NSView) -> [NSView] {
            let l = NSTextField(labelWithString: title)
            l.alignment = .right
            l.textColor = .secondaryLabelColor
            l.font = .systemFont(ofSize: 13)
            return [l, field]
        }
        let grid = NSGridView(views: [row("From:", fromPopup), row("To:", toField), row("Cc:", ccField),
                                      row("Bcc:", bccField), row("Subject:", subjectField)])
        grid.column(at: 0).width = 64
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        grid.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.usesFindBar = true
        textView.delegate = self
        textView.onDropFiles = { [weak self] urls in self?.addAttachments(urls) }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        attachmentStack.orientation = .horizontal
        attachmentStack.spacing = 6
        attachmentStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(attachmentStack)
        attachmentScroll.documentView = doc
        attachmentScroll.drawsBackground = false
        attachmentScroll.hasHorizontalScroller = true
        attachmentScroll.autohidesScrollers = true
        attachmentScroll.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.isHidden = true

        includeOriginal.state = .on
        includeOriginal.isHidden = true
        includeOriginal.controlSize = .small
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let send = NSButton(title: "Send", target: self, action: #selector(send(_:)))
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        send.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)
        send.imagePosition = .imageLeading
        send.toolTip = "Send (⌘↩)"
        let attach = NSButton(title: "Attach…", target: self, action: #selector(attachFiles(_:)))
        attach.bezelStyle = .rounded
        attach.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attach.imagePosition = .imageLeading
        attach.toolTip = "Attach files (⇧⌘A)"

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator
        for v in [grid, sep1, scroll, attachmentScroll, sep2, includeOriginal, status, attach, send] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sep1.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            sep1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep1.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep1.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: attachmentScroll.topAnchor),
            attachmentScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            attachmentScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            attachmentScroll.bottomAnchor.constraint(equalTo: sep2.topAnchor),
            attachmentScroll.heightAnchor.constraint(equalToConstant: 52),
            attachmentStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            attachmentStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            attachmentStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            doc.trailingAnchor.constraint(equalTo: attachmentStack.trailingAnchor),
            doc.heightAnchor.constraint(equalTo: attachmentScroll.contentView.heightAnchor),
            sep2.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep2.bottomAnchor.constraint(equalTo: send.topAnchor, constant: -10),
            send.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            send.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            attach.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -8),
            attach.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            includeOriginal.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            includeOriginal.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: includeOriginal.trailingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: attach.leadingAnchor, constant: -8),
        ])
        attachmentScroll.isHidden = true
        attachmentHeight = attachmentScroll.constraints.first { $0.firstAttribute == .height }
        attachmentHeight?.constant = 0
    }

    private var attachmentHeight: NSLayoutConstraint?

    private var account: Account? {
        guard let id = fromPopup.selectedItem?.representedObject as? String else { return MailService.shared.defaultAccount }
        return MailService.shared.account(id)
    }

    // MARK: Prefill

    private func prefill() {
        switch kind {
        case .new:
            setBody("", signature: true)
            window?.makeFirstResponder(toField)
        case .files(let urls):
            setBody("", signature: true)
            addAttachments(urls)
            if urls.count == 1 { subjectField.stringValue = urls[0].lastPathComponent }
            window?.makeFirstResponder(toField)
        case .mailto(let to, let cc, let subject, let body):
            toField.objectValue = to.map { $0.full }
            ccField.objectValue = cc.map { $0.full }
            subjectField.stringValue = subject
            setBody(body, signature: true)
            window?.makeFirstResponder(to.isEmpty ? toField : textView)
        case .reply(let d, let body, let all):
            selectAccount(d.accountID)
            let me = Set(MailService.shared.accounts.map { $0.email.lowercased() })
            let replyTo = MIME.parseAddresses(d.replyTo)
            var to = replyTo.isEmpty ? [d.from] : replyTo
            var cc: [EmailAddress] = []
            if d.folderRole == .sent { to = MIME.parseAddresses(d.toList) }
            if all {
                let others = (MIME.parseAddresses(d.toList) + MIME.parseAddresses(d.ccList))
                    .filter { !me.contains($0.email.lowercased()) && !to.map({ $0.email.lowercased() }).contains($0.email.lowercased()) }
                cc = others
            }
            toField.objectValue = to.map { $0.full }
            ccField.objectValue = cc.map { $0.full }
            subjectField.stringValue = Self.prefixed("Re: ", d.subject)
            inReplyTo = d.messageIDHeader
            references = (d.references + " " + d.messageIDHeader).trimmingCharacters(in: .whitespaces)
            replyRow = MailService.shared.store.rows(ids: [d.id]).first
            setQuote(d, body, header: "On \(Self.quoteDate(d.date)), \(d.from.full) wrote:")
            setBody("", signature: true)
            window?.title = "Re: " + d.subject
            window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        case .forward(let d, let body):
            selectAccount(d.accountID)
            subjectField.stringValue = Self.prefixed("Fwd: ", d.subject)
            let header = """
            ---------- Forwarded message ---------
            From: \(d.from.full)
            Date: \(Self.quoteDate(d.date))
            Subject: \(d.subject)
            To: \(d.toList)
            """
            setQuote(d, body, header: header, blockquote: false)
            setBody("", signature: true)
            window?.title = "Fwd: " + d.subject
            fetchForwardAttachments(d)
            window?.makeFirstResponder(toField)
        case .draft(let d, let body):
            selectAccount(d.accountID)
            toField.objectValue = MIME.parseAddresses(d.toList).map { $0.full }
            ccField.objectValue = MIME.parseAddresses(d.ccList).map { $0.full }
            subjectField.stringValue = d.subject
            draftRow = MailService.shared.store.rows(ids: [d.id]).first
            if let html = body?.html, let data = html.data(using: .utf8),
               let attr = NSAttributedString(html: data, documentAttributes: nil) {
                textView.textStorage?.setAttributedString(attr)
            } else {
                setBody(body?.text ?? "", signature: false)
            }
            window?.title = d.subject.isEmpty ? "Draft" : d.subject
            window?.makeFirstResponder(textView)
        }
    }

    private func selectAccount(_ id: String) {
        if let idx = fromPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) { fromPopup.selectItem(at: idx) }
    }

    private static func prefixed(_ p: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(p.lowercased()) ? subject : p + subject
    }

    private static func quoteDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func setBody(_ text: String, signature: Bool) {
        var s = text
        if signature, let sig = account?.signature, !sig.isEmpty { s += "\n\n" + sig }
        textView.string = ""
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
    }

    private func setQuote(_ d: MessageDetail, _ body: StoredBody?, header: String, blockquote: Bool = true) {
        let originalHTML: String
        if let h = body?.html, !h.isEmpty {
            originalHTML = HTMLPrep.bodyInner(h)
        } else {
            originalHTML = "<div style=\"white-space:pre-wrap\">" + MIME.escapeHTML(body?.text ?? "") + "</div>"
        }
        let headerHTML = MIME.escapeHTML(header).replacingOccurrences(of: "\n", with: "<br>")
        if blockquote {
            quotedHTML = "<div class=\"gmail_quote\"><div>\(headerHTML)</div><blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(originalHTML)</blockquote></div>"
        } else {
            quotedHTML = "<div class=\"gmail_quote\"><div>\(headerHTML)</div><br>\(originalHTML)</div>"
        }
        let plain = body?.text ?? MIME.plainText(fromHTML: body?.html ?? "", limit: 200_000)
        quotedText = header + "\n" + (blockquote ? plain.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") : plain)
        includeOriginal.isHidden = false
        includeOriginal.title = blockquote ? "Include original message" : "Include forwarded message"
    }

    private func fetchForwardAttachments(_ d: MessageDetail) {
        guard let parts = d.structure?.attachments(), !parts.isEmpty, let engine = MailService.shared.engine(d.accountID) else { return }
        status.stringValue = "Fetching \(parts.count) attachment\(parts.count == 1 ? "" : "s")…"
        let dir = AppPaths.tempDir("forward")
        tempDirs.append(dir)
        Task {
            var used = Set<String>()
            var urls: [URL] = []
            for p in parts {
                let url = dir.appendingPathComponent(PreviewViewController.uniqueName(p.suggestedFilename, used: &used))
                do {
                    try await engine.download(messageID: d.id, part: p, to: url)
                    urls.append(url)
                } catch {
                    status.stringValue = "Couldn't fetch \(p.suggestedFilename)"
                }
            }
            addAttachments(urls)
            if status.stringValue.hasPrefix("Fetching") { status.stringValue = "" }
        }
    }

    // MARK: Attachments

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                zipFolder(url)
                continue
            }
            attachments.append(OutgoingAttachment(url: url, filename: url.lastPathComponent, mimeType: MessageBuilder.mimeType(for: url)))
        }
        refreshAttachments()
        Debug.log("compose attachments: \(attachments.map { $0.filename })")
        dirty = true
    }

    /// Folders are zipped (with the system's ditto) and attached as one .zip.
    private func zipFolder(_ url: URL) {
        let dir = AppPaths.tempDir("zip")
        tempDirs.append(dir)
        let dest = dir.appendingPathComponent(url.lastPathComponent + ".zip")
        status.stringValue = "Zipping \(url.lastPathComponent)…"
        Task {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, dest.path]
            try? p.run()
            while p.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            status.stringValue = ""
            if p.terminationStatus == 0 { addAttachments([dest]) } else { status.stringValue = "Couldn't zip \(url.lastPathComponent)" }
        }
    }

    private func refreshAttachments() {
        attachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var total = 0
        for (i, a) in attachments.enumerated() {
            let size = (try? a.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            let b = NSButton(title: "\(a.filename)  ·  \(MIME.formatSize(size))  ✕", target: self, action: #selector(removeAttachment(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            b.toolTip = "Remove \(a.filename)"
            let type = UTType(filenameExtension: a.url.pathExtension) ?? .data
            let icon = NSWorkspace.shared.icon(for: type)
            icon.size = NSSize(width: 16, height: 16)
            b.image = icon
            b.imagePosition = .imageLeading
            attachmentStack.addArrangedSubview(b)
        }
        attachmentScroll.isHidden = attachments.isEmpty
        attachmentHeight?.constant = attachments.isEmpty ? 0 : 40
        if total > 25 * 1_048_576 {
            status.stringValue = "Attachments total \(MIME.formatSize(total)) — Gmail's limit is 25 MB."
            status.textColor = .systemRed
        } else if status.textColor == .systemRed {
            status.stringValue = ""
            status.textColor = .secondaryLabelColor
        }
    }

    @objc private func removeAttachment(_ sender: NSButton) {
        guard sender.tag < attachments.count else { return }
        attachments.remove(at: sender.tag)
        refreshAttachments()
    }

    @objc func attachFiles(_ sender: Any?) {
        guard let w = window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.beginSheetModal(for: w) { [weak self] resp in
            if resp == .OK { self?.addAttachments(panel.urls) }
        }
    }

    // MARK: Building the message

    private func addresses(_ field: NSTokenField) -> [EmailAddress] {
        let tokens = (field.objectValue as? [Any])?.compactMap { $0 as? String } ?? [field.stringValue]
        return tokens.flatMap { MIME.parseAddresses($0) }.filter { $0.email.contains("@") }
    }

    private func buildMessage() -> OutgoingMessage? {
        guard let account else { return nil }
        let attr = textView.attributedString()
        var html = RichText.html(from: attr)
        var text = attr.string
        if includeOriginal.state == .on, !quotedHTML.isEmpty {
            html += "<br>" + quotedHTML
            text += "\n\n" + quotedText
        }
        let doc = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\(html)</body></html>"
        return OutgoingMessage(from: account.fromHeader, to: addresses(toField), cc: addresses(ccField), bcc: addresses(bccField),
                               subject: subjectField.stringValue, textBody: text, htmlBody: doc,
                               inReplyTo: inReplyTo, references: references, attachments: attachments)
    }

    @objc func send(_ sender: Any?) {
        guard let message = buildMessage(), let account else { return }
        if message.allRecipients.isEmpty {
            let a = NSAlert()
            a.messageText = "Add at least one recipient."
            a.beginSheetModal(for: window!, completionHandler: nil)
            return
        }
        let invalid = (addresses(toField) + addresses(ccField) + addresses(bccField)).filter { !$0.email.contains(".") }
        if !invalid.isEmpty {
            let a = NSAlert()
            a.messageText = "Check the address \(invalid[0].email)."
            a.beginSheetModal(for: window!, completionHandler: nil)
            return
        }
        if message.subject.trimmingCharacters(in: .whitespaces).isEmpty {
            let a = NSAlert()
            a.messageText = "Send without a subject?"
            a.addButton(withTitle: "Send")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: window!) { [weak self] r in if r == .alertFirstButtonReturn { self?.queueSend(message, account: account) } }
            return
        }
        queueSend(message, account: account)
    }

    private func queueSend(_ message: OutgoingMessage, account: Account) {
        sentOrDiscarded = true
        window?.orderOut(nil)
        let main = (NSApp.delegate as? AppDelegate)?.mainWindow
        let pending = MailService.PendingSend(accountID: account.id, message: message, replyTo: replyRow,
                                              draftToDelete: draftRow, composer: self)
        let id = MailService.shared.queueSend(pending) { [weak self] error in
            guard let self else { return }
            if let error {
                self.sentOrDiscarded = false
                self.status.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status.textColor = .systemRed
                self.showWindow(nil)
                let a = NSAlert()
                a.messageText = "Your message wasn't sent"
                a.informativeText = self.status.stringValue
                a.beginSheetModal(for: self.window!, completionHandler: nil)
            } else {
                main?.showToast("Message sent")
                self.cleanUpAndForget()
            }
        }
        pendingSendID = id
        let seconds = Prefs.undoSendSeconds
        main?.showToast("Sending…", action: ("Undo", { [weak self] in self?.undoSend() }), duration: Double(max(seconds, 1)))
    }

    private func undoSend() {
        guard let id = pendingSendID, MailService.shared.cancelSend(id) else { return }
        pendingSendID = nil
        sentOrDiscarded = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Closing / drafts

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty, !sentOrDiscarded else { return true }
        let a = NSAlert()
        a.messageText = "Save this message as a draft?"
        a.informativeText = "Drafts are saved to the account's Drafts folder."
        a.addButton(withTitle: "Save Draft")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: sender) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn: self.saveDraftAndClose()
            case .alertSecondButtonReturn:
                self.sentOrDiscarded = true
                self.window?.close()
            default: break
            }
        }
        return false
    }

    private func saveDraftAndClose() {
        guard let message = buildMessage(), let account, let engine = MailService.shared.engine(account.id) else { return }
        sentOrDiscarded = true
        window?.orderOut(nil)
        let old = draftRow
        Task {
            do {
                try await engine.saveDraft(try MessageBuilder.build(message))
                if let old { engine.queue(kind: "expunge", rows: [old]); MailService.shared.store.deleteMessages(ids: [old.id]) }
                (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Draft saved")
                cleanUpAndForget()
            } catch {
                sentOrDiscarded = false
                showWindow(nil)
                let a = NSAlert(error: error)
                a.messageText = "Couldn't save the draft"
                a.beginSheetModal(for: window!, completionHandler: nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if pendingSendID == nil { cleanUpAndForget() }
    }

    private func cleanUpAndForget() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
        window?.orderOut(nil)
        Self.open.remove(self)
        if NSApp.windows.allSatisfy({ !$0.isVisible }) && (NSApp.delegate as? AppDelegate)?.mainWindow?.window?.isVisible != true {
            NSApp.terminate(nil)
        }
    }

    @objc private func fromChanged() { dirty = true }

    func textDidChange(_ notification: Notification) { dirty = true }

    // MARK: Address completion

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        guard substring.count >= 1 else { return nil }
        selectedIndex?.pointee = -1
        return MailService.shared.store.contacts(matching: substring).map { $0.full }
    }

    func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
        guard let s = representedObject as? String, let a = MIME.parseAddress(s) else { return representedObject as? String }
        return a.name.isEmpty ? a.email : a.name
    }

    func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
        representedObject as? String
    }

    func controlTextDidChange(_ obj: Notification) { dirty = true }
}

extension ComposeWindowController: NSTextFieldDelegate {}

/// Body text view that turns dropped files into attachments instead of inline images.
final class ComposeTextView: NSTextView {
    var onDropFiles: (([URL]) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingEntered(sender)
    }
}

/// Minimal attributed-string → HTML for outgoing mail: bold, italic, underline, strike, links, colours and sizes.
enum RichText {
    static func html(from attr: NSAttributedString) -> String {
        var out = ""
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttributes(in: full) { attrs, range, _ in
            var text = MIME.escapeHTML((attr.string as NSString).substring(with: range))
            text = text.replacingOccurrences(of: "\n", with: "<br>")
            var styles: [String] = []
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { text = "<b>\(text)</b>" }
                if traits.contains(.italic) { text = "<i>\(text)</i>" }
                if abs(font.pointSize - 14) > 0.5 { styles.append("font-size:\(Int(font.pointSize))px") }
                if let family = font.familyName, !family.hasPrefix(".") && family != NSFont.systemFont(ofSize: 14).familyName {
                    styles.append("font-family:'\(family)'")
                }
            }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { text = "<u>\(text)</u>" }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { text = "<s>\(text)</s>" }
            if let c = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), c != NSColor.textColor.usingColorSpace(.sRGB) {
                let hex = String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
                if hex != "#000000" && hex != "#ffffff" && hex != "#dfdfdf" && hex != "#e5e5e5" { styles.append("color:\(hex)") }
            }
            if !styles.isEmpty { text = "<span style=\"\(styles.joined(separator: ";"))\">\(text)</span>" }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                text = "<a href=\"\(MIME.escapeHTML(href))\">\(text)</a>"
            }
            out += text
        }
        return out
    }
}
