import AppKit

/// Settings: Accounts (add / remove / signature) and General (offline window, images, reading, sending).
@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tabs = NSTabView()
    private let table = NSTableView()
    private let signature = NSTextView()
    private let nameField = NSTextField()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let defaultButton = NSButton(title: "Make Default", target: nil, action: nil)

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let accounts = NSTabViewItem(identifier: "accounts")
        accounts.label = "Accounts"
        accounts.view = accountsView()
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = generalView()
        tabs.addTabViewItem(accounts)
        tabs.addTabViewItem(general)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -12),
        ])
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAccounts), name: .mailAccountsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncThemePopup), name: .themeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Accounts tab

    private func accountsView() -> NSView {
        let v = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let col = NSTableColumn(identifier: .init("a"))
        col.title = "Account"
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        scroll.documentView = table

        let add = NSButton(title: "Add Account…", target: self, action: #selector(addAccount))
        add.bezelStyle = .rounded
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeAccount)
        defaultButton.bezelStyle = .rounded
        defaultButton.target = self
        defaultButton.action = #selector(makeDefault)

        let nameLabel = NSTextField(labelWithString: "Your name:")
        nameField.placeholderString = "Shown as the sender"
        nameField.target = self
        nameField.action = #selector(saveDetails)
        let sigLabel = NSTextField(labelWithString: "Signature:")
        signature.font = .systemFont(ofSize: 13)
        signature.isRichText = false
        signature.textContainerInset = NSSize(width: 4, height: 4)
        let sigScroll = NSScrollView()
        sigScroll.documentView = signature
        sigScroll.hasVerticalScroller = true
        sigScroll.borderType = .bezelBorder
        signature.isVerticallyResizable = true
        signature.autoresizingMask = [.width]
        signature.textContainer?.widthTracksTextView = true
        let save = NSButton(title: "Save", target: self, action: #selector(saveDetails))
        save.bezelStyle = .rounded

        for x in [scroll, add, removeButton, defaultButton, nameLabel, nameField, sigLabel, sigScroll, save] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            scroll.heightAnchor.constraint(equalToConstant: 120),
            add.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            add.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 8),
            defaultButton.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            defaultButton.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: sigScroll.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            sigLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            sigLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            sigScroll.topAnchor.constraint(equalTo: sigLabel.topAnchor),
            sigScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 84),
            sigScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            sigScroll.heightAnchor.constraint(equalToConstant: 90),
            save.topAnchor.constraint(equalTo: sigScroll.bottomAnchor, constant: 8),
            save.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
        ])
        reloadAccounts()
        return v
    }

    @objc private func reloadAccounts() {
        table.reloadData()
        if table.selectedRow < 0 && !MailService.shared.accounts.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        loadDetails()
    }

    private var selectedAccount: Account? {
        let list = MailService.shared.accounts
        return table.selectedRow >= 0 && table.selectedRow < list.count ? list[table.selectedRow] : nil
    }

    private func loadDetails() {
        let a = selectedAccount
        nameField.stringValue = a?.displayName ?? ""
        signature.string = a?.signature ?? ""
        nameField.isEnabled = a != nil
        signature.isEditable = a != nil
        removeButton.isEnabled = a != nil
        defaultButton.isEnabled = a != nil && MailService.shared.accounts.count > 1
    }

    @objc private func saveDetails() {
        guard var a = selectedAccount else { return }
        a.displayName = nameField.stringValue
        a.signature = signature.string
        MailService.shared.updateAccount(a)
    }

    @objc func addAccount() {
        guard let w = window else { return }
        let sheet = AddAccountSheet()
        w.beginSheet(sheet.window!) { _ in _ = sheet }
    }

    @objc private func removeAccount() {
        guard let a = selectedAccount, let w = window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(a.email)?"
        alert.informativeText = "Its offline mail is deleted from this Mac. Nothing is deleted from the server."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn { MailService.shared.removeAccount(a.id) }
        }
    }

    @objc private func makeDefault() {
        guard let a = selectedAccount else { return }
        Prefs.defaultAccountID = a.id
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { MailService.shared.accounts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = MailService.shared.accounts[row]
        let isDefault = MailService.shared.defaultAccount?.id == a.id && MailService.shared.accounts.count > 1
        let label = NSTextField(labelWithString: a.email + (isDefault ? "   (default)" : ""))
        let sub = NSTextField(labelWithString: a.provider.label + (a.displayName.isEmpty ? "" : " · " + a.displayName))
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadDetails() }

    // MARK: General tab

    private func generalView() -> NSView {
        let v = NSView()
        let days = NSPopUpButton()
        for d in [7, 14, 30, 60, 90] {
            days.addItem(withTitle: "\(d) days")
            days.lastItem?.tag = d
        }
        days.selectItem(withTag: Prefs.offlineDays)
        days.target = self
        days.action = #selector(daysChanged(_:))

        let group = NSButton(checkboxWithTitle: "Group by conversation in new folders", target: self, action: #selector(groupChanged(_:)))
        group.state = Prefs.groupByConversationDefault ? .on : .off
        let markRead = NSButton(checkboxWithTitle: "Mark messages as read when opened", target: self, action: #selector(markReadChanged(_:)))
        markRead.state = Prefs.markReadOnOpen ? .on : .off
        let ask = NSButton(checkboxWithTitle: "Ask before loading any remote images", target: self, action: #selector(askChanged(_:)))
        ask.state = Prefs.askBeforeImages ? .on : .off
        let notify = NSButton(checkboxWithTitle: "Notify about new mail while Mac Mail is open", target: self, action: #selector(notifyChanged(_:)))
        notify.state = Prefs.notifyNewMail ? .on : .off

        let perImage = NSPopUpButton()
        for mb in [0.5, 1, 2, 5, 10] {
            perImage.addItem(withTitle: mb < 1 ? "500 KB" : "\(Int(mb)) MB")
            perImage.lastItem?.representedObject = mb
        }
        perImage.selectItem(at: [0.5, 1, 2, 5, 10].firstIndex(of: Prefs.imageMaxMB) ?? 2)
        perImage.target = self
        perImage.action = #selector(perImageChanged(_:))
        let perMessage = NSPopUpButton()
        for mb in [5.0, 10, 20, 50] {
            perMessage.addItem(withTitle: "\(Int(mb)) MB")
            perMessage.lastItem?.representedObject = mb
        }
        perMessage.selectItem(at: [5.0, 10, 20, 50].firstIndex(of: Prefs.imageMessageMaxMB) ?? 1)
        perMessage.target = self
        perMessage.action = #selector(perMessageChanged(_:))

        let undo = NSPopUpButton()
        for s in [0, 5, 10, 20, 30] {
            undo.addItem(withTitle: s == 0 ? "Off" : "\(s) seconds")
            undo.lastItem?.tag = s
        }
        undo.selectItem(withTag: Prefs.undoSendSeconds)
        undo.target = self
        undo.action = #selector(undoChanged(_:))

        let defaultMail = NSButton(title: "Make Mac Mail the Default Email App", target: self, action: #selector(makeDefaultMailApp))
        defaultMail.bezelStyle = .rounded

        let imageNote = NSTextField(wrappingLabelWithString:
            "Images up to the size limit load automatically and are shrunk to screen size. Bigger ones show a “Load image” box. Images in Spam never load on their own.")
        imageNote.font = .systemFont(ofSize: 11)
        imageNote.textColor = .secondaryLabelColor

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let theme = NSPopUpButton()
        for t in Prefs.Theme.allCases {
            theme.addItem(withTitle: t.label)
            theme.lastItem?.representedObject = t.rawValue
        }
        theme.selectItem(at: Prefs.Theme.allCases.firstIndex(of: Prefs.theme) ?? 0)
        theme.target = self
        theme.action = #selector(themeChanged(_:))
        themePopup = theme

        let grid = NSGridView(views: [
            [label("Appearance:"), theme],
            [label("Keep offline:"), days],
            [NSGridCell.emptyContentView, group],
            [NSGridCell.emptyContentView, markRead],
            [label("Auto-load images up to:"), perImage],
            [label("Per message, up to:"), perMessage],
            [NSGridCell.emptyContentView, imageNote],
            [NSGridCell.emptyContentView, ask],
            [label("Undo Send:"), undo],
            [NSGridCell.emptyContentView, notify],
            [NSGridCell.emptyContentView, defaultMail],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        imageNote.widthAnchor.constraint(equalToConstant: 340).isActive = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            grid.centerXAnchor.constraint(equalTo: v.centerXAnchor),
        ])
        return v
    }

    private weak var themePopup: NSPopUpButton?

    @objc private func themeChanged(_ s: NSPopUpButton) {
        guard let raw = s.selectedItem?.representedObject as? String, let t = Prefs.Theme(rawValue: raw) else { return }
        Prefs.theme = t
        AppDelegate.applyTheme(t)
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    @objc private func syncThemePopup() {
        themePopup?.selectItem(at: Prefs.Theme.allCases.firstIndex(of: Prefs.theme) ?? 0)
    }

    @objc private func daysChanged(_ s: NSPopUpButton) { Prefs.offlineDays = s.selectedTag() }
    @objc private func groupChanged(_ s: NSButton) { Prefs.groupByConversationDefault = s.state == .on }
    @objc private func markReadChanged(_ s: NSButton) { Prefs.markReadOnOpen = s.state == .on }
    @objc private func askChanged(_ s: NSButton) { Prefs.askBeforeImages = s.state == .on }
    @objc private func notifyChanged(_ s: NSButton) { Prefs.notifyNewMail = s.state == .on }
    @objc private func undoChanged(_ s: NSPopUpButton) { Prefs.undoSendSeconds = s.selectedTag() }
    @objc private func perImageChanged(_ s: NSPopUpButton) { Prefs.imageMaxMB = s.selectedItem?.representedObject as? Double ?? 2 }
    @objc private func perMessageChanged(_ s: NSPopUpButton) { Prefs.imageMessageMaxMB = s.selectedItem?.representedObject as? Double ?? 10 }

    @objc private func makeDefaultMailApp() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { [weak self] error in
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = error == nil ? "Mac Mail is now your default email app." : "Couldn't change the default email app."
                if let error { a.informativeText = error.localizedDescription }
                if let w = self?.window { a.beginSheetModal(for: w) }
            }
        }
    }

    func show(tab: String) {
        tabs.selectTabViewItem(withIdentifier: tab)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Sign-in sheet. Gmail needs an App Password (Google account → Security → 2-Step Verification → App passwords).
@MainActor
final class AddAccountSheet: NSWindowController {
    private let provider = NSPopUpButton()
    private let name = NSTextField()
    private let email = NSTextField()
    private let password = NSSecureTextField()
    private let imapHost = NSTextField()
    private let imapPort = NSTextField()
    private let smtpHost = NSTextField()
    private let smtpPort = NSTextField()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let signIn = NSButton(title: "Sign In", target: nil, action: nil)
    private var serverRows: [NSGridRow] = []

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Add a mail account")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        provider.addItems(withTitles: ["Gmail", "Other (IMAP over SSL)"])
        provider.target = self
        provider.action = #selector(providerChanged)
        name.placeholderString = "Your name"
        email.placeholderString = "you@gmail.com"
        password.placeholderString = "16-character App Password"
        imapHost.placeholderString = "imap.example.com"
        imapPort.stringValue = "993"
        smtpHost.placeholderString = "smtp.example.com"
        smtpPort.stringValue = "465"
        let help = NSButton(title: "How do I get an App Password?", target: self, action: #selector(openHelp))
        help.bezelStyle = .inline
        help.isBordered = false
        help.contentTintColor = .linkColor
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: 12)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        func l(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.alignment = .right; return t }
        let grid = NSGridView(views: [
            [l("Provider:"), provider],
            [l("Name:"), name],
            [l("Email:"), email],
            [l("App Password:"), password],
            [NSGridCell.emptyContentView, help],
            [l("IMAP server:"), imapHost],
            [l("IMAP port:"), imapPort],
            [l("SMTP server:"), smtpHost],
            [l("SMTP port:"), smtpPort],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for f in [name, email, password, imapHost, smtpHost] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        serverRows = (5...8).map { grid.row(at: $0) }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        signIn.bezelStyle = .rounded
        signIn.keyEquivalent = "\r"
        signIn.target = self
        signIn.action = #selector(submit)
        let note = NSTextField(wrappingLabelWithString: "The App Password is stored only in your Mac's Keychain.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        for v in [title, grid, error, note, spinner, cancel, signIn] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            error.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            error.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            error.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: error.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: error.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: error.trailingAnchor),
            signIn.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            signIn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            signIn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: signIn.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: signIn.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: signIn.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -10),
        ])
        providerChanged()
    }

    @objc private func providerChanged() {
        let other = provider.indexOfSelectedItem == 1
        for r in serverRows { r.isHidden = !other }
        email.placeholderString = other ? "you@example.com" : "you@gmail.com"
        password.placeholderString = other ? "Password or app password" : "16-character App Password"
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://myaccount.google.com/apppasswords")!)
    }

    @objc private func cancel() {
        guard let w = window else { return }
        w.sheetParent?.endSheet(w)
    }

    @objc private func submit() {
        let mail = email.stringValue.trimmingCharacters(in: .whitespaces)
        // App Passwords are shown with spaces; Google accepts them without.
        let pass = password.stringValue.replacingOccurrences(of: " ", with: "")
        guard mail.contains("@"), !pass.isEmpty else {
            error.stringValue = "Enter your email address and App Password."
            return
        }
        if MailService.shared.accounts.contains(where: { $0.email.lowercased() == mail.lowercased() }) {
            error.stringValue = "\(mail) is already added."
            return
        }
        var account: Account
        if provider.indexOfSelectedItem == 0 {
            account = Account.gmail(email: mail, name: name.stringValue)
        } else {
            guard !imapHost.stringValue.isEmpty, !smtpHost.stringValue.isEmpty else {
                error.stringValue = "Enter the IMAP and SMTP servers."
                return
            }
            account = Account(id: UUID().uuidString, email: mail, displayName: name.stringValue, provider: .imap, username: mail,
                              imapHost: imapHost.stringValue, imapPort: UInt16(imapPort.stringValue) ?? 993,
                              smtpHost: smtpHost.stringValue, smtpPort: UInt16(smtpPort.stringValue) ?? 465, signature: "")
        }
        if account.displayName.isEmpty { account.displayName = String(mail.split(separator: "@").first ?? "") }
        error.stringValue = ""
        spinner.startAnimation(nil)
        signIn.isEnabled = false
        Task {
            do {
                try await MailService.shared.addAccount(account, password: pass)
                spinner.stopAnimation(nil)
                if let w = window { w.sheetParent?.endSheet(w) }
                (NSApp.delegate as? AppDelegate)?.mainWindow?.window?.makeKeyAndOrderFront(nil)
            } catch let e {
                spinner.stopAnimation(nil)
                signIn.isEnabled = true
                var msg = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
                if account.provider == .gmail, case NetError.auth = e {
                    msg += " Use an App Password, not your normal Google password. 2-Step Verification must be on."
                }
                error.stringValue = msg
            }
        }
    }
}
