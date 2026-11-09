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
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let doc = try EMLDocument.parse(data)
            let c = EMLWindowController(doc: doc, url: url)
            open[key] = c
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
        } catch {
            let a = NSAlert(error: error)
            a.messageText = "Couldn't open “\(url.lastPathComponent)”"
            a.runModal()
        }
    }

    private let doc: EMLDocument
    private let url: URL
    private let loader = ImageLoader()
    private var web: WKWebView?
    private let banner = BannerView()
    private let attachmentBar = AttachmentBar()
    private var loadImages = false
    private var generation = 0

    private init(doc: EMLDocument, url: URL) {
        self.doc = doc
        self.url = url
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 520, height: 420)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.title = doc.subject.isEmpty ? url.deletingPathExtension().lastPathComponent : doc.subject
        w.representedURL = url
        super.init(window: w)
        w.delegate = self
        build()
        render()
        if let last = Self.open.values.compactMap({ $0.window }).last {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            w.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
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
        let parts = doc.structure.attachments()
        attachmentBar.set(parts)
        attachmentBar.isHidden = parts.isEmpty
        attachmentBar.onSave = { [weak self] p in self?.save(p) }
        attachmentBar.onSaveAll = { [weak self] in self?.saveAll() }
        attachmentBar.onQuickLook = { [weak self] p in self?.quickLook(p) }
        attachmentBar.provideFile = { [weak self] p, dest in
            guard let data = self?.doc.data(for: p) else { throw NetError.server("The attachment is empty.") }
            try data.write(to: dest, options: .atomic)
        }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(loader, forURLScheme: "lm")
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: DarkReader.script, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true, in: .defaultClient))
        if let list = PreviewViewController.ruleList { config.userContentController.add(list) }
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
        let attachHeight = attachmentBar.heightAnchor.constraint(equalToConstant: 0)
        attachHeight.isActive = parts.isEmpty
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
        guard let web else { return }
        generation += 1
        let (html, text) = doc.bodies()
        let prepared = HTMLPrep.prepare(html: html, text: text, clip: false, page: generation)
        // Remote images stay blocked until asked for: a file from someone else is untrusted.
        let page = ImagePage(generation: generation, messageID: 0, accountID: "", prepared: prepared,
                             autoLoad: loadImages, ignoreLimits: false)
        let doc = self.doc
        page.localCID = { cid in
            guard let part = doc.structure.part(withContentID: cid), let data = doc.data(for: part) else { return nil }
            return (data, part.mimeType)
        }
        page.dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        loader.page = page
        if prepared.hasRemoteImages && !loadImages {
            banner.show(text: "Images from the internet aren't loaded in saved messages.",
                        actions: [("Load images", { [weak self] in self?.loadImages = true; self?.banner.isHidden = true; self?.render() })])
        }
        web.loadHTMLString(prepared.html, baseURL: URL(string: "lm://message/0/"))
    }

    // MARK: Actions

    @objc private func replyTapped() {
        guard !MailService.shared.accounts.isEmpty else { return }
        let (html, text) = doc.bodies()
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
        op.jobTitle = doc.subject
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func save(_ part: BodyPart) {
        guard let window, let data = doc.data(for: part) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = part.suggestedFilename
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let dest = panel.url else { return }
            do { try data.write(to: dest, options: .atomic) } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    private func saveAll() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Attachments Here"
        panel.beginSheetModal(for: window) { [doc] resp in
            guard resp == .OK, let dir = panel.url else { return }
            var used = Set<String>()
            for p in doc.structure.attachments() {
                guard let data = doc.data(for: p) else { continue }
                let name = PreviewViewController.uniqueName(p.suggestedFilename, used: &used)
                try? data.write(to: dir.appendingPathComponent(name), options: .withoutOverwriting)
            }
        }
    }

    private var quickLookDir: URL?

    private func quickLook(_ part: BodyPart) {
        guard let data = doc.data(for: part) else { return }
        if let old = quickLookDir { try? FileManager.default.removeItem(at: old) }
        let dir = AppPaths.tempDir("quicklook")
        quickLookDir = dir
        let file = dir.appendingPathComponent(part.suggestedFilename)
        do {
            try data.write(to: file)
            QuickLookController.shared.show(file)
        } catch {
            NSSound.beep()
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
        loader.cancelAll()
        loader.page = nil
        web?.removeFromSuperview()
        web = nil
        if let d = quickLookDir { try? FileManager.default.removeItem(at: d) }
        Self.open[url.standardizedFileURL] = nil
    }
}
