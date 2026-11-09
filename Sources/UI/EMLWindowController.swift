import AppKit
import WebKit

/// A message opened from a .eml file (Finder double-click, Open With, drag to the Dock): an offline copy shown
/// with the same protections as the reading pane — scripts off, remote content blocked until asked for, inline
/// images from the file itself. Attachments can be saved, previewed and dragged out. Nothing touches a server
/// or the mail cache.
@MainActor
final class EMLWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static var open: [URL: EMLWindowController] = [:]

    static func show(_ url: URL) {
        let key = url.standardizedFileURL
        if let existing = open[key] { existing.window?.makeKeyAndOrderFront(nil); return }
        let c = EMLWindowController(url: url)
        open[key] = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.load()
    }

    private var doc: EMLDocument?
    private let url: URL
    private let loader = ImageLoader()
    private var web: WKWebView?
    private let banner = BannerView()
    private let attachmentBar = AttachmentBar()
    private var loadImages = false
    private var generation = 0
    private var renderAttempt = 0
    private var ruleListAttached = false
    private var closed = false
    /// Decoded once with the file, so Reply doesn't decode the message again.
    private var bodies: (html: String?, text: String?) = (html: nil, text: nil)
    private var lastRenderedDark: Bool?
    /// Required zero height while the banner is hidden, so no space is reserved for it.
    private var bannerCollapse: NSLayoutConstraint?

    private init(url: URL) {
        self.url = url
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 520, height: 420)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.title = url.deletingPathExtension().lastPathComponent
        w.representedURL = url
        super.init(window: w)
        let content = EMLContentView(frame: .zero)
        w.contentView = content
        content.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        w.delegate = self
        if let last = Self.open.values.compactMap({ $0.window }).last {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            w.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Reads, parses and decodes on a background thread; the window is already on screen and is filled in after.
    private func load() {
        let url = self.url
        Task { @MainActor [weak self] in
            do {
                let (doc, bodies) = try await Task.detached(priority: .userInitiated) {
                    let doc = try EMLDocument.parse(Data(contentsOf: url, options: .mappedIfSafe))
                    return (doc, doc.bodies())
                }.value
                guard let self, !self.closed else { return }
                self.doc = doc
                self.bodies = bodies
                self.window?.title = doc.subject.isEmpty ? url.deletingPathExtension().lastPathComponent : doc.subject
                self.build()
                self.render()
            } catch {
                guard let self, !self.closed else { return }
                self.close()
                let a = NSAlert(error: error)
                a.messageText = "Couldn't open “\(url.lastPathComponent)”"
                a.runModal()
            }
        }
    }

    private func build() {
        guard let content = window?.contentView, let doc else { return }
        let subject = NSTextField(wrappingLabelWithString: doc.subject.isEmpty ? "(no subject)" : doc.subject)
        subject.font = .systemFont(ofSize: 18, weight: .semibold)
        subject.isSelectable = true
        let from = NSTextField(labelWithString: doc.from.name.isEmpty ? doc.from.email : "\(doc.from.name)  <\(doc.from.email)>")
        from.font = .systemFont(ofSize: 13, weight: .medium)
        from.isSelectable = true
        var toText = "To: " + MIME.parseAddresses(doc.to).map { $0.display }.joined(separator: ", ")
        if !doc.cc.isEmpty { toText += "   Cc: " + MIME.parseAddresses(doc.cc).map { $0.display }.joined(separator: ", ") }
        let to = NSTextField(labelWithString: toText)
        to.font = .systemFont(ofSize: 12)
        to.textColor = .secondaryLabelColor
        to.lineBreakMode = .byTruncatingTail
        to.isSelectable = true
        let date = NSTextField(labelWithString: doc.date.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        } ?? "")
        date.font = .systemFont(ofSize: 12)
        date.textColor = .secondaryLabelColor
        let note = NSTextField(labelWithString: "Saved message · \(url.lastPathComponent)")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingMiddle
        let reply = NSButton(title: "Reply", target: self, action: #selector(replyTapped))
        reply.bezelStyle = .rounded
        reply.controlSize = .small
        reply.isHidden = MailService.shared.accounts.isEmpty
        let sep = NSBox()
        sep.boxType = .separator

        banner.isHidden = true
        let bannerCollapse = banner.heightAnchor.constraint(equalToConstant: 0)
        bannerCollapse.isActive = true
        self.bannerCollapse = bannerCollapse
        let parts = doc.structure.attachments()
        attachmentBar.set(parts)
        attachmentBar.setCollapsed(parts.isEmpty)
        attachmentBar.onSave = { [weak self] p in self?.save(p) }
        attachmentBar.onSaveAll = { [weak self] in self?.saveAll() }
        attachmentBar.onQuickLook = { [weak self] p in self?.quickLook(p) }
        attachmentBar.provideFile = { [weak self] p, dest in
            guard let doc = self?.doc else { throw NetError.server("The attachment is empty.") }
            // Decode and write off the main thread: a drag promise may be tens of MB.
            try await Task.detached(priority: .userInitiated) {
                guard let data = doc.data(for: p) else { throw NetError.server("The attachment is empty.") }
                try data.write(to: dest, options: .atomic)
            }.value
        }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(loader, forURLScheme: "lm")
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: DarkReader.script, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        self.web = web

        for v in [subject, from, to, date, note, reply, sep, banner, attachmentBar, web] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        from.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        to.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            subject.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            subject.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: reply.leadingAnchor, constant: -8),
            reply.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            reply.centerYAnchor.constraint(equalTo: subject.centerYAnchor),
            from.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 8),
            from.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
            from.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -12),
            date.firstBaselineAnchor.constraint(equalTo: from.firstBaselineAnchor),
            date.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            to.topAnchor.constraint(equalTo: from.bottomAnchor, constant: 3),
            to.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
            to.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: to.bottomAnchor, constant: 3),
            note.leadingAnchor.constraint(equalTo: subject.leadingAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            sep.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            banner.topAnchor.constraint(equalTo: sep.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            attachmentBar.topAnchor.constraint(equalTo: banner.bottomAnchor),
            attachmentBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            attachmentBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.topAnchor.constraint(equalTo: attachmentBar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func render() {
        guard let web, let doc else { return }
        lastRenderedDark = isDark
        // Fail closed like the reading pane: nothing renders until the remote-load block list is attached.
        // The wait is capped at ~2 s; after that the CSP meta alone guards the render (C-24).
        if PreviewViewController.ruleList == nil, !PreviewViewController.ruleListFailed {
            guard renderAttempt < 100 else {
                Debug.log("content rule list unavailable after 2 s; rendering with CSP only")
                PreviewViewController.ruleListFailed = true
                renderAttempt = 0
                return render()
            }
            renderAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, self.web != nil else { return }
                self.render()
            }
            return
        }
        renderAttempt = 0
        // The rule list is usually compiled after this window's web view was created, so attach it here,
        // after the wait above, rather than only from the configuration in build() (C-24).
        if !ruleListAttached, let list = PreviewViewController.ruleList {
            web.configuration.userContentController.add(list)
            ruleListAttached = true
        }
        generation += 1
        let gen = generation
        let bodies = self.bodies
        // Rewriting large HTML takes real time; prepare it off the main thread like the reading pane does.
        Task { @MainActor [weak self] in
            let prepared = await HTMLPrep.prepareOffMain(html: bodies.html, text: bodies.text, clip: false, page: gen)
            guard let self, gen == self.generation, !self.closed, let web = self.web else { return }
            // Remote images stay blocked until asked for: a file from someone else is untrusted.
            let page = ImagePage(generation: gen, messageID: 0, accountID: "", prepared: prepared,
                                 autoLoad: self.loadImages, ignoreLimits: false)
            page.localCID = { cid in
                guard let part = doc.structure.part(withContentID: cid), let data = doc.data(for: part) else { return nil }
                return (data, part.mimeType)
            }
            page.dark = self.isDark
            self.loader.page = page
            if prepared.hasRemoteImages && !self.loadImages {
                self.showBanner(text: "Images from the internet aren't loaded in saved messages.",
                                actions: [("Load images", { [weak self] in self?.loadImages = true; self?.hideBanner(); self?.render() })])
            }
            web.loadHTMLString(prepared.html, baseURL: URL(string: "lm://message/0/"))
        }
    }

    private var isDark: Bool { window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The page's image placeholders are baked per appearance, so a theme switch re-renders it.
    private func appearanceChanged() {
        guard doc != nil, !closed, lastRenderedDark != isDark else { return }
        render()
    }

    private func showBanner(text: String, actions: [(String, () -> Void)]) {
        bannerCollapse?.isActive = false
        banner.isHidden = false
        banner.show(text: text, actions: actions)
    }

    private func hideBanner() {
        banner.isHidden = true
        bannerCollapse?.isActive = true
    }

    // MARK: Actions

    @objc private func replyTapped() {
        guard !MailService.shared.accounts.isEmpty, let doc else { return }
        let (html, text) = bodies
        let d = MessageDetail(id: 0, folderID: 0, accountID: MailService.shared.defaultAccount?.id ?? "", uid: 0,
                              date: doc.date ?? Date(), flags: [], subject: doc.subject, from: doc.from, toList: doc.to,
                              ccList: doc.cc, replyTo: doc.headers["reply-to"] ?? "", messageIDHeader: doc.headers["message-id"] ?? "",
                              references: doc.headers["references"] ?? "", listUnsubscribe: "", structure: nil, size: 0,
                              folderRole: .none)
        ComposeWindowController.open(.reply(d, StoredBody(html: html, text: text), all: false))
    }

    @objc func printMessage(_ sender: Any?) {
        guard let web, let window else { return }
        let op = web.printOperation(with: NSPrintInfo.shared)
        op.jobTitle = doc?.subject ?? ""
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func save(_ part: BodyPart) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = part.suggestedFilename
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let dest = panel.url, let doc = self?.doc else { return }
            Task { @MainActor in
                do {
                    // Decode (base64 can be tens of MB) and write off the main thread.
                    try await Task.detached(priority: .userInitiated) {
                        guard let data = doc.data(for: part) else { throw NetError.server("The attachment is empty.") }
                        try data.write(to: dest, options: .atomic)
                    }.value
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func saveAll() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Attachments Here"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let dir = panel.url, let doc = self?.doc else { return }
            Task { @MainActor in
                // Names already in the folder count as used, so a collision saves as "name 2" instead of failing.
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                var used = Set(existing.map { $0.lowercased() })
                let named = doc.structure.attachments().map {
                    (part: $0, name: PreviewViewController.uniqueName($0.suggestedFilename, used: &used))
                }
                // Write every attachment off the main thread and report what couldn't be written in one alert.
                let skipped = await Task.detached(priority: .userInitiated) {
                    var skipped: [String] = []
                    for (p, name) in named {
                        guard let data = doc.data(for: p) else { skipped.append(name); continue }
                        do {
                            try data.write(to: dir.appendingPathComponent(name), options: .withoutOverwriting)
                        } catch {
                            skipped.append(name)
                        }
                    }
                    return skipped
                }.value
                guard !skipped.isEmpty, let self, !self.closed, let window = self.window else { return }
                let a = NSAlert()
                a.messageText = "Some attachments weren't saved"
                a.informativeText = skipped.joined(separator: "\n")
                a.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private var quickLookDir: URL?

    private func quickLook(_ part: BodyPart) {
        guard let doc else { return }
        let dir = AppPaths.tempDir("quicklook")
        let file = dir.appendingPathComponent(part.suggestedFilename)
        Task { @MainActor in
            do {
                // Decode and write off the main thread.
                try await Task.detached(priority: .userInitiated) {
                    guard let data = doc.data(for: part) else { throw NetError.server("The attachment is empty.") }
                    try data.write(to: file, options: .atomic)
                }.value
                // The window may have closed while the file was being written; nobody would then delete it.
                guard !self.closed else { try? FileManager.default.removeItem(at: dir); return }
                if let old = quickLookDir { try? FileManager.default.removeItem(at: old) }
                quickLookDir = dir
                QuickLookController.shared.show(file)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                if !self.closed { NSSound.beep() }
            }
        }
    }

    // MARK: Navigation: links open in the browser; nothing else loads.

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            ExternalNavigation.open(u)
            return
        }
        decisionHandler(u.scheme == "lm" || u.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { ExternalNavigation.open(u) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        loader.cancelAll()
        loader.page = nil
        if let web {
            web.stopLoading()
            web.navigationDelegate = nil
            web.removeFromSuperview()
        }
        web = nil
        // Close Quick Look before deleting its temp file, so it never previews a deleted attachment.
        if quickLookDir != nil { QuickLookController.shared.close() }
        if let d = quickLookDir { try? FileManager.default.removeItem(at: d) }
        quickLookDir = nil
        Self.open[url.standardizedFileURL] = nil
    }
}

/// Calls back when the window's effective appearance changes (a dark-mode switch), so the page can re-render.
private final class EMLContentView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
