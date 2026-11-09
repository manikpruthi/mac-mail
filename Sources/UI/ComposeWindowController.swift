import AppKit
import UniformTypeIdentifiers
import WebKit

/// New message / reply / forward / draft editing. Files dropped on the window, passed from Mac Explorer's
/// "Email with Mac Mail", or opened with the app arrive as attachments.
@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSTokenFieldDelegate, NSTextViewDelegate,
                                      WKNavigationDelegate, WKUIDelegate {
    enum Kind {
        case new
        case files([URL])
        case mailto(to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress], subject: String, body: String,
                    inReplyTo: String?, references: String?)
        case reply(MessageDetail, StoredBody?, all: Bool)
        case forward(MessageDetail, StoredBody?)
        case draft(MessageDetail, StoredBody?)
        /// A composer recovered from its autosave after a crash or forced quit (F-06).
        case restored(ComposerAutosave)
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
    private let formatBar = FormatBar()
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
    /// Autosave identity (F-06): one file per composer, removed when it's sent, saved or discarded.
    private var autosaveID = UUID().uuidString
    private var autosaveWork: DispatchWorkItem?
    /// Attachment sizes, read once when added (O-24).
    private var attachmentSizes: [URL: Int] = [:]
    /// Attachments the autosave listed but that no longer exist on disk; Send asks before dropping them (C-21).
    private var missingAttachments: [String] = []
    /// The account a reply/draft was started from when it has since been removed. Send waits for the user to
    /// pick a From account instead of quietly using another one (C-27).
    private var missingAccountID: String?
    /// Autosave encoding and file I/O run here, never on the main thread. Serial, so a later save can never be
    /// overtaken by an earlier one and a discard can't be undone by a write that was still in flight.
    private let autosaveQueue = DispatchQueue(label: "MacMail.compose.autosave", qos: .utility)

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
        if case .restored = kind { dirty = true }
    }

    // MARK: Autosave and crash recovery (F-06)

    /// Re-opens composers whose autosave survived a crash or forced quit. Called once at launch.
    static func restoreAutosaved() {
        // Decoding autosaves can mean reading megabytes of inline images; keep it off the main thread and
        // re-open the windows on it once the records are known.
        DispatchQueue.global(qos: .utility).async {
            let records = ComposerAutosave.all()
            DispatchQueue.main.async {
                for record in records {
                    // Only into the account it was written for: a fallback would send from the wrong address (C-27).
                    guard MailService.shared.account(record.accountID) != nil else { continue }
                    open(.restored(record))
                }
            }
        }
    }

    private func scheduleAutosave() {
        guard !sentOrDiscarded else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosaveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func autosaveNow() {
        // While a draft's body or images are still loading the editor holds placeholder text, so saving then
        // would record a body that can never get its images back; pipelineEnded schedules the save instead.
        guard dirty, !sentOrDiscarded, pipelineTasks == 0, !waitingForDraftBody, let account else { return }
        commitEditing()
        // The text storage is main-actor bound: only snapshot the string (and field values) here; encoding
        // the RTFD — every inline image — and measuring widths run on the autosave queue.
        let attr = textView.attributedString()
        let base = ComposerAutosave(
            // While the original account is gone, record it rather than the fallback the From popup shows:
            // restoring into another account would silently send from the wrong address (C-27).
            id: autosaveID, accountID: missingAccountID ?? account.id,
            to: (toField.objectValue as? [String]) ?? [], cc: (ccField.objectValue as? [String]) ?? [],
            bcc: (bccField.objectValue as? [String]) ?? [], subject: subjectField.stringValue,
            bodyRTF: nil, attachments: attachments.map { $0.url.path }, inReplyTo: inReplyTo, references: references,
            quotedHTML: quotedHTML, quotedText: quotedText, includeOriginal: includeOriginal.state == .on,
            draftRowID: draftRow?.id, replyRowID: replyRow?.id, saved: Date())
        autosaveQueue.async {
            // RTFD keeps inline images; old autosaves are plain RTF and still load. A body that can't be
            // encoded would replace a good autosave with an empty one, so keep the previous file (C-21).
            let rtf = InlineImage.rtfd(attr)
            if attr.length > 0, rtf == nil { return }
            var record = base
            record.bodyRTF = rtf
            record.imageWidths = InlineImage.widths(attr).map { Double($0) }
            record.write()
        }
    }

    private func discardAutosave() {
        autosaveWork?.cancel()
        let id = autosaveID
        // Same serial queue as the writes, so a discard always lands after any autosave still being written.
        autosaveQueue.async { ComposerAutosave.remove(id) }
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
        // Standard scroll-view recipe: without it the text sits low and the hidden quote pane reserves space (BUG-34).
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
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
        formatBar.textView = textView
        let sep2 = NSBox(); sep2.boxType = .separator
        // Header rows keep their natural height; the editor/original split takes the rest of the window.
        for f in [toField, ccField, bccField, subjectField] as [NSView] {
            f.setContentHuggingPriority(.required, for: .vertical)
            f.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        grid.setContentHuggingPriority(.required, for: .vertical)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        // Editor on top, the original message (read-only, as it looked) underneath; drag the divider to resize.
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(quotePane)
        quotePane.isHidden = true
        includeOriginal.target = self
        includeOriginal.action = #selector(includeOriginalChanged)
        for v in [grid, sep1, formatBar, split, attachmentScroll, sep2, includeOriginal, status, attach, send] as [NSView] {
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
            formatBar.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 5),
            formatBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            formatBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: formatBar.bottomAnchor, constant: 5),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: attachmentScroll.topAnchor),
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
        sendButton = send
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
        case .mailto(let to, let cc, let bcc, let subject, let body, let inReplyTo, let references):
            toField.objectValue = to.map { $0.full }
            ccField.objectValue = cc.map { $0.full }
            bccField.objectValue = bcc.map { $0.full }
            subjectField.stringValue = subject
            if let inReplyTo, !inReplyTo.isEmpty { self.inReplyTo = inReplyTo }
            if let references, !references.isEmpty { self.references = references }
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
            window?.title = subjectField.stringValue
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
            window?.title = subjectField.stringValue
            fetchMessageAttachments(d)
            window?.makeFirstResponder(toField)
        case .draft(let d, let body):
            selectAccount(d.accountID)
            toField.objectValue = MIME.parseAddresses(d.toList).map { $0.full }
            ccField.objectValue = MIME.parseAddresses(d.ccList).map { $0.full }
            bccField.objectValue = MIME.parseAddresses(d.bcc).map { $0.full }
            subjectField.stringValue = d.subject
            inReplyTo = d.inReplyTo.isEmpty ? nil : d.inReplyTo
            references = d.references.isEmpty ? nil : d.references
            draftRow = MailService.shared.store.rows(ids: [d.id]).first
            loadDraftBody(d, body)
            // The saved body already ends with this account's signature; track it so changing From replaces
            // it instead of appending a second one (B-20).
            currentSignature = MailService.shared.account(d.accountID)?.signature
            // A saved draft's attachments come back too; Send/Save wait until they're downloaded, and the
            // old draft is only replaced once the new one (with them) is on the server (B-01).
            fetchMessageAttachments(d)
            window?.title = d.subject.isEmpty ? "Draft" : d.subject
            window?.makeFirstResponder(textView)
        case .restored(let r):
            autosaveID = r.id
            selectAccount(r.accountID)
            toField.objectValue = r.to
            ccField.objectValue = r.cc
            bccField.objectValue = r.bcc
            subjectField.stringValue = r.subject
            inReplyTo = r.inReplyTo
            references = r.references
            if let rtf = r.bodyRTF,
               let attr = NSAttributedString(rtfd: rtf, documentAttributes: nil) ?? NSAttributedString(rtf: rtf, documentAttributes: nil) {
                textView.textStorage?.setAttributedString(attr)
                if let storage = textView.textStorage {
                    InlineImage.normalize(storage, maxWidth: 640, widths: r.imageWidths?.map { CGFloat($0) })
                }
            }
            // The recovered body already ends with this account's signature (see the draft case above).
            currentSignature = MailService.shared.account(r.accountID)?.signature
            let urls = r.attachments.map { URL(fileURLWithPath: $0) }
            missingAttachments = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }.map { $0.lastPathComponent }
            addAttachments(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
            if !r.quotedHTML.isEmpty {
                quotedHTML = r.quotedHTML
                quotedText = r.quotedText
                includeOriginal.isHidden = false
                includeOriginal.state = r.includeOriginal ? .on : .off
            }
            draftRow = r.draftRowID.flatMap { MailService.shared.store.rows(ids: [$0]).first }
            replyRow = r.replyRowID.flatMap { MailService.shared.store.rows(ids: [$0]).first }
            status.stringValue = missingAttachments.isEmpty
                ? "Recovered unsent message from \(Self.quoteDate(r.saved))"
                : "Recovered from \(Self.quoteDate(r.saved)) — \(missingAttachments.count) attachment\(missingAttachments.count == 1 ? "" : "s") missing"
            if !missingAttachments.isEmpty { status.textColor = .systemRed }
            window?.title = r.subject.isEmpty ? "Recovered Message" : r.subject
            window?.makeFirstResponder(textView)
        }
    }

    private func selectAccount(_ id: String) {
        if let idx = fromPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            fromPopup.selectItem(at: idx)
            missingAccountID = nil
        } else {
            // Never fall back to the default account for a message that belongs to another one (C-27).
            missingAccountID = id
        }
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
        var sig: String?
        if signature, let sg = account?.signature, !sg.isEmpty { s += "\n\n" + sg; sig = sg }
        currentSignature = sig
        textView.string = ""
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]))
    }

    /// The signature currently appended to the body, so changing the From account can swap it (BUG-20).
    private var currentSignature: String?
    /// True while a draft's body is still being fetched: Send/Save wait for it rather than writing a blank.
    private var waitingForDraftBody = false

    /// Changing the From account replaces the old signature with the new account's one — wherever it is,
    /// even when text was typed after it (B-20). Only when the old signature was edited away is the new
    /// one appended instead.
    private func swapSignature() {
        let newSig = account?.signature ?? ""
        guard newSig != currentSignature else { return }
        let storage = textView.textStorage
        let text = textView.string as NSString
        var replaced = false
        if let old = currentSignature, !old.isEmpty {
            let r = text.range(of: "\n\n" + old, options: .backwards)
            if r.location != NSNotFound {
                let replacement = newSig.isEmpty ? "" : "\n\n" + newSig
                // The body changes like typed text, so Undo has to cover it too.
                if textView.shouldChangeText(in: r, replacementString: replacement) {
                    storage?.replaceCharacters(in: r, with: replacement)
                    textView.didChangeText()
                    replaced = true
                }
            }
        }
        if !replaced, !newSig.isEmpty {
            let len = (textView.string as NSString).length
            let replacement = "\n\n" + newSig
            if textView.shouldChangeText(in: NSRange(location: len, length: 0), replacementString: replacement) {
                storage?.replaceCharacters(in: NSRange(location: len, length: 0), with: replacement)
                textView.didChangeText()
                replaced = true
            }
        }
        // Keep the old signature recorded when the change couldn't be applied, so it's retried next time.
        if replaced || newSig.isEmpty { currentSignature = newSig }
    }

    /// Alerts attach to the composer as a sheet; if the window is gone (an async error arriving late), they
    /// fall back to an app-modal alert instead of crashing on a nil window (B-21).
    private func present(_ alert: NSAlert, then: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let w = window, w.isVisible || w.isMiniaturized {
            alert.beginSheetModal(for: w, completionHandler: then)
        } else {
            let r = alert.runModal()
            then?(r)
        }
    }

    private func alert(_ text: String, info: String? = nil) {
        let a = NSAlert()
        a.messageText = text
        if let info { a.informativeText = info }
        present(a)
    }

    /// Fills the editor with a draft's cached body; when it isn't cached yet, fetches it instead of
    /// opening a blank editor that a later save would turn into a real empty draft (V2-04).
    private func loadDraftBody(_ d: MessageDetail, _ body: StoredBody?, fetched: Bool = false) {
        let hasContent = !(body?.html ?? "").isEmpty || !(body?.text ?? "").isEmpty
        // One fetch only: a draft that really is empty opens empty instead of re-fetching forever (B-02).
        guard hasContent || fetched else {
            waitingForDraftBody = true
            status.stringValue = "Loading draft…"
            let id = d.id
            Task { [weak self] in
                do {
                    guard let engine = MailService.shared.engine(d.accountID) else { throw NetError.server("Account unavailable") }
                    let fetched = try await engine.loadBody(messageID: id)
                    guard let self, !self.sentOrDiscarded else { return }
                    self.status.stringValue = ""
                    self.loadDraftBody(d, fetched, fetched: true)
                } catch {
                    guard let self, !self.sentOrDiscarded else { return }
                    self.waitingForDraftBody = false
                    self.status.stringValue = "Couldn't load the draft's body"
                }
            }
            return
        }
        waitingForDraftBody = false
        if let html = body?.html {
            let (tokenized, cids) = InlineImage.tokenizeCIDImages(html)
            if let data = tokenized.data(using: .utf8), let attr = NSAttributedString(html: data, documentAttributes: nil) {
                textView.textStorage?.setAttributedString(attr)
            }
            if !cids.isEmpty { loadDraftInlineImages(d, cids) }
        } else {
            setBody(body?.text ?? "", signature: false)
        }
        // Edits made while the body was loading weren't autosaved (the editor still held placeholders).
        if dirty { scheduleAutosave() }
    }

    /// Downloads a reopened draft's inline images, then swaps them for their placeholder tokens in one
    /// undoable edit. An image that can't be fetched leaves a visible notice behind instead of vanishing.
    private func loadDraftInlineImages(_ d: MessageDetail, _ cids: [(cid: String, width: CGFloat?)]) {
        guard let engine = MailService.shared.engine(d.accountID) else {
            replaceInlineTokens(cids, with: [:])
            return
        }
        let dir = AppPaths.tempDir("draft-inline")
        tempDirs.append(dir)
        pipelineBegan()
        let task = Task { [weak self] in
            defer { self?.pipelineEnded() }
            var images: [Int: NSTextAttachment] = [:]
            for (n, item) in cids.enumerated() {
                guard !Task.isCancelled, let self else { return }
                if let part = d.structure?.part(withContentID: item.cid) {
                    let url = dir.appendingPathComponent("\(n)")
                    if (try? await engine.download(messageID: d.id, part: part, to: url)) != nil,
                       let att = InlineImage.attachment(file: url, maxWidth: self.textView.inlineImageWidth, width: item.width) {
                        images[n] = att
                    }
                }
            }
            guard !Task.isCancelled, let self, !self.sentOrDiscarded else { return }
            self.replaceInlineTokens(cids, with: images)
        }
        zipTasks.append(task)
    }

    /// Replaces the draft image tokens with their images (or with a visible notice when one couldn't be
    /// fetched) as a single undoable edit (C-22).
    private func replaceInlineTokens(_ cids: [(cid: String, width: CGFloat?)], with images: [Int: NSTextAttachment]) {
        guard let storage = textView.textStorage else { return }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        for n in cids.indices {
            let r = (storage.string as NSString).range(of: InlineImage.token(n))
            guard r.location != NSNotFound else { continue }
            let attributes = storage.attributes(at: r.location, effectiveRange: nil)
            let replacement = images[n].map { NSAttributedString(attachment: $0) }
                ?? NSAttributedString(string: "[Image unavailable]", attributes: attributes)
            guard textView.shouldChangeText(in: r, replacementString: replacement.string) else { continue }
            storage.replaceCharacters(in: r, with: replacement)
            textView.didChangeText()
        }
        removeInlineTokens()
        undo?.endUndoGrouping()
    }

    /// Removes any token still left over, undoably.
    private func removeInlineTokens() {
        guard let storage = textView.textStorage else { return }
        let ranges = InlineImage.tokenRanges(in: storage.string)
        guard !ranges.isEmpty else { return }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        for r in ranges.reversed() where NSMaxRange(r) <= storage.length {
            guard textView.shouldChangeText(in: r, replacementString: "") else { continue }
            storage.deleteCharacters(in: r)
            textView.didChangeText()
        }
        undo?.endUndoGrouping()
    }

    // MARK: Original message pane

    private let split = NSSplitView()
    private let quotePane = NSView()
    private var quoteWeb: WKWebView?
    private let quoteLoader = ImageLoader()
    /// What the quote pane was built from, so it can be rebuilt after the web view was released (BUG-28).
    private var quoteSource: (detail: MessageDetail, body: StoredBody?, header: String, blockquote: Bool)?

    /// Shows the message being replied to / forwarded under the editor, rendered like the reading pane
    /// (same image limits, remote content blocked, scripts off). It's what gets quoted when you send.
    private func showOriginal(_ d: MessageDetail, _ body: StoredBody?, header: String) {
        let label = NSTextField(labelWithString: header)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 6
        label.lineBreakMode = .byTruncatingTail
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(quoteLoader, forURLScheme: "lm")
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(WKUserScript(source: DarkReader.script, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: .defaultClient))
        if let list = PreviewViewController.ruleList { config.userContentController.add(list) }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        // Same image policy as the reading pane, including the per-sender choice (SEC-A10); Spam never auto-loads.
        let spam = d.folderRole == .spam
        let senderPref = MailService.shared.store.pref("img:" + d.from.email.lowercased())
        let autoLoad = !spam && (senderPref == "always" || (!Prefs.askBeforeImages && senderPref != "ask" && senderPref != "never"))
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        quoteWeb = web
        // The regex passes over a large original run off the main thread (O-10).
        Task { [weak self, weak web] in
            let prepared = await HTMLPrep.prepareOffMain(html: body?.html, text: body?.text, page: 1)
            guard let self, let web, self.quoteWeb === web else { return }
            self.quoteLoader.page = ImagePage(generation: 1, messageID: d.id, accountID: d.accountID, prepared: prepared,
                                              autoLoad: autoLoad, ignoreLimits: senderPref == "always")
            self.quoteLoader.page?.dark = dark
            web.loadHTMLString(prepared.html, baseURL: URL(string: "lm://quote/\(d.id)/"))
        }
        let sep = NSBox()
        sep.boxType = .separator
        for v in [sep, label, web] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            quotePane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: quotePane.topAnchor),
            sep.leadingAnchor.constraint(equalTo: quotePane.leadingAnchor, constant: 14),
            sep.trailingAnchor.constraint(equalTo: quotePane.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: quotePane.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: quotePane.trailingAnchor, constant: -18),
            web.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            web.leadingAnchor.constraint(equalTo: quotePane.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: quotePane.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: quotePane.bottomAnchor),
        ])
        quotePane.isHidden = false
        // Give the editor the top third; the original fills the rest.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition(max(160, self.split.bounds.height * 0.34), ofDividerAt: 0)
        }
    }

    // MARK: Quote-pane navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            ExternalNavigation.open(url)
            return
        }
        if url.scheme == "lm" || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { ExternalNavigation.open(url) }
        return nil
    }

    private var view: NSView { window?.contentView ?? NSView() }

    @objc private func includeOriginalChanged() {
        quotePane.isHidden = includeOriginal.state != .on
        split.adjustSubviews()
        if quotePane.isHidden, split.bounds.height > 0 { split.setPosition(split.bounds.height, ofDividerAt: 0) }
        dirty = true
    }

    private func setQuote(_ d: MessageDetail, _ body: StoredBody?, header: String, blockquote: Bool = true) {
        showOriginal(d, body, header: header)
        quoteSource = (d, body, header, blockquote)
        let originalHTML: String
        if let h = body?.html, !h.isEmpty {
            // Sanitised exactly like the reading pane: no scripts, forms, iframes or tracking pixels
            // may ride along into the outgoing message.
            originalHTML = HTMLPrep.quoteSanitized(HTMLPrep.bodyInner(h))
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

    /// Downloads a message's attachments (forward, or a saved draft being reopened). Send stays disabled
    /// until the pipeline drains, and the task is cancelled with the window (V2-09/V2-10).
    private func fetchMessageAttachments(_ d: MessageDetail) {
        guard let parts = d.structure?.attachments(), !parts.isEmpty, let engine = MailService.shared.engine(d.accountID) else { return }
        status.stringValue = "Fetching \(parts.count) attachment\(parts.count == 1 ? "" : "s")…"
        let dir = AppPaths.tempDir("forward")
        tempDirs.append(dir)
        pipelineBegan()
        fetchTask = Task { [weak self] in
            defer { self?.pipelineEnded() }
            var used = Set<String>()
            var urls: [URL] = []
            for p in parts {
                if Task.isCancelled { return }
                let url = dir.appendingPathComponent(PreviewViewController.uniqueName(p.suggestedFilename, used: &used))
                do {
                    try await engine.download(messageID: d.id, part: p, to: url)
                    urls.append(url)
                } catch {
                    self?.status.stringValue = "Couldn't fetch \(p.suggestedFilename)"
                }
            }
            guard !Task.isCancelled else { return }
            self?.addAttachments(urls)
            if self?.status.stringValue.hasPrefix("Fetching") == true { self?.status.stringValue = "" }
        }
    }

    /// Attachment downloads and folder zips still running; Send is disabled while this is non-zero.
    private var pipelineTasks = 0
    private var fetchTask: Task<Void, Never>?
    private var zipTasks: [Task<Void, Never>] = []
    private var sendButton: NSButton?

    private func pipelineBegan() {
        pipelineTasks += 1
        sendButton?.isEnabled = false
    }

    private func pipelineEnded() {
        pipelineTasks = max(0, pipelineTasks - 1)
        if pipelineTasks == 0 {
            sendButton?.isEnabled = true
            // An autosave skipped while the pipeline was busy gets its chance now that the body is complete.
            if dirty { scheduleAutosave() }
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
            attachmentSizes[url] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        if !missingAttachments.isEmpty {
            // Reattaching a file the restore flagged as missing clears its warning.
            let names = Set(urls.map { $0.standardizedFileURL.lastPathComponent })
            missingAttachments.removeAll { names.contains($0) }
            refreshMissingStatus()
        }
        refreshAttachments()
        Debug.log("compose attachments: \(attachments.map { $0.filename })")
        dirty = true
        scheduleAutosave()
    }

    /// Clears the red "attachments missing" status line once no missing attachment remains.
    private func refreshMissingStatus() {
        guard missingAttachments.isEmpty, status.textColor == .systemRed else { return }
        status.stringValue = ""
        status.textColor = .secondaryLabelColor
    }

    /// Folders are zipped (with the system's ditto) and attached as one .zip.
    private func zipFolder(_ url: URL) {
        let dir = AppPaths.tempDir("zip")
        tempDirs.append(dir)
        let dest = dir.appendingPathComponent(url.lastPathComponent + ".zip")
        status.stringValue = "Zipping \(url.lastPathComponent)…"
        pipelineBegan()
        let task = Task { [weak self] in
            defer { self?.pipelineEnded() }
            do {
                try await AttachmentZip.zip(directory: url, to: dest, keepParent: true)
                guard !Task.isCancelled else { return }
                self?.status.stringValue = ""
                self?.addAttachments([dest])
            } catch {
                self?.status.stringValue = "Couldn't zip \(url.lastPathComponent)"
            }
        }
        zipTasks.append(task)
    }

    private func refreshAttachments() {
        attachmentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var total = 0
        for (i, a) in attachments.enumerated() {
            let size = attachmentSizes[a.url] ?? 0
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
        let removed = attachments.remove(at: sender.tag)
        attachmentSizes[removed.url] = nil
        refreshAttachments()
        dirty = true
        scheduleAutosave()
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
        commitEditing()
        guard let account else { return nil }
        // An autosave written while a draft's images were still downloading can leave tokens in the body; a
        // literal "[inline-image-N]" must never be sent (C-22).
        let attr = NSMutableAttributedString(attributedString: textView.attributedString())
        for r in InlineImage.tokenRanges(in: attr.string).reversed() where NSMaxRange(r) <= attr.length {
            attr.deleteCharacters(in: r)
        }
        // Inline images (pasted or dropped into the body) go out as cid: parts in multipart/related. A file
        // pasted into the body as rich text is sent as an ordinary attachment, not dropped (C-03).
        var inline: [OutgoingAttachment] = []
        var inlineIDs = Set<String>()
        var html = RichText.html(from: attr) { att in
            guard att is InlineImageAttachment, let part = self.inlinePart(for: att), let cid = part.contentID else { return nil }
            if inlineIDs.insert(cid).inserted { inline.append(part) }
            return cid
        }
        var bodyFiles: [OutgoingAttachment] = []
        var seenBodyAttachments = Set<ObjectIdentifier>()
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            guard let att = value as? NSTextAttachment, !(att is InlineImageAttachment),
                  seenBodyAttachments.insert(ObjectIdentifier(att)).inserted,
                  let part = self.filePart(for: att) else { return }
            bodyFiles.append(part)
        }
        var text = attr.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        if includeOriginal.state == .on, !quotedHTML.isEmpty {
            html += "<br>" + quotedHTML
            text += "\n\n" + quotedText
        }
        let doc = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\(html)</body></html>"
        return OutgoingMessage(from: account.fromHeader, to: addresses(toField), cc: addresses(ccField), bcc: addresses(bccField),
                               subject: subjectField.stringValue, textBody: text, htmlBody: doc,
                               inReplyTo: inReplyTo, references: references, attachments: attachments + bodyFiles + inline)
    }

    /// Files written for sending. Inline images cache their part on the attachment (C-08); the counter keeps
    /// names unique and writes are never repeated for the same image.
    private var inlinePartCount = 0
    private var inlineDir: URL?

    private func inlinePart(for att: NSTextAttachment) -> OutgoingAttachment? {
        if let a = att as? InlineImageAttachment, let p = a.outgoingPart { return p }
        guard let data = InlineImage.bytes(att) else { return nil }
        let name = BodyPart.safeFilename(att.fileWrapper?.preferredFilename ?? "image.png") ?? "image.png"
        guard let url = writeSendingFile(data, name: name) else { return nil }
        let part = OutgoingAttachment(url: url, filename: name, mimeType: InlineImage.mimeType(data),
                                      contentID: "\(UUID().uuidString.lowercased())@macmail")
        (att as? InlineImageAttachment)?.outgoingPart = part
        return part
    }

    /// A non-image attachment living in the body (rich-text paste, file promise): send its bytes as a file
    /// attachment instead of letting normalize delete it or the HTML drop it (C-03).
    private func filePart(for att: NSTextAttachment) -> OutgoingAttachment? {
        guard let data = InlineImage.bytes(att) else { return nil }
        let name = BodyPart.safeFilename(att.fileWrapper?.preferredFilename ?? "attachment") ?? "attachment"
        guard let url = writeSendingFile(data, name: name) else { return nil }
        return OutgoingAttachment(url: url, filename: name, mimeType: MessageBuilder.mimeType(for: url))
    }

    private func writeSendingFile(_ data: Data, name: String) -> URL? {
        let dir = inlineDir ?? {
            let d = AppPaths.tempDir("inline")
            tempDirs.append(d)
            inlineDir = d
            return d
        }()
        let url = dir.appendingPathComponent("\(inlinePartCount)-" + name)
        inlinePartCount += 1
        do { try data.write(to: url); return url } catch { return nil }
    }

    /// Commits in-progress field editing so a half-typed recipient or subject reaches the message (BUG-18).
    private func commitEditing() {
        for f in [toField, ccField, bccField, subjectField] as [NSControl] {
            if f.currentEditor() != nil { f.validateEditing() }
        }
    }

    @objc func send(_ sender: Any?) {
        guard !waitingForDraftBody else {
            alert("The draft is still loading — try again in a moment.")
            return
        }
        guard pipelineTasks == 0 else {
            NSSound.beep()
            status.stringValue = "Attachments are still being prepared…"
            return
        }
        guard missingAttachments.isEmpty else {
            let a = NSAlert()
            a.messageText = "Some attachments couldn't be recovered"
            a.informativeText = missingAttachments.joined(separator: "\n") + "\n\nSend the message without them?"
            a.addButton(withTitle: "Send Without")
            a.addButton(withTitle: "Cancel")
            present(a) { [weak self] r in
                guard let self, r == .alertFirstButtonReturn else { return }
                self.missingAttachments = []
                self.refreshMissingStatus()
                self.send(nil)
            }
            return
        }
        guard missingAccountID == nil else {
            alert("Choose a From account",
                  info: "This message belongs to an account that has been removed. Pick a From account, then send again.")
            return
        }
        guard let message = buildMessage(), let account else {
            alert("Choose a From account before sending.")
            return
        }
        if message.allRecipients.isEmpty {
            alert("Add at least one recipient.")
            return
        }
        let invalid = (addresses(toField) + addresses(ccField) + addresses(bccField)).filter { !$0.email.contains(".") }
        if !invalid.isEmpty {
            alert("Check the address \(invalid[0].email).")
            return
        }
        if message.subject.trimmingCharacters(in: .whitespaces).isEmpty {
            let a = NSAlert()
            a.messageText = "Send without a subject?"
            a.addButton(withTitle: "Send")
            a.addButton(withTitle: "Cancel")
            present(a) { [weak self] r in if r == .alertFirstButtonReturn { self?.queueSend(message, account: account) } }
            return
        }
        queueSend(message, account: account)
    }

    private func queueSend(_ message: OutgoingMessage, account: Account) {
        sentOrDiscarded = true
        window?.orderOut(nil)
        let main = (NSApp.delegate as? AppDelegate)?.mainWindow
        let pending = MailService.PendingSend(accountID: account.id, message: message, replyTo: replyRow,
                                              draftToDelete: draftRow)
        let id = MailService.shared.queueSend(pending, onUndo: { [weak self] in self?.reopenAfterUndo() }) { [weak self] outcome in
            guard let self else { return }
            // The pending id is dead either way; leaving it set would block cleanup on close (V2-11).
            self.pendingSendID = nil
            switch outcome {
            case .sent:
                main?.showToast("Message sent")
                self.discardAutosave()
                self.cleanUpAndForget()
            case .queued:
                // Offline: the finished message waits in the outbox and goes out when the network is back (F-07).
                main?.showToast("You're offline — message saved to the Outbox and will be sent automatically")
                self.discardAutosave()
                self.cleanUpAndForget()
            case .failed(let error):
                self.sentOrDiscarded = false
                self.status.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status.textColor = .systemRed
                self.showWindow(nil)
                self.alert("Your message wasn't sent", info: self.status.stringValue)
            }
        }
        pendingSendID = id
        let seconds = Prefs.undoSendSeconds
        if seconds > 0 {
            main?.showToast("Sending… (⌘Z or Esc to undo)", action: ("Undo", { [weak self] in self?.undoSend() }),
                            duration: Double(max(seconds, 1)))
        } else {
            main?.showToast("Sending…")
        }
    }

    /// Toast button: only succeeds while the send is still waiting; once the upload has started the
    /// toast says so instead of pretending (B-04).
    private func undoSend() {
        guard let id = pendingSendID else { return }
        if MailService.shared.cancelSend(id) {
            reopenAfterUndo()
        } else {
            (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Too late to undo — the message is already being sent")
        }
    }

    private func reopenAfterUndo() {
        pendingSendID = nil
        sentOrDiscarded = false
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Sending undone")
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
                self.discardAutosave()
                self.window?.close()
            default: break
            }
        }
        return false
    }

    private func saveDraftAndClose() { saveDraft { _ in } }

    /// Saves the draft (server APPEND), then runs `done` with whether it saved. Used by the close prompt
    /// and, at quit time, to keep the app alive until the save lands.
    private func saveDraft(_ done: @escaping (Bool) -> Void) {
        guard missingAccountID == nil else {
            alert("Choose a From account",
                  info: "This message belongs to an account that has been removed. Pick the account to save the draft in.")
            done(false)
            return
        }
        guard !waitingForDraftBody else {
            alert("The draft is still loading — try again in a moment.")
            done(false)
            return
        }
        guard pipelineTasks == 0 else {
            alert("Attachments are still being downloaded — try again in a moment.")
            done(false)
            return
        }
        guard var message = buildMessage(), let account else {
            alert("Choose a From account before saving.")
            done(false)
            return
        }
        guard let engine = MailService.shared.engine(account.id) else {
            alert("\(account.email) isn't available", info: "Reconnect the account, then save the draft again.")
            done(false)
            return
        }
        // A fresh Message-ID identifies the replacement draft on the server (B-09).
        let messageID = MessageBuilder.newMessageID(for: message.from)
        message.messageID = messageID
        sentOrDiscarded = true
        window?.orderOut(nil)
        let old = draftRow
        let bccLine = addresses(bccField).map { $0.full }.joined(separator: ", ")
        Task { [weak self] in
            guard let self else { done(false); return }
            do {
                let data = try await Task.detached { try MessageBuilder.build(message) }.value
                let newID = try await engine.saveDraft(data, messageID: messageID)
                // The replacement row is found by its Message-ID, never by subject; tag it with the Bcc
                // line, which never travels in the draft MIME (BUG-19 / B-09).
                if let newID { MailService.shared.store.setBcc(ids: [newID], bcc: bccLine) }
                // The old draft goes only once its replacement is confirmed on the server, and never if
                // the replacement came out empty (V2-04, B-01).
                let hasContent = !message.textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !message.attachments.isEmpty
                if let old, hasContent, newID != nil || engine.isDemo {
                    engine.queue(.expunge, rows: [old]); MailService.shared.store.deleteMessages(ids: [old.id])
                }
                (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Draft saved")
                self.discardAutosave()
                self.cleanUpAndForget()
                done(true)
            } catch {
                self.sentOrDiscarded = false
                self.showWindow(nil)
                let a = NSAlert(error: error)
                a.messageText = "Couldn't save the draft"
                self.present(a)
                done(false)
            }
        }
    }

    /// Quit-time variant of the close prompt: Save / Don't Save / Cancel, reporting whether the quit
    /// may proceed. windowShouldClose doesn't run during termination (V2-01).
    func confirmBeforeQuit(_ done: @escaping (Bool) -> Void) {
        guard dirty, !sentOrDiscarded, let window else { done(true); return }
        // A sheet on a miniaturized or hidden window is invisible and would stall quit; surface it first.
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        let a = NSAlert()
        a.messageText = "Save this message as a draft?"
        a.informativeText = "Drafts are saved to the account's Drafts folder."
        a.addButton(withTitle: "Save Draft")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self else { done(true); return }
            switch r {
            case .alertFirstButtonReturn: self.saveDraft(done)
            case .alertSecondButtonReturn:
                self.sentOrDiscarded = true
                self.discardAutosave()
                done(true)
            default: done(false)
            }
        }
    }

    /// Demo self-test (MAC_MAIL_DEMO_SELFTEST): exercises the To→Cc drag-move and title-follows-subject paths
    /// through the same delegate methods AppKit calls. Returns "PASS …"/"FAIL …" lines.
    func demoSelfTest(done: @escaping ([String]) -> Void) {
        var out: [String] = []
        toField.objectValue = ["Ann <ann@example.com>", "Bob <bob@example.com>"]
        ccField.objectValue = []
        let pb = NSPasteboard(name: .drag)
        _ = tokenField(toField, writeRepresentedObjects: ["Ann <ann@example.com>"], to: pb)
        let dropped = tokenField(ccField, readFrom: pb) as? [String] ?? []
        ccField.objectValue = dropped
        subjectField.stringValue = "Lunch plans"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: subjectField))
        dirty = true
        DispatchQueue.main.async { [self] in
            let to = (toField.objectValue as? [String]) ?? []
            let cc = (ccField.objectValue as? [String]) ?? []
            out.append((to == ["Bob <bob@example.com>"] && cc == ["Ann <ann@example.com>"] ? "PASS" : "FAIL")
                       + " drag To→Cc moves the address (to=\(to) cc=\(cc))")
            out.append((window?.title == "Lunch plans" ? "PASS" : "FAIL") + " window title follows subject (\(window?.title ?? "nil"))")
            out.append((Self.composersNeedingSave.contains(self) ? "PASS" : "FAIL") + " dirty composer is asked on quit")
            out += formatSelfTest()
            out += inlineImageSelfTest()
            done(out)
        }
    }

    /// Selects a word, sets Georgia 18 bold from the format bar, and checks the bar and the sent HTML follow.
    private func formatSelfTest() -> [String] {
        let storage = textView.textStorage!
        let start = storage.length
        textView.setSelectedRange(NSRange(location: start, length: 0))
        textView.insertText("Styled", replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: start, length: 6))
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        formatBar.selfTestApply(family: "Georgia", size: 18, boldSegment: true)
        textView.undoManager?.endUndoGrouping()
        let state = formatBar.selfTestState
        let html = buildMessage()?.htmlBody ?? ""
        let ok = state == "Georgia/18/b=true" && html.contains("<b>Styled</b>") && html.contains("font-size:18px")
            && html.contains("font-family:'Georgia',serif")
        textView.undoManager?.undoNestedGroup()
        let undone = storage.length > start && (storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont)?.pointSize != 18
        return [(ok && undone ? "PASS" : "FAIL") + " format bar sets font/size/bold, sent HTML follows, undo works (state=\(state))"]
    }

    /// Pastes a copied image file and a text file the way Finder / Mac Explorer put them on the pasteboard
    /// (file URLs plus an icon TIFF), then checks the image is inline, the text file attached, the sent
    /// message has a cid part, and an autosave keeps the image.
    private func inlineImageSelfTest() -> [String] {
        var out: [String] = []
        let dir = AppPaths.tempDir("selftest-inline")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("photo.png"), txt = dir.appendingPathComponent("notes.txt")
        let img = NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return ["FAIL inline: test image"] }
        try? pngData.write(to: png)
        try? Data("hello".utf8).write(to: txt)
        let pb = NSPasteboard(name: NSPasteboard.Name("MacMailSelfTest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([png as NSURL, txt as NSURL])
        pb.addTypes([.tiff], owner: nil)
        pb.setData(NSWorkspace.shared.icon(forFile: png.path).tiffRepresentation, forType: .tiff)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        _ = textView.paste(from: pb)
        var inline: [NSTextAttachment] = []
        let storage = textView.textStorage!
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let a = v as? NSTextAttachment { inline.append(a) }
        }
        let shown = inline.first?.bounds.size ?? .zero
        out.append((inline.count == 1 && attachments.map { $0.filename } == ["notes.txt"] && shown.width <= textView.inlineImageWidth + 1
                    && inline.first is InlineImageAttachment ? "PASS" : "FAIL")
                   + " copied image file pastes inline, other file attaches (inline=\(inline.count) shown=\(Int(shown.width))x\(Int(shown.height)) files=\(attachments.map { $0.filename }))")
        if let m = buildMessage(), let data = try? MessageBuilder.build(m), let doc = try? EMLDocument.parse(data),
           let cid = m.attachments.first(where: { $0.contentID != nil })?.contentID {
            let part = doc.structure.part(withContentID: cid)
            let same = part.flatMap { doc.data(for: $0) } == pngData
            let inHTML = doc.bodies().html?.contains("cid:\(cid)") == true
            let chips = doc.structure.attachments().compactMap { $0.filename }
            out.append((same && inHTML && chips == ["notes.txt"] ? "PASS" : "FAIL")
                       + " inline image is sent as a cid part (bytes=\(same) html=\(inHTML) chips=\(chips))")
        } else {
            out.append("FAIL inline image is sent as a cid part (no message)")
        }
        // Resize: Image Size → 200 pt, the sent HTML follows, the handle frame matches, and Undo puts it back.
        var idx = -1
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, _ in if v != nil { idx = r.location } }
        if let att = inline.first, idx >= 0 {
            let before = att.bounds.width
            // In a scripted run every change shares the event's undo group; nest the resize so only it is undone.
            textView.undoManager?.beginUndoGrouping()
            textView.setImageWidth(att, index: idx, width: 200)
            textView.undoManager?.endUndoGrouping()
            textView.setSelectedRange(NSRange(location: idx, length: 1))
            let frame = textView.selectedImage?.rect ?? .zero
            let html = buildMessage()?.htmlBody ?? ""
            let resized = att.bounds.width == 200 && html.contains("width=\"200\"") && frame.width == 200 && frame.height == att.bounds.height
            textView.undoManager?.undoNestedGroup()
            out.append((resized && att.bounds.width == before ? "PASS" : "FAIL")
                       + " inline image resizes and undoes (\(Int(before))→200→\(Int(att.bounds.width)), frame \(Int(frame.width))x\(Int(frame.height)))")
            textView.setImageWidth(att, index: idx, width: 240)
        }
        let attr = textView.attributedString()
        let rtfd = InlineImage.rtfd(attr)
        let restored = rtfd.flatMap { NSAttributedString(rtfd: $0, documentAttributes: nil) }.map { NSTextStorage(attributedString: $0) }
        if let restored { InlineImage.normalize(restored, maxWidth: 640, widths: InlineImage.widths(attr)) }
        var kept = 0
        var seen: [String] = []
        restored?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: restored?.length ?? 0)) { v, _, _ in
            if let a = v as? NSTextAttachment {
                seen.append("\(type(of: a)) same=\(InlineImage.bytes(a) == pngData) n=\(InlineImage.bytes(a)?.count ?? -1)/\(pngData.count) w=\(a.bounds.width)")
            }
            if let a = v as? NSTextAttachment, InlineImage.bytes(a) == pngData, a is InlineImageAttachment,
               a.bounds.width == 240 { kept += 1 }
        }
        out.append((kept == 1 ? "PASS" : "FAIL") + " autosave keeps the inline image and its size (\(kept) rtfd=\(rtfd?.count ?? -1) \(seen))")
        return out
    }

    static var composersNeedingSave: [ComposeWindowController] {
        open.filter { $0.dirty && !$0.sentOrDiscarded }
    }

    // MARK: Quote web view lifecycle (BUG-28)

    /// The quote web views are torn down with the reading panes when the app idles in the background or
    /// under memory pressure, and rebuilt when their window is shown again.
    static func releaseQuoteWebViews() {
        for c in open { c.releaseQuoteWebView() }
    }

    static func restoreQuoteWebViews() {
        for c in open where c.window?.isVisible == true { c.restoreQuoteWebView() }
    }

    private func releaseQuoteWebView() {
        quoteLoader.cancelAll()
        quoteWeb?.removeFromSuperview()
        quoteWeb = nil
    }

    private func restoreQuoteWebView() {
        guard quoteWeb == nil, let q = quoteSource else { return }
        quotePane.subviews.forEach { $0.removeFromSuperview() }
        setQuote(q.detail, q.body, header: q.header, blockquote: q.blockquote)
    }

    func windowWillClose(_ notification: Notification) {
        if pendingSendID == nil {
            // Closed without changes (or after Don't Save): nothing to recover.
            if !dirty || sentOrDiscarded { discardAutosave() }
            cleanUpAndForget()
        }
    }

    private func cleanUpAndForget() {
        fetchTask?.cancel()
        for t in zipTasks { t.cancel() }
        quoteLoader.cancelAll()
        quoteWeb?.removeFromSuperview()
        quoteWeb = nil
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
        window?.orderOut(nil)
        Self.open.remove(self)
        if NSApp.windows.allSatisfy({ !$0.isVisible }) && (NSApp.delegate as? AppDelegate)?.mainWindow?.window?.isVisible != true {
            NSApp.terminate(nil)
        }
    }

    @objc private func fromChanged() {
        missingAccountID = nil
        dirty = true
        swapSignature()
        scheduleAutosave()
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        scheduleAutosave()
        formatBar.refresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        formatBar.refresh()
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any],
                  toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        // ⌘B/⌘I/⌘U with nothing selected only change typing attributes; keep the bar in step.
        DispatchQueue.main.async { [weak self] in self?.formatBar.refresh() }
        return new
    }

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

    // MARK: Dragging addresses between To / Cc / Bcc (a move, like Outlook)

    private static let addressType = NSPasteboard.PasteboardType("com.manikpruthi.macmail.addresses")
    /// The field a drag of address tokens started in, and what it carried.
    private var dragSource: (field: NSTokenField, objects: [String])?

    func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
        let strings = objects.compactMap { $0 as? String }
        guard !strings.isEmpty else { return false }
        pboard.declareTypes([Self.addressType, .string], owner: nil)
        pboard.setPropertyList(strings, forType: Self.addressType)
        pboard.setString(strings.joined(separator: ", "), forType: .string)
        // AppKit adds its own types to the drag pasteboard after this returns, so changeCount can't identify the
        // drag; the dragged addresses themselves do.
        dragSource = pboard.name == .drag ? (tokenField, strings) : nil
        return true
    }

    func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
        let objects = (pboard.propertyList(forType: Self.addressType) as? [String])
            ?? pboard.string(forType: .string).map { MIME.parseAddresses($0).map { $0.full } }
        guard let objects, !objects.isEmpty else { return nil }
        if pboard.name == .drag, let src = dragSource, src.objects == objects, src.field !== tokenField {
            dragSource = nil
            // After the drop finishes, take the tokens out of the field they were dragged from.
            DispatchQueue.main.async { [weak self] in self?.remove(src.objects, from: src.field) }
        }
        return objects
    }

    private func remove(_ objects: [String], from field: NSTokenField) {
        if field.currentEditor() != nil { field.validateEditing(); field.abortEditing() }
        var current = (field.objectValue as? [Any])?.compactMap { $0 as? String } ?? []
        for o in objects { if let i = current.firstIndex(of: o) { current.remove(at: i) } }
        field.objectValue = current
        dirty = true
    }

    func controlTextDidChange(_ obj: Notification) {
        dirty = true
        scheduleAutosave()
        if (obj.object as? NSControl) === subjectField {
            window?.title = subjectField.stringValue.isEmpty ? "New Message" : subjectField.stringValue
        }
    }
}

extension ComposeWindowController: NSTextFieldDelegate {}

/// Body text view. Like Outlook: images (pasted pictures, or image files copied/dropped from Finder or Mac Explorer)
/// go into the body inline; other files become attachments.
final class ComposeTextView: NSTextView {
    var onDropFiles: (([URL]) -> Void)?

    /// Width an inline image may take: the editor's text width.
    var inlineImageWidth: CGFloat {
        let inset = textContainerInset.width * 2 + (textContainer?.lineFragmentPadding ?? 5) * 2
        return max(200, bounds.width - inset)
    }

    // MARK: Resizing inline images (drag a corner handle, or right-click → Image Size)

    private static let handle: CGFloat = 8

    /// The selected inline image and its frame in view coordinates (an image is selected by clicking it).
    var selectedImage: (att: NSTextAttachment, index: Int, rect: NSRect)? {
        let r = selectedRange()
        guard r.length == 1 else { return nil }
        return image(at: r.location)
    }

    private func image(at index: Int) -> (att: NSTextAttachment, index: Int, rect: NSRect)? {
        guard let storage = textStorage, index < storage.length,
              let att = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment,
              att is InlineImageAttachment, let lm = layoutManager, let tc = textContainer else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        _ = tc
        let line = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let loc = lm.location(forGlyphAt: glyphs.location)
        let size = att.bounds.size
        // The image's bottom sits on the baseline (flipped view: baseline y = line top + glyph y).
        var rect = NSRect(x: line.minX + loc.x, y: line.minY + loc.y - size.height - att.bounds.minY,
                          width: size.width, height: size.height)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return (att, index, rect)
    }

    private func imageHit(_ point: NSPoint) -> (att: NSTextAttachment, index: Int, rect: NSRect)? {
        let i = characterIndexForInsertion(at: point)
        for c in [i, i - 1] where c >= 0 {
            if let hit = image(at: c), hit.rect.insetBy(dx: -Self.handle, dy: -Self.handle).contains(point) { return hit }
        }
        return nil
    }

    private func handleRects(_ r: NSRect) -> [NSRect] {
        let h = Self.handle
        return [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
            .map { NSRect(x: $0.x - h / 2, y: $0.y - h / 2, width: h, height: h) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let sel = selectedImage else { return }
        drawnImageRect = sel.rect
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: sel.rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        for h in handleRects(sel.rect) {
            NSColor.white.setFill()
            NSBezierPath(rect: h).fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: h).stroke()
        }
    }

    /// Where the selection frame was last drawn. Deleting or resizing the image can move or remove it before the
    /// next draw, so this old area is repainted explicitly; otherwise a piece of the image and handles stays on screen.
    private var drawnImageRect: NSRect?

    private func refreshImageSelection() {
        let now = selectedImage?.rect
        guard now != drawnImageRect else { return }
        if let old = drawnImageRect { setNeedsDisplay(old.insetBy(dx: -Self.handle - 2, dy: -Self.handle - 2)) }
        if let now { setNeedsDisplay(now.insetBy(dx: -Self.handle - 2, dy: -Self.handle - 2)) }
        drawnImageRect = now
        window?.invalidateCursorRects(for: self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        refreshImageSelection()
    }

    /// Images about to be deleted or replaced: their area is repainted once the change is in.
    private var staleImageRects: [NSRect] = []

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if affectedCharRange.length > 0, let storage = textStorage, NSMaxRange(affectedCharRange) <= storage.length {
            storage.enumerateAttribute(.attachment, in: affectedCharRange) { v, r, _ in
                if v is InlineImageAttachment, let hit = image(at: r.location) { staleImageRects.append(hit.rect) }
            }
        }
        return true
    }

    override func didChangeText() {
        super.didChangeText()
        for r in staleImageRects { setNeedsDisplay(r.insetBy(dx: -Self.handle - 2, dy: -Self.handle - 2)) }
        staleImageRects.removeAll()
        refreshImageSelection()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let sel = selectedImage else { return }
        let hs = handleRects(sel.rect)
        let cursors: [NSCursor]
        if #available(macOS 15.0, *) {
            cursors = [NSCursor.frameResize(position: .topLeft, directions: .all), NSCursor.frameResize(position: .topRight, directions: .all),
                       NSCursor.frameResize(position: .bottomLeft, directions: .all), NSCursor.frameResize(position: .bottomRight, directions: .all)]
        } else {
            cursors = Array(repeating: NSCursor.crosshair, count: 4)
        }
        for (r, c) in zip(hs, cursors) { addCursorRect(r, cursor: c) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let sel = selectedImage, let corner = handleRects(sel.rect).firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }) {
            trackResize(sel, corner: corner, from: point)
            return
        }
        // First click selects the image (handles appear); a click on the selected image drags it to move it.
        if event.clickCount == 1, let hit = imageHit(point), hit.rect.contains(point),
           selectedRange() != NSRange(location: hit.index, length: 1) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: hit.index, length: 1))
            return
        }
        super.mouseDown(with: event)
    }

    /// Drags a corner: the image keeps its aspect ratio; left-hand corners grow it when dragged left.
    private func trackResize(_ sel: (att: NSTextAttachment, index: Int, rect: NSRect), corner: Int, from start: NSPoint) {
        let startWidth = sel.att.bounds.width
        let sign: CGFloat = corner % 2 == 0 ? -1 : 1
        let range = NSRange(location: sel.index, length: 1)
        undoManager?.beginUndoGrouping()
        registerResizeUndo(sel.att, index: sel.index, width: startWidth)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(e.locationInWindow, from: nil)
            let width = startWidth + sign * (p.x - start.x)
            InlineImage.previewResize(sel.att, width: width, maxWidth: inlineImageWidth)
            imageSizeChanged(range)
            if e.type == .leftMouseUp { break }
        }
        undoManager?.endUndoGrouping()
        InlineImage.applyDisplay(sel.att, maxWidth: inlineImageWidth, width: sel.att.bounds.width)
        imageSizeChanged(range)
    }

    func setImageWidth(_ att: NSTextAttachment, index: Int, width: CGFloat?) {
        registerResizeUndo(att, index: index, width: att.bounds.width)
        InlineImage.applyDisplay(att, maxWidth: inlineImageWidth, width: width)
        imageSizeChanged(NSRange(location: index, length: 1))
    }

    private func registerResizeUndo(_ att: NSTextAttachment, index: Int, width: CGFloat) {
        undoManager?.registerUndo(withTarget: self) { tv in tv.setImageWidth(att, index: index, width: width) }
        undoManager?.setActionName("Resize Image")
    }

    private func imageSizeChanged(_ range: NSRange) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        needsDisplay = true
        refreshImageSelection()
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = imageHit(point) else { return menu }
        setSelectedRange(NSRange(location: hit.index, length: 1))
        let sub = NSMenu()
        let natural = InlineImage.naturalSize(hit.att)?.width ?? hit.att.bounds.width
        let options: [(String, CGFloat?)] = [("Small", 160), ("Medium", 320), ("Large", 480),
                                             ("Fit to Window", inlineImageWidth), ("Original Size", natural)]
        for (title, width) in options {
            let item = NSMenuItem(title: title, action: #selector(imageSizeMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = width.map { NSNumber(value: Double($0)) }
            item.tag = hit.index
            if let width, abs(min(width, inlineImageWidth) - hit.att.bounds.width) < 1 { item.state = .on }
            sub.addItem(item)
        }
        let parent = NSMenuItem(title: "Image Size", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.insertItem(parent, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func imageSizeMenu(_ sender: NSMenuItem) {
        guard let hit = image(at: sender.tag), let w = sender.representedObject as? NSNumber else { return }
        setImageWidth(hit.att, index: hit.index, width: CGFloat(w.doubleValue))
    }

    /// HTML and web archives are never read: they would make AppKit fetch remote images while pasting.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes.filter { $0 != .html && $0.rawValue != "Apple Web Archive pasteboard type"
            && $0.rawValue != "com.apple.webarchive" }
    }

    override func paste(_ sender: Any?) {
        if !paste(from: NSPasteboard.general) { super.paste(sender) }
        if let storage = textStorage { InlineImage.normalize(storage, maxWidth: inlineImageWidth) }
    }

    /// Files and pictures on `pb` go in as inline images / attachments; false when it holds neither.
    func paste(from pb: NSPasteboard) -> Bool {
        if let urls = Self.fileURLs(pb), !urls.isEmpty {
            insertFiles(urls)
            return true
        }
        if let data = Self.imageData(pb) {
            insertImages([(data, "Pasted image.png")])
            return true
        }
        return false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Moving text (and images) within the body is AppKit's own drag.
        if (sender.draggingSource as AnyObject?) !== self {
            let pb = sender.draggingPasteboard
            let point = convert(sender.draggingLocation, from: nil)
            if let urls = Self.fileURLs(pb), !urls.isEmpty {
                setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
                insertFiles(urls)
                return true
            }
            if let data = Self.imageData(pb) {
                setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
                insertImages([(data, "Image.png")])
                return true
            }
        }
        let ok = super.performDragOperation(sender)
        if let storage = textStorage { InlineImage.normalize(storage, maxWidth: inlineImageWidth) }
        return ok
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.fileURLs(sender.draggingPasteboard) != nil || Self.imageData(sender.draggingPasteboard) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = super.draggingUpdated(sender)
        if (sender.draggingSource as AnyObject?) !== self,
           Self.fileURLs(sender.draggingPasteboard) != nil || Self.imageData(sender.draggingPasteboard) != nil { return .copy }
        return op
    }

    /// Image files go inline at the insertion point; everything else (and images over the size limit) is attached.
    private func insertFiles(_ urls: [URL]) {
        var images: [URL] = []
        var others: [URL] = []
        for u in urls { if InlineImage.isCandidate(u) { images.append(u) } else { others.append(u) } }
        var failed: [URL] = []
        let atts = images.compactMap { u -> NSTextAttachment? in
            let a = InlineImage.attachment(file: u, maxWidth: inlineImageWidth)
            if a == nil { failed.append(u) }
            return a
        }
        insert(atts)
        if !(others + failed).isEmpty { onDropFiles?(others + failed) }
    }

    private func insertImages(_ items: [(Data, String)]) {
        insert(items.compactMap { InlineImage.attachment(data: $0.0, name: $0.1, maxWidth: inlineImageWidth) })
    }

    private func insert(_ atts: [NSTextAttachment]) {
        guard !atts.isEmpty else { return }
        let out = NSMutableAttributedString()
        for (i, a) in atts.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
            out.append(NSAttributedString(attachment: a))
        }
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: out.string) else { return }
        textStorage?.replaceCharacters(in: range, with: out)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + out.length, length: 0))
    }

    /// File URLs on a pasteboard (Finder and Mac Explorer copy files this way), nil when there are none.
    static func fileURLs(_ pb: NSPasteboard) -> [URL]? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else { return nil }
        return urls
    }

    /// Picture data (screenshots, images copied in Preview, Photos or a browser).
    static func imageData(_ pb: NSPasteboard) -> Data? {
        for t in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                  NSPasteboard.PasteboardType(UTType.gif.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let d = pb.data(forType: t) { return d }
        }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}

/// Minimal attributed-string → HTML for outgoing mail: bold, italic, underline, strike, links, colours, sizes,
/// and paragraph formatting (alignment, indent, spacing, lists).
enum RichText {
    /// `image` returns the content id for an inline image attachment (nil leaves it out).
    static func html(from attr: NSAttributedString, image: ((NSTextAttachment) -> String?)? = nil) -> String {
        guard attr.length > 0 else { return "" }
        let ns = attr.string as NSString
        var out = ""
        var list = ""
        var location = 0
        func closeList() {
            if !list.isEmpty { out += "</\(list)>"; list = "" }
        }
        while location < attr.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 0x0D { content.length -= 1 }
            let style = attr.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            let kind = listKind(style)
            if kind != list {
                closeList()
                if !kind.isEmpty { out += "<\(kind)>"; list = kind }
            }
            let inner = inlineHTML(attr, content, image: image)
            let css = blockCSS(style, inList: !list.isEmpty)
            if list.isEmpty {
                out += "<div\(styleAttribute(css))>\(inner.isEmpty ? "<br>" : inner)</div>"
            } else {
                out += "<li\(styleAttribute(css))>\(inner.isEmpty ? "<br>" : inner)</li>"
            }
            location = NSMaxRange(paragraph)
        }
        closeList()
        return out
    }

    private static func inlineHTML(_ attr: NSAttributedString, _ range: NSRange,
                                   image: ((NSTextAttachment) -> String?)?) -> String {
        guard range.length > 0 else { return "" }
        let ns = attr.string as NSString
        var out = ""
        attr.enumerateAttributes(in: range) { attrs, run, _ in
            if let att = attrs[.attachment] as? NSTextAttachment {
                if let cid = image?(att) {
                    let w = Int(att.bounds.width.rounded()), h = Int(att.bounds.height.rounded())
                    let size = w > 0 && h > 0 ? " width=\"\(w)\" height=\"\(h)\"" : ""
                    out += "<img src=\"cid:\(MIME.escapeHTML(cid))\"\(size) alt=\"\" style=\"max-width:100%;height:auto\">"
                }
                return
            }
            var text = MIME.escapeHTML(ns.substring(with: run))
            text = text.replacingOccurrences(of: "\n", with: "<br>")
            var styles: [String] = []
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { text = "<b>\(text)</b>" }
                if traits.contains(.italic) { text = "<i>\(text)</i>" }
                if abs(font.pointSize - 14) > 0.5 { styles.append("font-size:\(cssNumber(font.pointSize))px") }
                if let family = font.familyName, !family.hasPrefix(".") && family != NSFont.systemFont(ofSize: 14).familyName {
                    // A generic fallback keeps the look close when the recipient lacks the font.
                    let generic = font.isFixedPitch ? "monospace"
                        : ["Georgia", "Times New Roman", "Times"].contains(family) ? "serif" : "sans-serif"
                    styles.append("font-family:'\(family.replacingOccurrences(of: "'", with: ""))',\(generic)")
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
                // Only safe schemes go out; a javascript:/data: link in the attributed string is dropped (SEC-14).
                let lower = href.lowercased()
                if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
                    text = "<a href=\"\(MIME.escapeHTML(href))\">\(text)</a>"
                }
            }
            out += text
        }
        return out
    }

    /// Paragraph-level formatting the composer doesn't offer but pasted rich text can carry.
    private static func blockCSS(_ style: NSParagraphStyle?, inList: Bool) -> [String] {
        guard let style else { return [] }
        var css: [String] = []
        switch style.alignment {
        case .center: css.append("text-align:center")
        case .right: css.append("text-align:right")
        case .justified: css.append("text-align:justify")
        default: break
        }
        if !inList, style.headIndent > 0.5 { css.append("margin-left:\(cssNumber(style.headIndent))px") }
        if style.paragraphSpacingBefore > 0.5 { css.append("margin-top:\(cssNumber(style.paragraphSpacingBefore))px") }
        if style.paragraphSpacing > 0.5 { css.append("margin-bottom:\(cssNumber(style.paragraphSpacing))px") }
        return css
    }

    private static func styleAttribute(_ css: [String]) -> String {
        css.isEmpty ? "" : " style=\"\(css.joined(separator: ";"))\""
    }

    /// "18" or "15.7": a fractional point size keeps one decimal instead of being truncated. Built by hand so
    /// a decimal comma from the user's locale can't end up in the CSS.
    private static func cssNumber(_ value: CGFloat) -> String {
        let tenths = Int((value * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(abs(tenths % 10))"
    }

    /// `<ol>` for numbered markers, `<ul>` for every other list; "" for an ordinary paragraph.
    private static func listKind(_ style: NSParagraphStyle?) -> String {
        guard let marker = style?.textLists.last?.markerFormat.rawValue.lowercased(), !marker.isEmpty else { return "" }
        if marker.contains("decimal") || marker.contains("alpha") || marker.contains("roman")
            || marker.contains("latin") || marker.contains("hexadecimal") || marker.contains("octal") {
            return "ol"
        }
        return "ul"
    }
}

/// One composer's unsent state, written to Application Support/…/Autosave every few seconds while it's
/// being edited, so a crash or forced quit can't lose it (F-06). Removed on send, save or discard.
struct ComposerAutosave: Codable {
    var id: String
    var accountID: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var bodyRTF: Data?
    var attachments: [String]
    var inReplyTo: String?
    var references: String?
    var quotedHTML: String
    var quotedText: String
    var includeOriginal: Bool
    var draftRowID: Int64?
    var replyRowID: Int64?
    var saved: Date
    /// Inline image widths in document order (RTFD keeps the images but not their sizes).
    var imageWidths: [Double]? = nil

    private static func file(_ id: String) -> URL { AppPaths.autosave.appendingPathComponent(id + ".json") }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file(id), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file(id).path)
    }

    static func remove(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }

    static func all() -> [ComposerAutosave] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.autosave, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(ComposerAutosave.self, from: $0) }
        }.sorted { $0.saved < $1.saved }
    }
}
