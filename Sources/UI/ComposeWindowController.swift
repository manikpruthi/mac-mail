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
        textView.onPasteImage = { [weak self] data in self?.addPastedImage(data) }
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
        for v in [grid, sep1, split, attachmentScroll, sep2, includeOriginal, status, attach, send] as [NSView] {
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
            split.topAnchor.constraint(equalTo: sep1.bottomAnchor),
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

    /// Changing the From account replaces the signature at the end of the body with the new account's one.
    private func swapSignature() {
        let newSig = account?.signature ?? ""
        guard newSig != currentSignature else { return }
        let storage = textView.textStorage
        if let old = currentSignature, !old.isEmpty {
            let tail = "\n\n" + old
            let text = textView.string
            if text.hasSuffix(tail) {
                let len = (text as NSString).length
                storage?.replaceCharacters(in: NSRange(location: len - (tail as NSString).length,
                                                       length: (tail as NSString).length), with: "")
            }
        }
        if !newSig.isEmpty {
            let len = (textView.string as NSString).length
            storage?.replaceCharacters(in: NSRange(location: len, length: 0), with: "\n\n" + newSig)
        }
        currentSignature = newSig
    }

    /// Fills the editor with a draft's cached body; when it isn't cached yet, fetches it instead of
    /// opening a blank editor that a later save would turn into a real empty draft (V2-04).
    private func loadDraftBody(_ d: MessageDetail, _ body: StoredBody?) {
        let hasContent = !(body?.html ?? "").isEmpty || !(body?.text ?? "").isEmpty
        guard hasContent else {
            waitingForDraftBody = true
            status.stringValue = "Loading draft…"
            let id = d.id
            Task { [weak self] in
                do {
                    guard let engine = MailService.shared.engine(d.accountID) else { return }
                    let fetched = try await engine.loadBody(messageID: id)
                    guard let self, !self.sentOrDiscarded else { return }
                    self.status.stringValue = ""
                    self.loadDraftBody(d, fetched)
                } catch {
                    guard let self, !self.sentOrDiscarded else { return }
                    self.waitingForDraftBody = false
                    self.status.stringValue = "Couldn't load the draft's body"
                }
            }
            return
        }
        waitingForDraftBody = false
        if let html = body?.html, let data = html.data(using: .utf8),
           let attr = NSAttributedString(html: data, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)
        } else {
            setBody(body?.text ?? "", signature: false)
        }
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
        let prepared = HTMLPrep.prepare(html: body?.html, text: body?.text, page: 1)
        let spam = d.folderRole == .spam
        quoteLoader.page = ImagePage(generation: 1, messageID: d.id, accountID: d.accountID, prepared: prepared,
                                     autoLoad: !spam && !Prefs.askBeforeImages, ignoreLimits: false)
        quoteLoader.page?.dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        web.loadHTMLString(prepared.html, baseURL: URL(string: "lm://quote/\(d.id)/"))
        quoteWeb = web
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
        if pipelineTasks == 0 { sendButton?.isEnabled = true }
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

    private static let attachmentStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    /// A screenshot pasted into the body becomes a PNG attachment (UX-08).
    private func addPastedImage(_ data: Data) {
        let dir = AppPaths.tempDir("paste")
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("Pasted image \(Self.attachmentStamp.string(from: Date())).png")
        do {
            try data.write(to: url)
        } catch {
            status.stringValue = "Couldn't save the pasted image"
            return
        }
        addAttachments([url])
    }

    // MARK: Building the message

    private func addresses(_ field: NSTokenField) -> [EmailAddress] {
        let tokens = (field.objectValue as? [Any])?.compactMap { $0 as? String } ?? [field.stringValue]
        return tokens.flatMap { MIME.parseAddresses($0) }.filter { $0.email.contains("@") }
    }

    private func buildMessage() -> OutgoingMessage? {
        commitEditing()
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

    /// Commits in-progress field editing so a half-typed recipient or subject reaches the message (BUG-18).
    private func commitEditing() {
        for f in [toField, ccField, bccField, subjectField] as [NSControl] {
            if f.currentEditor() != nil { f.validateEditing() }
        }
    }

    @objc func send(_ sender: Any?) {
        guard !waitingForDraftBody else {
            let a = NSAlert()
            a.messageText = "The draft is still loading — try again in a moment."
            a.beginSheetModal(for: window!, completionHandler: nil)
            return
        }
        guard pipelineTasks == 0 else {
            NSSound.beep()
            status.stringValue = "Attachments are still being prepared…"
            return
        }
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
            // The pending id is dead either way; leaving it set would block cleanup on close (V2-11).
            self.pendingSendID = nil
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
        if seconds > 0 {
            main?.showToast("Sending…", action: ("Undo", { [weak self] in self?.undoSend() }), duration: Double(max(seconds, 1)))
        } else {
            main?.showToast("Sending…")
        }
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

    private func saveDraftAndClose() { saveDraft { _ in } }

    /// Saves the draft (server APPEND), then runs `done` with whether it saved. Used by the close prompt
    /// and, at quit time, to keep the app alive until the save lands.
    private func saveDraft(_ done: @escaping (Bool) -> Void) {
        guard !waitingForDraftBody else {
            let a = NSAlert()
            a.messageText = "The draft is still loading — try again in a moment."
            a.beginSheetModal(for: window!, completionHandler: nil)
            done(false)
            return
        }
        guard let message = buildMessage(), let account, let engine = MailService.shared.engine(account.id) else { done(false); return }
        sentOrDiscarded = true
        window?.orderOut(nil)
        let old = draftRow
        let bccLine = addresses(bccField).map { $0.full }.joined(separator: ", ")
        Task { [weak self] in
            guard let self else { done(false); return }
            do {
                try await engine.saveDraft(try MessageBuilder.build(message))
                // The replacement row arrived with the sync inside saveDraft; tag it with the Bcc line,
                // which never travels in the draft MIME (BUG-19).
                if let drafts = MailService.shared.store.folder(account: account.id, role: .drafts) {
                    let ids = MailService.shared.store.rows(folderID: drafts.id)
                        .filter { $0.subject == message.subject && $0.id != old?.id }
                        .map { $0.id }
                    MailService.shared.store.setBcc(ids: ids, bcc: bccLine)
                }
                // Never expunge the previous draft if the replacement came out empty (V2-04).
                let hasContent = !message.textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !message.attachments.isEmpty
                if let old, hasContent {
                    engine.queue(kind: "expunge", rows: [old]); MailService.shared.store.deleteMessages(ids: [old.id])
                }
                (NSApp.delegate as? AppDelegate)?.mainWindow?.showToast("Draft saved")
                self.cleanUpAndForget()
                done(true)
            } catch {
                self.sentOrDiscarded = false
                self.showWindow(nil)
                let a = NSAlert(error: error)
                a.messageText = "Couldn't save the draft"
                a.beginSheetModal(for: self.window!, completionHandler: nil)
                done(false)
            }
        }
    }

    /// Quit-time variant of the close prompt: Save / Don't Save / Cancel, reporting whether the quit
    /// may proceed. windowShouldClose doesn't run during termination (V2-01).
    func confirmBeforeQuit(_ done: @escaping (Bool) -> Void) {
        guard dirty, !sentOrDiscarded, let window else { done(true); return }
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
                done(true)
            default: done(false)
            }
        }
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
        if pendingSendID == nil { cleanUpAndForget() }
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
        dirty = true
        swapSignature()
    }

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

    // MARK: Dragging addresses between To / Cc / Bcc (a move, like Outlook)

    private static let addressType = NSPasteboard.PasteboardType("com.manikpruthi.macmail.addresses")
    /// The field a drag of address tokens started in, and what it carried.
    private var dragSource: (field: NSTokenField, objects: [String], changeCount: Int)?

    func tokenField(_ tokenField: NSTokenField, writeRepresentedObjects objects: [Any], to pboard: NSPasteboard) -> Bool {
        let strings = objects.compactMap { $0 as? String }
        guard !strings.isEmpty else { return false }
        pboard.declareTypes([Self.addressType, .string], owner: nil)
        pboard.setPropertyList(strings, forType: Self.addressType)
        pboard.setString(strings.joined(separator: ", "), forType: .string)
        dragSource = pboard.name == .drag ? (tokenField, strings, pboard.changeCount) : nil
        return true
    }

    func tokenField(_ tokenField: NSTokenField, readFrom pboard: NSPasteboard) -> [Any]? {
        let objects = (pboard.propertyList(forType: Self.addressType) as? [String])
            ?? pboard.string(forType: .string).map { MIME.parseAddresses($0).map { $0.full } }
        guard let objects, !objects.isEmpty else { return nil }
        if pboard.name == .drag, let src = dragSource, src.changeCount == pboard.changeCount, src.field !== tokenField {
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
        if (obj.object as? NSControl) === subjectField {
            window?.title = subjectField.stringValue.isEmpty ? "New Message" : subjectField.stringValue
        }
    }
}

extension ComposeWindowController: NSTextFieldDelegate {}

/// Body text view that turns dropped files and pasted screenshots into attachments instead of inline images.
final class ComposeTextView: NSTextView {
    var onDropFiles: (([URL]) -> Void)?
    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) { onPasteImage?(data); return }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        super.paste(sender)
    }

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
}
