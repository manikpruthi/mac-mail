import AppKit
import UserNotifications

/// Settings: Accounts (add / remove / signature) and General (offline window, images, reading, sending).
@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate,
                                       NSTextFieldDelegate, NSTabViewDelegate {
    private let tabs = NSTabView()
    private let table = NSTableView()
    private let signature = NSTextView()
    private let nameField = NSTextField()
    private let addButton = NSButton(title: "Add Account…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let defaultButton = NSButton(title: "Make Default", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit Account…", target: nil, action: nil)
    private let notifyBox = NSButton(checkboxWithTitle: "Notify about new mail in this account", target: nil, action: nil)
    private let notifyNote = NSTextField(wrappingLabelWithString: "")
    private let notifyFix = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Name/signature edits not yet saved, and which account they belong to (B-10).
    private var detailsDirty = false
    private var loadedAccountID: String?
    /// The one sheet open on this window, if any (C-17).
    private var accountSheet: AddAccountSheet?
    /// Bumped per storage refresh so a slow background read can't overwrite newer figures (C-33).
    private var storageGeneration = 0
    /// Bumped per notification-status query so a late answer can't label the wrong account (C-32).
    private var notifyGeneration = 0

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
        let storage = NSTabViewItem(identifier: "storage")
        storage.label = "Storage"
        storage.view = storageView()
        tabs.addTabViewItem(accounts)
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(storage)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -12),
        ])
        w.center()
        tabs.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAccounts), name: .mailAccountsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncThemePopup), name: .themeChanged, object: nil)
        // Closing the window must not silently drop edited name/signature text (C-16).
        NotificationCenter.default.addObserver(self, selector: #selector(settingsWindowWillClose), name: NSWindow.willCloseNotification, object: w)
        // Coming back from System Settings re-reads whether notifications are allowed (C-32).
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
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

        let add = addButton
        add.target = self
        add.action = #selector(addAccount)
        add.bezelStyle = .rounded
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeAccount)
        defaultButton.bezelStyle = .rounded
        defaultButton.target = self
        defaultButton.action = #selector(makeDefault)
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelectedAccount)
        notifyBox.target = self
        notifyBox.action = #selector(notifyToggled)
        // Shown only when macOS authorization is denied, so an "On" switch is never a silent lie (C-32).
        notifyNote.font = .systemFont(ofSize: 11)
        notifyNote.textColor = .systemOrange
        notifyNote.isHidden = true
        notifyFix.bezelStyle = .inline
        notifyFix.isBordered = false
        notifyFix.contentTintColor = .linkColor
        notifyFix.target = self
        notifyFix.action = #selector(openNotificationSettings)
        notifyFix.isHidden = true

        let nameLabel = NSTextField(labelWithString: "Your name:")
        nameField.placeholderString = "Shown as the sender"
        nameField.target = self
        nameField.action = #selector(saveDetails)
        nameField.delegate = self
        let sigLabel = NSTextField(labelWithString: "Signature:")
        signature.font = .systemFont(ofSize: 13)
        signature.isRichText = false
        signature.delegate = self
        signature.textContainerInset = NSSize(width: 4, height: 4)
        let sigScroll = NSScrollView()
        sigScroll.documentView = signature
        sigScroll.hasVerticalScroller = true
        sigScroll.borderType = .bezelBorder
        signature.isVerticallyResizable = true
        signature.autoresizingMask = [.width]
        signature.textContainer?.widthTracksTextView = true
        let save = saveButton
        save.target = self
        save.action = #selector(saveDetails)
        save.bezelStyle = .rounded

        for x in [scroll, add, removeButton, defaultButton, editButton, nameLabel, nameField, sigLabel, sigScroll, save, notifyBox,
                  notifyNote, notifyFix] as [NSView] {
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
            editButton.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
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
            notifyBox.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            notifyBox.leadingAnchor.constraint(equalTo: sigScroll.leadingAnchor),
            notifyNote.topAnchor.constraint(equalTo: save.bottomAnchor, constant: 10),
            notifyNote.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            notifyNote.trailingAnchor.constraint(equalTo: notifyFix.leadingAnchor, constant: -8),
            notifyFix.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            notifyFix.centerYAnchor.constraint(equalTo: notifyNote.centerYAnchor),
        ])
        reloadAccounts()
        return v
    }

    @objc private func reloadAccounts() {
        // An account added, edited or removed elsewhere must not silently drop text typed here.
        commitDetails(for: loadedAccountID)
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
        loadedAccountID = a?.id
        nameField.stringValue = a?.displayName ?? ""
        signature.string = a?.signature ?? ""
        nameField.isEnabled = a != nil
        signature.isEditable = a != nil
        addButton.isEnabled = accountSheet == nil
        removeButton.isEnabled = a != nil
        editButton.isEnabled = a != nil && a?.provider != .demo && accountSheet == nil
        notifyBox.isEnabled = a != nil
        notifyBox.state = a.map { Prefs.notifications(for: $0.id) } ?? false ? .on : .off
        defaultButton.isEnabled = a != nil && MailService.shared.accounts.count > 1
        detailsDirty = false
        saveButton.isEnabled = false
        refreshNotificationStatus()
    }

    func textDidChange(_ notification: Notification) { markDetailsDirty() }
    func controlTextDidChange(_ obj: Notification) { markDetailsDirty() }

    private func markDetailsDirty() {
        detailsDirty = true
        saveButton.isEnabled = true
    }

    @objc private func saveDetails() {
        commitDetails(for: loadedAccountID)
    }

    /// Writes the name/signature edits to the account they were made for.
    private func commitDetails(for id: String?) {
        guard detailsDirty, let id, var a = MailService.shared.account(id) else { return }
        a.displayName = nameField.stringValue
        a.signature = signature.string
        detailsDirty = false
        saveButton.isEnabled = false
        MailService.shared.updateAccount(a)
    }

    /// Closing the window saves pending edits instead of losing them (C-16).
    @objc private func settingsWindowWillClose() {
        commitPendingEdits()
    }

    /// Saves name/signature edits typed but not committed (window close and quit, C-16).
    func commitPendingEdits() {
        // A text field's value lives in its editor until editing ends; commit it to the control first.
        window?.makeFirstResponder(nil)
        commitDetails(for: loadedAccountID)
    }

    @objc private func notifyToggled() {
        guard let a = selectedAccount else { return }
        let on = notifyBox.state == .on
        Prefs.setNotifications(on, for: a.id)
        guard on else {
            refreshNotificationStatus()
            return
        }
        // Ask macOS now, when the user switches notifications on, not at the first delivery (C-32).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshNotificationStatus() } }
        }
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func appDidBecomeActive() {
        refreshNotificationStatus()
    }

    /// Says that macOS is blocking alerts, so an "On" switch is never a silent lie (C-32).
    private func refreshNotificationStatus() {
        notifyGeneration += 1
        let generation = notifyGeneration
        guard let a = selectedAccount, Prefs.notifications(for: a.id) else {
            setNotificationWarning(false)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.notifyGeneration == generation, self.selectedAccount?.id == a.id else { return }
                    self.setNotificationWarning(denied)
                }
            }
        }
    }

    private func setNotificationWarning(_ show: Bool) {
        notifyNote.stringValue = show ? "macOS is blocking Mac Mail notifications." : ""
        notifyNote.isHidden = !show
        notifyFix.isHidden = !show
    }

    @objc private func editSelectedAccount() {
        guard let a = selectedAccount else { return }
        editAccount(a.id)
    }

    /// Account editor / Sign in again (F-04): servers, ports, logins, security and the password.
    func editAccount(_ id: String) {
        guard let a = MailService.shared.account(id), a.provider != .demo else { return }
        present(AddAccountSheet(editing: a))
    }

    @objc func addAccount() {
        present(AddAccountSheet())
    }

    /// One sheet at a time (C-17): a second click or menu command must not stack a sheet on the window
    /// (AppKit raises) or leave the first probe running out of sight.
    private func present(_ sheet: AddAccountSheet) {
        guard let w = window, w.attachedSheet == nil, accountSheet == nil else { return }
        accountSheet = sheet
        addButton.isEnabled = false
        editButton.isEnabled = false
        w.beginSheet(sheet.window!) { [weak self] _ in
            // Ending the sheet (Cancel, Esc or success) stops an in-flight credential probe.
            sheet.cancelProbe()
            self?.accountSheet = nil
            self?.loadDetails()
        }
    }

    @objc private func removeAccount() {
        guard let a = selectedAccount, let w = window, w.attachedSheet == nil else { return }
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

    /// Switching accounts commits pending name/signature edits to the account they were typed for (B-10).
    func tableViewSelectionDidChange(_ notification: Notification) {
        commitDetails(for: loadedAccountID)
        loadDetails()
    }

    /// Storage figures are read when that tab is opened, not when Settings is created (C-33).
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard tabViewItem?.identifier as? String == "storage" else { return }
        refreshStorage()
    }

    // MARK: Storage tab (F-26)

    private let storageInfo = NSTextField(wrappingLabelWithString: "")
    private let clearBodiesButton = NSButton(title: "Clear Message Text Cache…", target: nil, action: nil)

    private func storageView() -> NSView {
        let v = NSView()
        storageInfo.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        storageInfo.isSelectable = true
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshStorage))
        clearBodiesButton.target = self
        clearBodiesButton.action = #selector(clearBodies)
        let clearImages = NSButton(title: "Clear Image Cache", target: self, action: #selector(clearImages))
        let pruneNow = NSButton(title: "Prune Now", target: self, action: #selector(pruneNow))
        let exportLog = NSButton(title: "Export Diagnostics Log…", target: self, action: #selector(exportLog))
        for b in [refresh, clearBodiesButton, clearImages, pruneNow, exportLog] { b.bezelStyle = .rounded }
        let note = NSTextField(wrappingLabelWithString: "Cleared message text is downloaded again when you open a message. Nothing is deleted from the server. The diagnostics log holds connection and sync errors only — never message content or passwords.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [refresh, pruneNow, clearBodiesButton, clearImages])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for x in [storageInfo, buttons, exportLog, note] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            storageInfo.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
            storageInfo.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            storageInfo.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: storageInfo.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: storageInfo.leadingAnchor),
            exportLog.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            exportLog.leadingAnchor.constraint(equalTo: storageInfo.leadingAnchor),
            note.topAnchor.constraint(equalTo: exportLog.bottomAnchor, constant: 14),
            note.leadingAnchor.constraint(equalTo: storageInfo.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: storageInfo.trailingAnchor),
        ])
        // The figures are read when the tab is opened, never while Settings is being created (C-33).
        return v
    }

    /// Storage figures are counted on a utility queue with its own connection: the SQL and the file sizes
    /// never run on the main thread (C-33).
    @objc private func refreshStorage() {
        let service = MailService.shared
        let prune = service.lastPrune.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "not yet this session"
        storageInfo.stringValue = [
            "Mail cache:      calculating…",
            "Image cache:     calculating…",
            "Outbox:          \(service.outbox.items.count) waiting",
            "Queued actions:  calculating…",
            "Offline window:  \(Prefs.offlineDays) days (newest 200 per folder always kept)",
            "Last prune:      \(prune)",
        ].joined(separator: "\n")
        storageGeneration += 1
        let generation = storageGeneration
        let path = service.store.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let stats = Store.stats(path: path)
            let images = AppPaths.directorySize(AppPaths.imageCache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.storageGeneration == generation else { return }
                    self.showStorage(stats, images: images)
                }
            }
        }
    }

    private func showStorage(_ stats: MailCacheStats, images: Int64) {
        let service = MailService.shared
        let fmt = ByteCountFormatter()
        let prune = service.lastPrune.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "not yet this session"
        var lines = [
            "Mail cache:      \(fmt.string(fromByteCount: stats.databaseBytes))  (\(stats.messages) messages, \(stats.bodies) with text)",
            "Image cache:     \(fmt.string(fromByteCount: images)) (limit 200 MB)",
            "Outbox:          \(service.outbox.items.count) waiting",
            "Queued actions:  \(stats.queuedOps)",
            "Offline window:  \(Prefs.offlineDays) days (newest 200 per folder always kept)",
            "Last prune:      \(prune)",
        ]
        for e in service.engines.values where e.lastError != nil {
            lines.append("Last error:      \(e.account.email): \(e.lastError ?? "")")
        }
        storageInfo.stringValue = lines.joined(separator: "\n")
    }

    @objc private func clearBodies() {
        guard let w = window, w.attachedSheet == nil else { return }
        let a = NSAlert()
        a.messageText = "Clear the cached message text?"
        a.informativeText = "Messages stay in the list; their text is downloaded again when opened. Offline reading needs a fresh download."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.clearBodiesButton.isEnabled = false
            self.storageGeneration += 1
            self.storageInfo.stringValue = "Clearing the cached message text…"
            let path = MailService.shared.store.path
            // Two DELETEs and a full VACUUM go to their own connection on a utility queue (C-06).
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let cleared = Store.clearBodies(path: path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.clearBodiesButton.isEnabled = true
                        guard cleared else {
                            self.storageInfo.stringValue = "The message text cache couldn't be cleared. Try again."
                            return
                        }
                        NotificationCenter.default.postMailDataChanged(.all)
                        self.refreshStorage()
                        Memory.relieve()
                    }
                }
            }
        }
    }

    @objc private func clearImages() {
        Task {
            await ImageDiskCache.shared.clear()
            refreshStorage()
        }
    }

    @objc private func pruneNow() {
        MailService.shared.pruneNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshStorage() }
    }

    @objc private func exportLog() {
        guard let w = window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Mac Mail diagnostics.log"
        panel.beginSheetModal(for: w) { r in
            guard r == .OK, let url = panel.url else { return }
            // Reading the log and writing the copy are file I/O; they never run on the main thread.
            DispatchQueue.global(qos: .utility).async {
                try? DiagnosticsLog.export(to: url)
            }
        }
    }

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
        let badge = NSButton(checkboxWithTitle: "Show unread count on the Dock icon", target: self, action: #selector(badgeChanged(_:)))
        badge.state = (Prefs.d.object(forKey: "showDockBadge") as? Bool ?? true) ? .on : .off

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
            [NSGridCell.emptyContentView, badge],
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

    @objc private func daysChanged(_ s: NSPopUpButton) {
        Prefs.offlineDays = s.selectedTag()
        // Apply the new offline window right away (on a background connection) instead of at the next launch.
        MailService.shared.pruneNow()
    }
    @objc private func groupChanged(_ s: NSButton) { Prefs.groupByConversationDefault = s.state == .on }
    @objc private func markReadChanged(_ s: NSButton) { Prefs.markReadOnOpen = s.state == .on }
    @objc private func askChanged(_ s: NSButton) { Prefs.askBeforeImages = s.state == .on }
    @objc private func notifyChanged(_ s: NSButton) {
        Prefs.notifyNewMail = s.state == .on
        // Ask for permission when the user turns notifications on, not on the first delivery (UX-09).
        if Prefs.notifyNewMail { MailService.shared.requestNotificationPermission() }
    }
    @objc private func badgeChanged(_ s: NSButton) {
        Prefs.d.set(s.state == .on, forKey: "showDockBadge")
        MailService.shared.updateBadge()
    }
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
        // selectTabViewItem doesn't always tell the delegate, so the figures are kicked off here too.
        if tab == "storage" { refreshStorage() }
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
    private let username = NSTextField()
    private let smtpUsername = NSTextField()
    private let imapSecurity = NSPopUpButton()
    private let smtpSecurity = NSPopUpButton()
    /// Set when editing an existing account (F-04) rather than adding one.
    private let editing: Account?
    private let error = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let signIn = NSButton(title: "Sign In", target: nil, action: nil)
    /// Saves an edit without contacting the servers, so an offline Mac can still fix its settings (C-18).
    private let saveOffline = NSButton(title: "Save Without Verifying", target: nil, action: nil)
    private var serverRows: [NSGridRow] = []

    init(editing: Account? = nil) {
        self.editing = editing
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: w)
        build()
        if let a = editing { fill(a) }
    }

    private func fill(_ a: Account) {
        provider.selectItem(at: a.provider == .gmail ? 0 : 1)
        provider.isEnabled = false
        name.stringValue = a.displayName
        email.stringValue = a.email
        email.isEditable = false
        username.stringValue = a.username == a.email ? "" : a.username
        smtpUsername.stringValue = a.smtpUsername
        imapHost.stringValue = a.imapHost
        imapPort.stringValue = "\(a.imapPort)"
        smtpHost.stringValue = a.smtpHost
        smtpPort.stringValue = "\(a.smtpPort)"
        imapSecurity.selectItem(at: ConnectionSecurity.allCases.firstIndex(of: a.imapSecurity) ?? 0)
        smtpSecurity.selectItem(at: ConnectionSecurity.allCases.firstIndex(of: a.smtpSecurity) ?? 0)
        password.placeholderString = "Leave empty to keep the saved password"
        signIn.title = "Save"
        providerChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: editing == nil ? "Add a mail account" : "Edit \(editing?.email ?? "account")")
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
        username.placeholderString = "Same as email"
        smtpUsername.placeholderString = "Same as IMAP login"
        for p in [imapSecurity, smtpSecurity] {
            p.addItems(withTitles: ConnectionSecurity.allCases.map { $0.label })
            p.target = self
        }
        imapSecurity.action = #selector(imapSecurityChanged)
        smtpSecurity.action = #selector(smtpSecurityChanged)
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
            [l("Login name:"), username],
            [l("IMAP server:"), imapHost],
            [l("IMAP port / security:"), Self.pair(imapPort, imapSecurity)],
            [l("SMTP server:"), smtpHost],
            [l("SMTP port / security:"), Self.pair(smtpPort, smtpSecurity)],
            [l("SMTP login:"), smtpUsername],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for f in [name, email, password, imapHost, smtpHost, username, smtpUsername] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        for f in [imapPort, smtpPort] { f.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        serverRows = (5...10).map { grid.row(at: $0) }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        signIn.bezelStyle = .rounded
        signIn.keyEquivalent = "\r"
        signIn.target = self
        signIn.action = #selector(submit)
        saveOffline.bezelStyle = .rounded
        saveOffline.target = self
        saveOffline.action = #selector(saveWithoutVerifying)
        saveOffline.isHidden = editing == nil
        saveOffline.toolTip = "Keep these settings and reconnect later, without checking the password now."
        let note = NSTextField(wrappingLabelWithString: "The password is stored only in your Mac's Keychain. Mac Mail signs in to IMAP and SMTP before saving (or saves unchecked if you choose) and never sends a password without TLS.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        for v in [title, grid, error, note, spinner, cancel, signIn, saveOffline] as [NSView] {
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
            saveOffline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            saveOffline.centerYAnchor.constraint(equalTo: signIn.centerYAnchor),
        ])
        providerChanged()
    }

    private static func pair(_ a: NSView, _ b: NSView) -> NSView {
        let s = NSStackView(views: [a, b])
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    /// Picking a security mode suggests its usual port.
    @objc private func imapSecurityChanged() {
        let sec = ConnectionSecurity.allCases[max(0, imapSecurity.indexOfSelectedItem)]
        if ["993", "143", ""].contains(imapPort.stringValue) { imapPort.stringValue = sec == .tls ? "993" : "143" }
    }

    @objc private func smtpSecurityChanged() {
        let sec = ConnectionSecurity.allCases[max(0, smtpSecurity.indexOfSelectedItem)]
        if ["465", "587", ""].contains(smtpPort.stringValue) { smtpPort.stringValue = sec == .tls ? "465" : "587" }
    }

    @objc private func providerChanged() {
        let other = provider.indexOfSelectedItem == 1
        for r in serverRows { r.isHidden = !other }
        email.placeholderString = other ? "you@example.com" : "you@gmail.com"
        // An edited account keeps its saved password unless a new one is typed.
        password.placeholderString = editing == nil
            ? (other ? "Password or app password" : "16-character App Password")
            : "Leave empty to keep the saved password"
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://myaccount.google.com/apppasswords")!)
    }

    @objc private func cancel() {
        probeTask?.cancel()
        closeSheet()
    }

    /// Validates the form and builds the account from the fields the editor shows (C-31). When editing,
    /// the saved account is the starting point, so settings this sheet doesn't show are kept as they are.
    private func formAccount() -> Account? {
        let mail = email.stringValue.trimmingCharacters(in: .whitespaces)
        // App Passwords are shown with spaces; Google accepts them without.
        let pass = password.stringValue.replacingOccurrences(of: " ", with: "")
        guard mail.contains("@"), !pass.isEmpty || editing != nil else {
            error.stringValue = "Enter your email address and App Password."
            return nil
        }
        if editing == nil, MailService.shared.accounts.contains(where: { $0.email.lowercased() == mail.lowercased() }) {
            error.stringValue = "\(mail) is already added."
            return nil
        }
        // Keeping the saved account means a custom login, SMTP login, port or security mode survives an
        // edit; only the fields this sheet exposes are replaced (C-31).
        var account = editing ?? Account.gmail(email: mail, name: name.stringValue)
        account.email = mail
        account.displayName = name.stringValue
        if provider.indexOfSelectedItem == 1 {
            guard !imapHost.stringValue.isEmpty, !smtpHost.stringValue.isEmpty else {
                error.stringValue = "Enter the IMAP and SMTP servers."
                return nil
            }
            // Invalid ports would silently fall back to 993/465 before; now they stop the submit.
            func port(_ text: String) -> UInt16? {
                guard let n = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
                return UInt16(n)
            }
            guard let pIn = port(imapPort.stringValue) else {
                error.stringValue = "The IMAP port must be a number between 1 and 65535."
                return nil
            }
            guard let pOut = port(smtpPort.stringValue) else {
                error.stringValue = "The SMTP port must be a number between 1 and 65535."
                return nil
            }
            let login = username.stringValue.trimmingCharacters(in: .whitespaces)
            account.provider = .imap
            account.username = login.isEmpty ? mail : login
            account.imapHost = imapHost.stringValue.trimmingCharacters(in: .whitespaces)
            account.imapPort = pIn
            account.smtpHost = smtpHost.stringValue.trimmingCharacters(in: .whitespaces)
            account.smtpPort = pOut
            account.imapSecurity = ConnectionSecurity.allCases[max(0, imapSecurity.indexOfSelectedItem)]
            account.smtpSecurity = ConnectionSecurity.allCases[max(0, smtpSecurity.indexOfSelectedItem)]
            account.smtpUsername = smtpUsername.stringValue.trimmingCharacters(in: .whitespaces)
        }
        if account.displayName.isEmpty { account.displayName = String(mail.split(separator: "@").first ?? "") }
        return account
    }

    @objc private func submit() {
        guard let account = formAccount() else { return }
        let pass = password.stringValue.replacingOccurrences(of: " ", with: "")
        error.stringValue = ""
        setProbing(true)
        probeTask = Task { [weak self] in
            // Cancelled before the task got to run: don't contact the servers at all.
            guard !Task.isCancelled else { return }
            do {
                if self?.editing != nil {
                    // What the edit replaces, in case the sheet is cancelled while the check runs.
                    let restore = MailService.shared.restorePoint(for: account.id)
                    try await MailService.shared.updateCredentials(account, password: pass)
                    guard !Task.isCancelled else {
                        // Cancelled during the check: leave the account exactly as the user found it.
                        if let restore { MailService.shared.restore(restore) }
                        return
                    }
                } else {
                    try await MailService.shared.addAccount(account, password: pass)
                    // The sheet may have been cancelled while the probe was running: undo the add.
                    guard !Task.isCancelled else { MailService.shared.removeAccount(account.id); return }
                }
                self?.setProbing(false)
                self?.closeSheet()
                (NSApp.delegate as? AppDelegate)?.mainWindow?.window?.makeKeyAndOrderFront(nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.setProbing(false)
                var msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if account.provider == .gmail, case NetError.auth = error {
                    msg += " Use an App Password, not your normal Google password. 2-Step Verification must be on."
                }
                self?.error.stringValue = msg
            }
        }
    }

    /// Saves an edited account without a network check, so a mistyped host or an offline Mac is fixable (C-18).
    @objc private func saveWithoutVerifying() {
        guard editing != nil, let account = formAccount() else { return }
        let pass = password.stringValue.replacingOccurrences(of: " ", with: "")
        do {
            try MailService.shared.saveCredentialsWithoutVerifying(account, password: pass)
        } catch {
            self.error.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        closeSheet()
    }

    private func setProbing(_ probing: Bool) {
        if probing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        signIn.isEnabled = !probing
        saveOffline.isEnabled = !probing
    }

    private func closeSheet() {
        guard let w = window else { return }
        w.sheetParent?.endSheet(w)
    }

    /// The in-flight credential probe, cancelled if the sheet closes first.
    private var probeTask: Task<Void, Never>?

    /// Cancels a running probe without touching the sheet (also called when the sheet ends).
    func cancelProbe() { probeTask?.cancel() }
}
