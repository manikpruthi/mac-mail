import AppKit
import Quartz
import UniformTypeIdentifiers
import WebKit

/// The reading pane: header, image/clip banner, attachment chips and one reused WKWebView.
@MainActor
final class PreviewViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let store = MailService.shared.store
    /// Created on demand and destroyed while the app is in the background, so WebKit's helper processes
    /// (content, GPU, networking ≈ 50 MB) exit when you're not reading mail.
    private var webView: WKWebView?
    static var ruleList: WKContentRuleList?
    /// True once the rule list store failed to provide one; rendering then proceeds with the CSP meta only.
    static var ruleListFailed = false
    private let loader = ImageLoader()
    private var generation = 0
    private var current: MessageDetail?
    private var currentBody: StoredBody?
    private var showFullClipped = false
    /// Set when the web view was torn down for good (window closing): no pending work may render into it.
    private var tornDown = false
    /// Message whose body is being fetched, so show() doesn't start a second fetch for it.
    private var fetchingID: Int64?

    private let stack = NSStackView()
    /// Stands in for the web view while there is none (at launch, and after WebKit is released when idle).
    /// Without a stretchable item the stack's height is fixed by the header, and Auto Layout then shrinks
    /// the whole window to it.
    private let webSpacer = NSView()
    private let headerBox = NSView()
    private let subjectLabel = NSTextField(wrappingLabelWithString: "")
    private let fromLabel = NSTextField(labelWithString: "")
    private let toLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let unsubscribeButton = NSButton(title: "Unsubscribe", target: nil, action: nil)
    private let editDraftButton = NSButton(title: "Edit Draft", target: nil, action: nil)
    private let banner = BannerView()
    private let attachmentBar = AttachmentBar()
    private let emptyLabel = NSTextField(labelWithString: "No message selected")
    private let welcome = WelcomeView()
    private let spinner = NSProgressIndicator()

    var onAddAccount: (() -> Void)?
    var onEditDraft: ((MessageDetail) -> Void)?
    var showToast: ((String) -> Void)?

    /// "Show with light background" (like Outlook's sun button) — remembered per sender across launches.
    private let lightButton = NSButton()

    private static func lightKey(_ email: String) -> String { "lightBg:" + email.lowercased() }
    private func lightBackground(_ d: MessageDetail) -> Bool {
        Prefs.d.bool(forKey: Self.lightKey(d.from.email))
    }

    private static let live = NSHashTable<PreviewViewController>.weakObjects()

    override func loadView() {
        Self.live.add(self)
        let root = ReadingPaneView()
        root.onAppearanceChange = { [weak self] in self?.appearanceChanged() }

        // Block every network load WebKit might try on its own (stylesheets, fonts, iframes): only lm:// gets through.
        // Compiled once and stored by WebKit; later launches just look it up.
        if Self.ruleList == nil {
            let store = WKContentRuleListStore.default()
            let id = "macmail-block-remote-v1"
            let install: (WKContentRuleList?) -> Void = { [weak self] list in
                guard let list else { Self.ruleListFailed = true; return }
                Self.ruleList = list
                self?.webView?.configuration.userContentController.add(list)
            }
            store?.lookUpContentRuleList(forIdentifier: id) { list, _ in
                if let list { install(list); return }
                store?.compileContentRuleList(
                    forIdentifier: id,
                    encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://.*","load-type":["third-party","first-party"]},"action":{"type":"block"}}]"#
                ) { list, _ in install(list) }
            }
        }

        loader.onBlocked = { [weak self] page in self?.imagesHeld(page) }
        loader.markBlocked = { [weak self] id in
            self?.webView?.evaluateJavaScript(
                "document.querySelectorAll('img[data-lm=\"\(id)\"]').forEach(function(e){e.setAttribute('data-lm-blocked','1')})",
                in: nil, in: .defaultClient, completionHandler: nil)
        }

        buildHeader()
        banner.isHidden = true
        attachmentBar.isHidden = true
        attachmentBar.onSave = { [weak self] part in self?.save(part) }
        attachmentBar.onSaveAll = { [weak self] in self?.saveAll() }
        attachmentBar.onQuickLook = { [weak self] part in self?.quickLook(part) }
        attachmentBar.provideFile = { [weak self] part, url in
            guard let self, let d = self.current else { throw NetError.server("No message is open.") }
            guard let engine = MailService.shared.engine(d.accountID) else { throw NetError.server("Account unavailable") }
            try await engine.download(messageID: d.id, part: part, to: url)
        }

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [headerBox, banner, attachmentBar] as [NSView] {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        webSpacer.translatesAutoresizingMaskIntoConstraints = false
        webSpacer.setContentHuggingPriority(.init(1), for: .vertical)
        webSpacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        stack.addArrangedSubview(webSpacer)
        root.addSubview(stack)

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        welcome.translatesAutoresizingMaskIntoConstraints = false
        welcome.onAdd = { [weak self] in self?.onAddAccount?() }
        root.addSubview(welcome)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            welcome.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            welcome.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            welcome.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: 40),
        ])
        view = root
        showEmpty(text: "No message selected")
    }

    private func buildHeader() {
        headerBox.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        subjectLabel.maximumNumberOfLines = 3
        subjectLabel.isSelectable = true
        fromLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fromLabel.isSelectable = true
        fromLabel.lineBreakMode = .byTruncatingTail
        toLabel.font = .systemFont(ofSize: 12)
        toLabel.textColor = .secondaryLabelColor
        toLabel.lineBreakMode = .byTruncatingTail
        toLabel.isSelectable = true
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        unsubscribeButton.bezelStyle = .inline
        unsubscribeButton.controlSize = .small
        unsubscribeButton.target = self
        unsubscribeButton.action = #selector(unsubscribe)
        editDraftButton.bezelStyle = .rounded
        editDraftButton.controlSize = .small
        editDraftButton.target = self
        editDraftButton.action = #selector(editDraft)
        lightButton.bezelStyle = .inline
        lightButton.isBordered = false
        lightButton.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Show with light background")
        lightButton.toolTip = "Show this message with a light background (⌥⌘L)"
        lightButton.target = self
        lightButton.action = #selector(toggleLight)

        let separator = NSBox()
        separator.boxType = .separator
        for v in [subjectLabel, fromLabel, toLabel, dateLabel, unsubscribeButton, editDraftButton, lightButton, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            headerBox.addSubview(v)
        }
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fromLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            subjectLabel.topAnchor.constraint(equalTo: headerBox.topAnchor, constant: 16),
            subjectLabel.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor, constant: 20),
            subjectLabel.trailingAnchor.constraint(lessThanOrEqualTo: editDraftButton.leadingAnchor, constant: -8),
            editDraftButton.trailingAnchor.constraint(equalTo: lightButton.leadingAnchor, constant: -8),
            editDraftButton.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),
            lightButton.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -18),
            lightButton.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),
            fromLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 8),
            fromLabel.leadingAnchor.constraint(equalTo: subjectLabel.leadingAnchor),
            fromLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -12),
            dateLabel.firstBaselineAnchor.constraint(equalTo: fromLabel.firstBaselineAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -20),
            toLabel.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 3),
            toLabel.leadingAnchor.constraint(equalTo: subjectLabel.leadingAnchor),
            toLabel.trailingAnchor.constraint(lessThanOrEqualTo: unsubscribeButton.leadingAnchor, constant: -8),
            unsubscribeButton.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor, constant: -16),
            unsubscribeButton.centerYAnchor.constraint(equalTo: toLabel.centerYAnchor),
            separator.topAnchor.constraint(equalTo: toLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerBox.bottomAnchor),
        ])
    }

    // MARK: Showing messages

    func showEmpty(text: String) {
        current = nil
        currentBody = nil
        fetchingID = nil
        loader.cancelAll()
        loader.page = nil
        stack.isHidden = true
        spinner.stopAnimation(nil)
        let noAccounts = MailService.shared.accounts.isEmpty
        welcome.isHidden = !noAccounts
        emptyLabel.isHidden = noAccounts
        emptyLabel.stringValue = text
        updateLightButton()
        // Drop the previous email's DOM and decoded images.
        webView?.loadHTMLString("", baseURL: nil)
    }

    private var openStarted = Date()
    private var openWasCached = false
    var onRendered: (() -> Void)?

    /// Time to the message text being on screen, separate from images still loading.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard current != nil, navigation === pendingNavigation else { return }
        Debug.log("open → text visible: \(Debug.ms(since: openStarted))")
    }

    /// False for programmatic selections (launch, folder switch, search typing, cursor move after
    /// archive/delete): the message is shown but not marked read.
    private var markReadAllowed = true

    func show(messageID: Int64, markRead: Bool = true) {
        guard let d = store.detail(messageID) else { showEmpty(text: "No message selected"); return }
        // An explicit open of the message already on screen still marks it read.
        if current?.id == messageID, markRead, !markReadAllowed {
            markReadAllowed = true
            markReadIfNeeded(messageID)
        }
        // Already shown, or a body fetch for it is still in flight — but a failed fetch may be retried, and a
        // web view released while idle must be rebuilt rather than leaving a blank pane (B-29).
        if current?.id == messageID, webView != nil, !tornDown, currentBody != nil || fetchingID == messageID { return }
        markReadAllowed = markRead
        tornDown = false
        spinner.stopAnimation(nil)
        openStarted = Date()
        openWasCached = store.hasBody(messageID)
        current = d
        currentBody = nil
        showFullClipped = false
        stack.isHidden = false
        emptyLabel.isHidden = true
        welcome.isHidden = true
        banner.isHidden = true

        subjectLabel.stringValue = d.subject.isEmpty ? "(no subject)" : d.subject
        fromLabel.stringValue = d.from.name.isEmpty ? d.from.email : "\(d.from.name)  <\(d.from.email)>"
        var to = "To: " + MIME.parseAddresses(d.toList).map { $0.display }.joined(separator: ", ")
        if !d.ccList.isEmpty { to += "   Cc: " + MIME.parseAddresses(d.ccList).map { $0.display }.joined(separator: ", ") }
        toLabel.stringValue = to
        dateLabel.stringValue = Self.dateFormatter.string(from: d.date)
        unsubscribeButton.isHidden = unsubscribeURL(d) == nil
        editDraftButton.isHidden = d.folderRole != .drafts
        attachmentBar.set(d.structure?.attachments() ?? [])
        attachmentBar.isHidden = attachmentBar.isEmpty

        if let body = store.body(messageID) {
            render(d, body)
        } else {
            fetchBody(for: d)
        }
    }

    /// Fetches the message text and renders it. `fetchingID` stops a second fetch for the same message,
    /// since both show() and restoreWebViewIfNeeded() come through here (F-03).
    private func fetchBody(for d: MessageDetail) {
        guard fetchingID != d.id else { return }
        fetchingID = d.id
        ensureWebView().loadHTMLString("", baseURL: nil)
        spinner.startAnimation(nil)
        let id = d.id
        Task {
            defer { if fetchingID == id { fetchingID = nil } }
            do {
                guard let engine = MailService.shared.engine(d.accountID) else { throw NetError.server("Account unavailable") }
                let body = try await engine.loadBody(messageID: id)
                guard current?.id == id, !tornDown else { return }
                spinner.stopAnimation(nil)
                render(d, body)
            } catch {
                guard current?.id == id, !tornDown else { return }
                spinner.stopAnimation(nil)
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ensureWebView().loadHTMLString(HTMLPrep.prepare(html: nil, text: "Couldn't load this message.\n\n\(msg)\n\nSelect it again to retry.").html, baseURL: nil)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private func render(_ d: MessageDetail, _ body: StoredBody, forceImages: Bool = false, attempt: Int = 0) {
        // Fail closed: nothing goes on screen until the remote-load block list is attached (CSP meta is the backstop).
        // The wait is capped at ~2 s; after that the CSP meta alone guards the render (B-30).
        if Self.ruleList == nil, !Self.ruleListFailed {
            guard attempt < 100 else {
                Debug.log("content rule list unavailable after 2 s; rendering with CSP only")
                Self.ruleListFailed = true
                render(d, body, forceImages: forceImages)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, self.current?.id == d.id, !self.tornDown else { return }
                self.render(d, body, forceImages: forceImages, attempt: attempt + 1)
            }
            return
        }
        guard !tornDown else { return }
        currentBody = body
        loader.cancelAll()
        // "View entire message" skips the clip but keeps every other protection.
        let forceLight = lightBackground(d)
        generation += 1
        let gen = generation
        let full = showFullClipped
        Task {
            // Large HTML is prepared off the main actor.
            let prepared = await HTMLPrep.prepareOffMain(html: body.html, text: body.text, clip: !full,
                                                         forceLight: forceLight, page: gen)
            guard !tornDown, generation == gen, current?.id == d.id else { return }
            finishRender(d, prepared: prepared, forceLight: forceLight, forceImages: forceImages)
        }
    }

    private func finishRender(_ d: MessageDetail, prepared: PreparedHTML, forceLight: Bool, forceImages: Bool) {
        updateLightButton()
        let senderPref = store.pref("img:" + d.from.email.lowercased())
        let isSpam = d.folderRole == .spam
        // Spam never loads images on its own, whatever the sender preference says (B-31).
        let autoLoad = forceImages || (!isSpam && (senderPref == "always" || (!Prefs.askBeforeImages && senderPref != "ask")))
        let page = ImagePage(generation: generation, messageID: d.id, accountID: d.accountID, prepared: prepared,
                             autoLoad: autoLoad, ignoreLimits: forceImages || senderPref == "always")
        page.dark = isDark && !forceLight
        lastRenderedDark = isDark
        loader.page = page
        banner.isHidden = true
        if prepared.clipped && !showFullClipped {
            banner.kind = .clipped
            banner.show(text: "This message is large, so only the first part is shown.",
                        actions: [("View entire message", { [weak self] in self?.viewEntire() })])
        } else if prepared.hasRemoteImages && !autoLoad {
            showImagesBanner(page)
        }
        let web = ensureWebView()
        // Images of the previous message would otherwise stay decoded in WebKit's memory cache (every
        // message's image URLs are unique, so they're never reused); drop them before the next page.
        web.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache],
                                                      modifiedSince: .distantPast) {}
        pendingNavigation = web.loadHTMLString(prepared.html, baseURL: URL(string: "lm://message/\(d.id)/"))
        if markReadAllowed { markReadIfNeeded(d.id) }
    }

    private func markReadIfNeeded(_ id: Int64) {
        guard Prefs.markReadOnOpen, !Debug.bench, current?.id == id, !(current?.flags.contains(.seen) ?? true) else { return }
        MailService.shared.setFlag(store.rows(ids: [id]), flag: .seen, on: true)
        // Keep the captured flags in sync so later re-renders (theme, zoom, load images) don't mark it read again.
        current?.flags.insert(.seen)
    }

    private func viewEntire() {
        guard let d = current, let b = currentBody else { return }
        showFullClipped = true
        render(d, b)
    }

    private func imagesHeld(_ page: ImagePage) {
        // A clipped-message banner keeps its "View entire message" action; the image notice then
        // appears once the full message has rendered (F-14).
        guard page.generation == generation, banner.isHidden || banner.kind == .images else { return }
        showImagesBanner(page)
    }

    private func showImagesBanner(_ page: ImagePage) {
        let sender = current?.from.email.lowercased() ?? ""
        let text: String
        if current?.folderRole == .spam {
            text = "Images are hidden in Spam to protect your privacy."
        } else if !page.autoLoad {
            text = "Images in this message aren't loaded."
        } else {
            text = "Some large images weren't loaded to keep memory low."
        }
        var actions: [(String, () -> Void)] = [("Load all images", { [weak self] in self?.loadAllImages() })]
        if !sender.isEmpty && current?.folderRole != .spam {
            actions.append(("Always load from this sender", { [weak self] in
                self?.store.setPref("img:" + sender, "always")
                self?.loadAllImages()
            }))
        }
        banner.show(text: text, actions: actions)
        banner.kind = .images
    }

    private func loadAllImages() {
        guard let d = current, let b = currentBody else { return }
        banner.isHidden = true
        render(d, b, forceImages: true)
    }

    // MARK: Script messages (click to load one image)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let s = body["load"] as? String, let id = Int(s),
              let page = loader.page else { return }
        page.forced.insert(id)
        let js = """
        document.querySelectorAll('img[data-lm="\(id)"]').forEach(function(e){
          e.removeAttribute('data-lm-blocked'); e.src = 'lm://img/\(page.generation)/\(id)?f=' + Date.now();
        });
        """
        webView?.evaluateJavaScript(js, in: nil, in: .defaultClient, completionHandler: nil)
    }

    // MARK: Navigation (links open in the default browser)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard current != nil, navigation === pendingNavigation else { return }
        pendingNavigation = nil
        Debug.log("open → rendered: \(Debug.ms(since: openStarted)) (\(openWasCached ? "cached" : "fetched")) webpid=\(webView.value(forKey: "_webProcessIdentifier") ?? "?")")
        onRendered?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            ExternalNavigation.open(url)
            return
        }
        // Only the app's own lm:// document and about:blank may navigate in place. Everything else,
        // including a custom scheme a sender might try, is swallowed rather than handed to LaunchServices.
        if url.scheme == "lm" || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    /// target="_blank" links and script-opened windows. Returning nil keeps WebKit from asking macOS
    /// to open a URL it cannot handle (the "There is no application set to open lm://…" alert).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { ExternalNavigation.open(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit can drop its content process under memory pressure; re-render quietly.
        if let d = current, let b = currentBody { render(d, b) }
    }

    // MARK: Attachments

    private func save(_ part: BodyPart) {
        guard let d = current, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = part.suggestedFilename
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.attachmentBar.setBusy(true, text: "Saving \(part.suggestedFilename)…")
            Task { @MainActor in
                // Busy always clears, including when the account is gone (B-06).
                defer { self?.attachmentBar.setBusy(false) }
                do {
                    guard let engine = MailService.shared.engine(d.accountID) else { throw NetError.server("Account unavailable") }
                    try await engine.download(messageID: d.id, part: part, to: url)
                    self?.showToast?("Saved \(url.lastPathComponent)")
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    self?.presentError(error)
                }
            }
        }
    }

    private func saveAll() {
        guard let d = current, let window = view.window, let parts = d.structure?.attachments(), !parts.isEmpty else { return }
        let panel = NSSavePanel()
        let base = d.subject.isEmpty ? "Attachments" : String(d.subject.prefix(60)).replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = base + " attachments.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let dest = panel.url else { return }
            self?.attachmentBar.setBusy(true, text: "Saving \(parts.count) attachments…")
            Task { @MainActor in
                let dir = AppPaths.tempDir("attachments")
                defer {
                    try? FileManager.default.removeItem(at: dir)
                    self?.attachmentBar.setBusy(false)
                }
                do {
                    guard let engine = MailService.shared.engine(d.accountID) else { throw NetError.server("Account unavailable") }
                    var used = Set<String>()
                    for p in parts {
                        let name = Self.uniqueName(p.suggestedFilename, used: &used)
                        try await engine.download(messageID: d.id, part: p, to: dir.appendingPathComponent(name))
                    }
                    try await AttachmentZip.zip(directory: dir, to: dest)
                    self?.showToast?("Saved \(dest.lastPathComponent)")
                } catch {
                    self?.presentError(error)
                }
            }
        }
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    // MARK: Header buttons

    private func unsubscribeURL(_ d: MessageDetail) -> URL? {
        let items = d.listUnsubscribe.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t"))
        }
        if let http = items.first(where: { $0.hasPrefix("http") }), let u = URL(string: http) { return u }
        if let mail = items.first(where: { $0.hasPrefix("mailto:") }), let u = URL(string: mail) { return u }
        return nil
    }

    @objc private func unsubscribe() {
        guard let d = current, let url = unsubscribeURL(d) else { return }
        if url.scheme == "mailto" {
            (NSApp.delegate as? AppDelegate)?.compose(mailto: url)
            return
        }
        // A slipped click shouldn't unsubscribe you or land you on a phishing page — confirm first.
        let alert = NSAlert()
        alert.messageText = "Unsubscribe from this mailing list?"
        alert.informativeText = "This will open \(url.host ?? url.absoluteString) in your browser."
        alert.addButton(withTitle: "Unsubscribe")
        alert.addButton(withTitle: "Cancel")
        if let w = view.window {
            alert.beginSheetModal(for: w) { resp in
                if resp == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func editDraft() {
        guard let d = current else { return }
        onEditDraft?(d)
    }

    // MARK: Web view lifecycle

    private var pendingNavigation: WKNavigation?

    private func ensureWebView() -> WKWebView {
        if let w = webView { return w }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(loader, forURLScheme: "lm")
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        if #available(macOS 14.0, *) { config.preferences.isTextInteractionEnabled = true }
        // Click-to-load for held-back images. Runs in the app's own script world; the email's scripts stay disabled.
        let js = """
        document.addEventListener('click', function(e){
          var t = e.target;
          if (t && t.tagName === 'IMG' && t.getAttribute('data-lm-blocked') === '1') {
            e.preventDefault(); e.stopPropagation();
            window.webkit.messageHandlers.lm.postMessage({load: t.getAttribute('data-lm')});
          }
        }, true);
        """
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        ucc.addUserScript(WKUserScript(source: DarkReader.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        // A weak proxy: WKUserContentController retains its handlers, which would otherwise keep this controller alive.
        ucc.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "lm")
        if let list = Self.ruleList { ucc.add(list) }
        let w = WKWebView(frame: .zero, configuration: config)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.setValue(false, forKey: "drawsBackground")
        w.allowsMagnification = true
        w.pageZoom = readingZoom
        w.translatesAutoresizingMaskIntoConstraints = false
        w.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(w)
        w.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        webSpacer.isHidden = true
        webView = w
        Debug.log("web view created")
        return w
    }

    /// Tears the web view down; WebKit's content/GPU/network processes exit shortly after.
    /// From here on no pending render or body fetch may create a new web view until the pane is shown again.
    func releaseWebView() {
        tornDown = true
        // Close Quick Look and drop its temp file now, not on the next Quick Look (C-25).
        if quickLookURL != nil || quickLookDir != nil {
            QuickLookController.shared.close()
            if let d = quickLookDir { try? FileManager.default.removeItem(at: d) }
            quickLookDir = nil
            quickLookURL = nil
        }
        guard let w = webView else { return }
        loader.cancelAll()
        w.stopLoading()
        w.navigationDelegate = nil
        w.configuration.userContentController.removeAllScriptMessageHandlers()
        w.removeFromSuperview()
        webSpacer.isHidden = false
        webView = nil
        pendingNavigation = nil
        lastRenderedDark = nil
        // The prepared HTML and image bookkeeping are rebuilt from currentBody on restore (O-17).
        loader.page = nil
        Debug.log("web view released")
    }

    /// Brings the open message back after the web view was released. A body fetch dropped by the
    /// teardown is started again, rather than leaving a header-only pane (F-03).
    func restoreWebViewIfNeeded() {
        tornDown = false
        guard webView == nil, let d = current else { return }
        if let b = currentBody {
            render(d, b)
        } else {
            fetchBody(for: d)
        }
    }

    // MARK: App-wide web view trimming (BUG-28)

    /// Releases the web views of every reading pane except the main window's (message windows keep one each),
    /// so idle/memory-pressure trims reach them all without the app delegate knowing about the windows.
    static func releaseWebViews(except main: PreviewViewController?) {
        for p in live.allObjects where p !== main { p.releaseWebView() }
    }

    /// Restores the reading panes whose window is actually visible.
    static func restoreWebViews(except main: PreviewViewController?) {
        for p in live.allObjects where p !== main && p.view.window?.isVisible == true { p.restoreWebViewIfNeeded() }
    }

    // MARK: Text zoom (View > Larger/Smaller/Actual Text)

    private var readingZoom: CGFloat {
        get {
            let v = Prefs.d.double(forKey: "readingZoom")
            return v > 0 ? CGFloat(v) : 1
        }
        set {
            let clamped = min(max(newValue, 0.5), 3)
            Prefs.d.set(Double(clamped), forKey: "readingZoom")
            webView?.pageZoom = clamped
        }
    }

    func zoomIn() { readingZoom += 0.1 }
    func zoomOut() { readingZoom -= 0.1 }
    func resetZoom() { readingZoom = 1 }

    // First-responder actions for the View menu (View > Actual Size / Zoom In / Zoom Out).
    @objc func zoomInReading(_ sender: Any?) { zoomIn() }
    @objc func zoomOutReading(_ sender: Any?) { zoomOut() }
    @objc func resetReadingZoom(_ sender: Any?) { resetZoom() }

    // MARK: Theme

    private var isDark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var lastRenderedDark: Bool?

    private func appearanceChanged() {
        updateLightButton()
        guard lastRenderedDark != isDark else { return }
        lastRenderedDark = isDark
        // The recolouring pass runs per page load, so re-render the open message for the new theme.
        if let d = current, let b = currentBody { render(d, b) }
    }

    private func updateLightButton() {
        lightButton.isHidden = !isDark || current == nil
        let on = current.map { lightBackground($0) } ?? false
        lightButton.image = NSImage(systemSymbolName: on ? "moon" : "sun.max", accessibilityDescription: nil)
        lightButton.toolTip = on ? "Show this message in dark mode (⌥⌘L)" : "Show this message with a light background (⌥⌘L)"
    }

    @objc func toggleLight() {
        guard let d = current, let b = currentBody, isDark else { NSSound.beep(); return }
        let key = Self.lightKey(d.from.email)
        Prefs.d.set(!Prefs.d.bool(forKey: key), forKey: key)
        render(d, b)
    }

    // MARK: Print (F-17)

    func printMessage() {
        guard let d = current, let web = webView, let window = view.window else { NSSound.beep(); return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .spool
        let op = web.printOperation(with: info)
        op.jobTitle = d.subject.isEmpty ? "Message" : d.subject
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        // WKWebView's print view has no size until laid out.
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Quick Look (F-15)

    private var quickLookURL: URL?
    private var quickLookDir: URL?

    private func quickLook(_ part: BodyPart) {
        guard let d = current else { return }
        attachmentBar.setBusy(true, text: "Opening \(part.suggestedFilename)…")
        let dir = AppPaths.tempDir("quicklook")
        let url = dir.appendingPathComponent(part.suggestedFilename)
        Task { @MainActor in
            defer { attachmentBar.setBusy(false) }
            do {
                guard let engine = MailService.shared.engine(d.accountID) else { throw NetError.server("Account unavailable") }
                try await engine.download(messageID: d.id, part: part, to: url)
                // The pane may have been torn down (window closed, WebKit released) while the download ran;
                // releaseWebView cleaned up an empty quickLookDir, so the file written now must not be orphaned.
                guard !tornDown else {
                    try? FileManager.default.removeItem(at: dir)
                    return
                }
                if let old = quickLookDir { try? FileManager.default.removeItem(at: old) }
                quickLookDir = dir
                quickLookURL = url
                QuickLookController.shared.show(url)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                presentError(error)
            }
        }
    }

    func saveAllAttachments() {
        if attachmentBar.isEmpty || attachmentBar.isHidden { NSSound.beep() } else { attachmentBar.triggerSaveAll() }
    }

    var currentDetail: MessageDetail? { current }
    var currentBodyValue: StoredBody? { currentBody }
}

/// The only bridge from rendered mail to the outside world. Custom schemes are never passed to
/// NSWorkspace/LaunchServices; that is what produced repeated "no application set to open lm://…" alerts.
@MainActor
enum ExternalNavigation {
    private static var lastOpen: (url: URL, at: Date)?

    static func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return }
        // A target="_blank" link can reach both the policy delegate and the UI delegate; avoid two tabs.
        if let lastOpen, lastOpen.url == url, Date().timeIntervalSince(lastOpen.at) < 0.75 { return }
        lastOpen = (url, Date())
        if scheme == "mailto" {
            (NSApp.delegate as? AppDelegate)?.compose(mailto: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Forwards script messages without the user content controller retaining the preview controller.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

// MARK: - Reading pane background

/// Same background as the email page (white in light mode, #1e1e1e in dark) so the header and message read as one surface.
final class ReadingPaneView: NSView {
    var onAppearanceChange: (() -> Void)?
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1) : .white
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Self.background.cgColor }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}

// MARK: - Banner

final class BannerView: NSView {
    /// What the banner is for, so a held-image notice never replaces the clipped-message banner (F-14).
    enum Kind { case general, clipped, images }
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private var handlers: [() -> Void] = []
    var kind: Kind = .general

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        for v in [icon, label, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, actions: [(String, () -> Void)]) {
        label.stringValue = text
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        handlers = actions.map { $0.1 }
        for (i, a) in actions.enumerated() {
            let b = NSButton(title: a.0, target: self, action: #selector(tapped(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            buttons.addArrangedSubview(b)
        }
        isHidden = false
    }

    @objc private func tapped(_ sender: NSButton) {
        guard sender.tag < handlers.count else { return }
        handlers[sender.tag]()
    }
}

// MARK: - Welcome (no accounts yet)

final class WelcomeView: NSView {
    var onAdd: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: NSImage(systemSymbolName: "envelope.open", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Welcome to Mac Mail")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "Add your Gmail account with an App Password. Your password stays in the macOS Keychain and mail syncs straight from Gmail.")
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        let button = NSButton(title: "Add Account…", target: self, action: #selector(add))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.controlSize = .large
        let stack = NSStackView(views: [icon, title, body, button])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func add() { onAdd?() }
}
