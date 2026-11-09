import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var mainWindow: MainWindowController?
    private var settings: SettingsWindowController?
    private var pendingOpen: [URL] = []
    private var launched = false

    private var benchActivity: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Debug.log("willFinishLaunching")
        defer { Debug.log("willFinishLaunching done") }
        Prefs.register()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
        if let a = ProcessInfo.processInfo.environment["MAC_MAIL_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        } else {
            Self.applyTheme(Prefs.theme)
        }
        buildMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.log("didFinishLaunching")
        // A script-launched benchmark runs in the background, where App Nap would throttle its timers.
        if Debug.bench { benchActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "benchmark") }
        MailService.shared.start()
        Debug.log("service started")
        let w = MainWindowController()
        mainWindow = w
        Debug.log("window built")
        w.showWindow(nil)
        w.start()
        Debug.log("window started")
        launched = true
        ImageLoader.pruneCache()
        if !pendingOpen.isEmpty {
            let urls = pendingOpen
            pendingOpen = []
            handle(urls)
        }
        if AppPaths.isDemo { runDemoHooks() }
        Debug.log("launch → window shown: \(Debug.ms(since: Debug.launch))")
        if Debug.bench { runBenchmark() }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.idleWork?.cancel()
                self?.mainWindow?.preview.restoreWebViewIfNeeded()
                self?.mainWindow?.appBecameActive()
            }
        }
        // While you're in another app, WebKit's helper processes are shut down after a minute and freed memory
        // is handed back to macOS. Coming back re-renders the open message (~0.1 s).
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIdleTrim(after: 60) }
        }
        nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIdleTrim(after: 0) }
        }
        nc.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if (note.object as? NSWindow) === self?.mainWindow?.window { self?.scheduleIdleTrim(after: 0) }
            }
        }
        nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mainWindow?.preview.restoreWebViewIfNeeded() }
        }
        memoryPressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if !NSApp.isActive { self?.mainWindow?.preview.releaseWebView() }
                Memory.relieve()
            }
        }
        memoryPressure.resume()
    }

    private var idleWork: DispatchWorkItem?
    private let memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    private func scheduleIdleTrim(after seconds: TimeInterval) {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard !NSApp.isActive || self?.mainWindow?.window?.isMiniaturized == true else { return }
            self?.mainWindow?.preview.releaseWebView()
            Memory.relieve()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MailService.shared.hasPendingSends {
            let a = NSAlert()
            a.messageText = "A message is about to be sent"
            a.informativeText = "Quit after it's sent, or quit now and cancel it?"
            a.addButton(withTitle: "Wait")
            a.addButton(withTitle: "Quit Anyway")
            if a.runModal() == .alertFirstButtonReturn {
                Task {
                    while MailService.shared.hasPendingSends { try? await Task.sleep(nanoseconds: 300_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    NSApp.terminate(nil)
                }
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MailService.shared.shutdown()
    }

    // MARK: Opening files and mailto: links

    /// Files (from Mac Explorer's "Email with Mac Mail", Finder's Open With, or drag to the Dock) start a new
    /// message with them attached; mailto: links start a message to that address.
    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { handle(urls) } else { pendingOpen += urls }
    }

    private func handle(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        Debug.log("open request: \(files.count) file(s) \(files.map { $0.lastPathComponent }) mailto=\(urls.count - files.count)")
        for m in urls where m.scheme?.lowercased() == "mailto" { compose(mailto: m) }
        if !files.isEmpty { ComposeWindowController.open(.files(files)) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func compose(mailto url: URL) {
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let parts = raw.split(separator: "?", maxSplits: 1)
        let to = MIME.parseAddresses((parts.first.map(String.init) ?? "").removingPercentEncoding ?? "")
        var cc: [EmailAddress] = []
        var subject = ""
        var body = ""
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = kv.first.map { String($0).lowercased() } ?? ""
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: "%20").removingPercentEncoding ?? "") : ""
                switch key {
                case "subject": subject = value
                case "body": body = value
                case "cc": cc = MIME.parseAddresses(value)
                default: break
                }
            }
        }
        ComposeWindowController.open(.mailto(to: to, cc: cc, subject: subject, body: body))
    }

    // MARK: Theme

    /// nil appearance = follow macOS (live, including auto light/dark switching).
    static func applyTheme(_ theme: Prefs.Theme) {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc func setThemeFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = Prefs.Theme(rawValue: raw) else { return }
        Prefs.theme = theme
        Self.applyTheme(theme)
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setThemeFromMenu(_:)) {
            item.state = (item.representedObject as? String) == Prefs.theme.rawValue ? .on : .off
        }
        return true
    }

    // MARK: Settings

    @objc func showSettingsAction(_ sender: Any?) { showSettings(addAccount: false) }

    func showSettings(addAccount: Bool) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.show(tab: "accounts")
        if addAccount { settings?.addAccount() }
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
            return top
        }
        let settingsItem = item("Settings…", #selector(showSettingsAction(_:)), ",")
        settingsItem.target = self
        _ = submenu("Mac Mail", [
            item("About Mac Mail", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(), settingsItem, .separator(),
            item("Hide Mac Mail", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Mac Mail", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = submenu("File", [
            item("New Message", #selector(MainWindowController.newMessage(_:)), "n"),
            item("Attach Files…", #selector(ComposeWindowController.attachFiles(_:)), "a", [.command, .shift]),
            .separator(),
            item("Save Attachments…", #selector(MainWindowController.saveAttachments(_:)), "s", [.command, .shift]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Search Mail", #selector(MainWindowController.focusSearch(_:)), "f", [.command, .option]),
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f"),
        ])
        if let find = main.items.last?.submenu?.items.last { find.tag = Int(NSFindPanelAction.showFindPanel.rawValue) }
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for t in Prefs.Theme.allCases {
            let i = NSMenuItem(title: t.label, action: #selector(setThemeFromMenu(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.rawValue
            appearanceMenu.addItem(i)
        }
        appearance.submenu = appearanceMenu
        _ = submenu("View", [
            item("Group by Conversation", #selector(MainWindowController.toggleConversations(_:)), "c", [.command, .option]),
            .separator(),
            appearance,
            item("Show Message with Light Background", #selector(MainWindowController.toggleLightBackground(_:)), "l", [.command, .option]),
            .separator(),
            item("Sync Now", #selector(MainWindowController.syncNow(_:)), "r", [.command, .option]),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
        ])
        _ = submenu("Message", [
            item("Reply", #selector(MainWindowController.reply(_:)), "r"),
            item("Reply All", #selector(MainWindowController.replyAll(_:)), "r", [.command, .shift]),
            item("Forward", #selector(MainWindowController.forward(_:)), "j"),
            .separator(),
            item("Mark as Read / Unread", #selector(MainWindowController.toggleRead(_:)), "u", [.command, .shift]),
            item("Flag / Unflag", #selector(MainWindowController.toggleFlag(_:)), "l", [.command, .shift]),
            .separator(),
            item("Archive", #selector(MainWindowController.archiveMessages(_:)), "a", [.command, .control]),
            item("Delete", #selector(MainWindowController.deleteMessages(_:)), "\u{8}"),
            item("Report Spam / Not Spam", #selector(MainWindowController.toggleSpam(_:)), "j", [.command, .shift]),
            .separator(),
            item("Send", #selector(ComposeWindowController.send(_:)), "\r"),
        ])
        _ = submenu("Format", [
            item("Show Fonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t"),
            item("Bold", #selector(NSFontManager.addFontTrait(_:)), "b"),
            item("Italic", #selector(NSFontManager.addFontTrait(_:)), "i"),
            item("Underline", #selector(NSText.underline(_:)), "u"),
        ])
        if let fmt = main.items.last?.submenu {
            fmt.items[0].target = NSFontManager.shared
            fmt.items[1].target = NSFontManager.shared
            fmt.items[1].tag = Int(NSFontTraitMask.boldFontMask.rawValue)
            fmt.items[2].target = NSFontManager.shared
            fmt.items[2].tag = Int(NSFontTraitMask.italicFontMask.rawValue)
        }
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        NSApp.windowsMenu = window.submenu
        NSApp.mainMenu = main
    }

    // MARK: Benchmark (MAC_MAIL_BENCH=1 MAC_MAIL_DEBUG=1): opens the 10 newest messages read-only, logs timings and memory.

    private func runBenchmark() {
        guard let w = mainWindow else { return }
        let env = ProcessInfo.processInfo.environment
        let offset = Int(env["MAC_MAIL_BENCH_OFFSET"] ?? "0") ?? 0
        var index = 0
        func next() {
            if index >= 10 {
                Debug.log("bench done; footprint \(Memory.footprintMB()) MB")
                if env["MAC_MAIL_BENCH_HOLD"] == "1" {
                    w.preview.releaseWebView()
                    Memory.relieve()
                    let delay = Double(env["MAC_MAIL_SNAPSHOT_DELAY"] ?? "") ?? 4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        Debug.log("after release; footprint \(Memory.footprintMB()) MB")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                }
                return
            }
            w.list.selectAfterRemoval(previousIndex: offset + index)
            index += 1
        }
        w.preview.onRendered = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Debug.log("bench start; footprint \(Memory.footprintMB()) MB")
            next()
        }
    }

    // MARK: Demo / screenshot hooks

    private func runDemoHooks() {
        let env = ProcessInfo.processInfo.environment
        // MAC_MAIL_DEMO_HTML=<file>: replace the second demo message's body with this HTML (reproduce rendering bugs).
        if let file = env["MAC_MAIL_DEMO_HTML"], let html = try? String(contentsOfFile: file, encoding: .utf8),
           let inbox = MailService.shared.store.folder(account: DemoData.account.id, role: .inbox),
           let id = MailService.shared.store.ids(folderID: inbox.id, uids: [19]).first {
            MailService.shared.store.saveBody(id, html: html, text: nil)
            // Give the first message the image-heavy newsletter so a sequence can switch between two image emails.
            if let first = MailService.shared.store.ids(folderID: inbox.id, uids: [20]).first {
                MailService.shared.store.saveBody(first, html: DemoData.newsletterHTML, text: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let w = self?.mainWindow else { return }
            if env["MAC_MAIL_DEMO_GROUP"] == "1" { w.list.setGrouped(true) }
            if let idx = env["MAC_MAIL_DEMO_SELECT"].flatMap(Int.init) {
                w.list.selectAfterRemoval(previousIndex: idx)
            }
            if let q = env["MAC_MAIL_DEMO_SEARCH"] { w.runSearch(q) }
            if let row = env["MAC_MAIL_DEMO_REPLY"].flatMap(Int.init) {
                w.list.selectAfterRemoval(previousIndex: row)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.reply(nil) }
            }
            if let row = env["MAC_MAIL_DEMO_OPEN"].flatMap(Int.init) {
                w.list.selectAfterRemoval(previousIndex: row)
                if let r = w.list.focusedRow { w.openRow(r) }
            }
            // MAC_MAIL_DEMO_SEQUENCE=0,1: select these rows 3 s apart (reproduces bugs that need a previous message).
            if let seq = env["MAC_MAIL_DEMO_SEQUENCE"] {
                for (i, row) in seq.split(separator: ",").compactMap({ Int($0) }).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 3) { w.list.selectAfterRemoval(previousIndex: row) }
                }
            }
            if let row = env["MAC_MAIL_DEMO_CONTEXT"].flatMap(Int.init) {
                // Simulates right-click → first read/unread command on `row`, then reports what changed.
                let before = w.list.selectedRows.map { $0.subject }
                let menu = NSMenu()
                w.list.populate(menu, clickedRow: row)
                if let item = menu.items.first(where: { $0.title.hasPrefix("Mark as") }) {
                    Debug.log("context: '\(item.title)' on row \(row)")
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                }
                let after = w.list.selectedRows.map { $0.subject }
                let flags = MailService.shared.store.unifiedInboxRows().map { "\($0.subject.prefix(18))=\($0.flags.contains(.seen) ? "read" : "UNREAD")" }
                Debug.log("selection before=\(before) after=\(after)")
                Debug.log("flags: \(flags)")
            }
            if let file = env["MAC_MAIL_WINDOW_ID_FILE"], let n = w.window?.windowNumber {
                try? "\(n)".write(toFile: file, atomically: true, encoding: .utf8)
            }
            if let path = env["MAC_MAIL_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    Task { @MainActor in
                        let target = env["MAC_MAIL_DEMO_COMPOSE"] == "1" || env["MAC_MAIL_DEMO_REPLY"] != nil
                            ? NSApp.windows.first(where: { $0.windowController is ComposeWindowController })
                            : env["MAC_MAIL_DEMO_OPEN"] != nil
                                ? NSApp.windows.first(where: { $0.windowController is MessageWindowController })
                                : w.window
                        if let win = target { await Snapshot.write(window: win, to: path) }
                        NSApp.terminate(nil)
                    }
                }
            }
            if env["MAC_MAIL_DEMO_COMPOSE"] == "1" {
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("Q4 Budget.pdf")
                try? Data("demo".utf8).write(to: f)
                ComposeWindowController.open(.files([f]))
            }
        }
    }
}
