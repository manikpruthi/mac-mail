import AppKit
import Quartz
import UniformTypeIdentifiers

/// Attachment chips under the message header. Click a chip (or right-click → Save As…) to save it, Space or
/// right-click → Quick Look to preview it, or drag it to Finder or another app (F-15).
/// "Save All…" zips every attachment into one file.
final class AttachmentBar: NSView, NSFilePromiseProviderDelegate {
    var onSave: ((BodyPart) -> Void)?
    var onSaveAll: (() -> Void)?
    var onQuickLook: ((BodyPart) -> Void)?
    /// Writes a part to a file URL (drag-out promise). Runs the download; throws on failure.
    var provideFile: ((BodyPart, URL) async throws -> Void)?

    private let scroll = NSScrollView()
    private let chips = NSStackView()
    private let saveAll = NSButton(title: "Save All…", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let separator = NSBox()
    private var parts: [BodyPart] = []
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 58)
    /// The bar's vertical layout; relaxed while collapsed so a zero height is satisfiable.
    private var bodyConstraints: [NSLayoutConstraint] = []
    private(set) var isCollapsed = false

    var isEmpty: Bool { parts.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // Below required so a container (the .eml viewer) can collapse the bar to zero height without
        // an Auto Layout conflict.
        heightConstraint.priority = NSLayoutConstraint.Priority(999)
        heightConstraint.isActive = true
        chips.orientation = .horizontal
        chips.spacing = 8
        chips.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 8)
        chips.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(chips)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        saveAll.bezelStyle = .rounded
        saveAll.controlSize = .small
        saveAll.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        saveAll.imagePosition = .imageLeading
        saveAll.target = self
        saveAll.action = #selector(saveAllTapped)
        saveAll.toolTip = "Save every attachment as one .zip file"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let separator = self.separator
        separator.boxType = .separator
        for v in [scroll, saveAll, status, progress, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let vertical: [NSLayoutConstraint] = [
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            progress.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            saveAll.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            status.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -1),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        bodyConstraints = vertical
        NSLayoutConstraint.activate([heightConstraint] + vertical + [
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -8),
            chips.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            chips.topAnchor.constraint(equalTo: doc.topAnchor),
            chips.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.trailingAnchor.constraint(equalTo: chips.trailingAnchor),
            progress.trailingAnchor.constraint(equalTo: saveAll.leadingAnchor, constant: -8),
            saveAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            status.trailingAnchor.constraint(equalTo: saveAll.trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Collapses the bar to zero height where it isn't inside a stack view (the .eml viewer).
    func setCollapsed(_ collapsed: Bool) {
        guard isCollapsed != collapsed else { return }
        isCollapsed = collapsed
        heightConstraint.constant = collapsed ? 0 : 58
        if collapsed {
            NSLayoutConstraint.deactivate(bodyConstraints)
        } else {
            NSLayoutConstraint.activate(bodyConstraints)
        }
        for v in [scroll, saveAll, status, progress, separator] as [NSView] { v.isHidden = collapsed }
    }

    func set(_ parts: [BodyPart]) {
        self.parts = parts
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, p) in parts.enumerated() {
            let chip = AttachmentChip(part: p)
            chip.tag = i
            chip.target = self
            chip.action = #selector(chipTapped(_:))
            chip.menu = menu(for: i)
            chip.dragProvider = { [weak self] in self?.promise(for: i) }
            chips.addArrangedSubview(chip)
        }
        // Single attachment: the chip itself saves it (Save As). Several: Save All zips them.
        saveAll.isHidden = parts.count < 2
        setBusy(false)
    }

    private func menu(for index: Int) -> NSMenu {
        let m = NSMenu()
        let look = NSMenuItem(title: "Quick Look", action: #selector(menuQuickLook(_:)), keyEquivalent: "")
        look.target = self
        look.tag = index
        m.addItem(look)
        let item = NSMenuItem(title: "Save As…", action: #selector(menuSave(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index
        m.addItem(item)
        if parts.count > 1 {
            let all = NSMenuItem(title: "Save All Attachments as .zip…", action: #selector(saveAllTapped), keyEquivalent: "")
            all.target = self
            m.addItem(all)
        }
        return m
    }

    private(set) var isBusy = false

    /// While a save runs, every chip (and its menu) is disabled too, so a second save can't start (B-32).
    func setBusy(_ busy: Bool, text: String = "") {
        isBusy = busy
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        status.stringValue = busy ? text : ""
        saveAll.isEnabled = !busy
        for case let chip as NSButton in chips.arrangedSubviews { chip.isEnabled = !busy }
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        guard !isBusy, sender.tag < parts.count else { return }
        onQuickLook?(parts[sender.tag])
    }

    // MARK: Drag-out (file promises: the attachment downloads when it's dropped)

    private func promise(for index: Int) -> NSFilePromiseProvider? {
        guard !isBusy, index < parts.count, provideFile != nil else { return nil }
        let p = parts[index]
        let type = UTType(filenameExtension: (p.suggestedFilename as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = index
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let i = provider.userInfo as? Int, i < parts.count else { return "Attachment" }
        return parts[i].suggestedFilename
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let i = provider.userInfo as? Int, i < parts.count, let write = provideFile else {
            completionHandler(NetError.server("The attachment is no longer available.")); return
        }
        let part = parts[i]
        Task { @MainActor in
            do { try await write(part, url); completionHandler(nil) } catch {
                try? FileManager.default.removeItem(at: url)
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    @objc private func chipTapped(_ sender: NSButton) {
        guard !isBusy, sender.tag < parts.count else { return }
        onSave?(parts[sender.tag])
    }

    @objc private func menuSave(_ sender: NSMenuItem) {
        guard !isBusy, sender.tag < parts.count else { return }
        onSave?(parts[sender.tag])
    }

    @objc private func saveAllTapped() { onSaveAll?() }

    /// Saves every attachment of the message shown (menu command).
    func triggerSaveAll() {
        if parts.count > 1 { onSaveAll?() } else if let p = parts.first { onSave?(p) }
    }
}

final class AttachmentChip: NSButton, NSDraggingSource {
    var dragProvider: (() -> NSFilePromiseProvider?)?
    private var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        // Track the drag ourselves: a press that moves becomes a file drag, a press that doesn't and ends
        // inside the chip is a click. The wait is capped, and a mouse-up outside the chip is not a click,
        // so a missed mouse-up can never wedge the event loop or swallow the next click (C-23).
        guard let window else { super.mouseDown(with: event); return }
        let deadline = Date().addingTimeInterval(10)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                mouseDownPoint = nil
                if isEnabled, bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                return
            }
            if let start = mouseDownPoint, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4,
               isEnabled, let provider = dragProvider?() {
                mouseDownPoint = nil
                let item = NSDraggingItem(pasteboardWriter: provider)
                item.setDraggingFrame(bounds, contents: image)
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
        }
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    init(part: BodyPart) {
        super.init(frame: .zero)
        let name = part.suggestedFilename
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? UTType(mimeType: part.mimeType) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 28, height: 28)
        image = icon
        imagePosition = .imageLeading
        let title = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        title.append(NSAttributedString(string: "\n" + MIME.formatSize(part.decodedSize),
                                        attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
        attributedTitle = title
        bezelStyle = .regularSquare
        isBordered = true
        setButtonType(.momentaryPushIn)
        toolTip = "Save “\(name)”… — drag to copy it, right-click to Quick Look"
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Shows downloaded attachments in the system Quick Look panel (F-15).
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var url: URL?
    private var closeObserver: NSObjectProtocol?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { NSWorkspace.shared.open(url); return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        if closeObserver == nil {
            // Clear dataSource/url when the panel closes, so it never previews a deleted file (C-25).
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.panelClosed() }
            }
        }
    }

    /// Closes the panel if it is showing one of our temp files (teardown deletes them right after).
    func close() {
        if let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.orderOut(nil) }
        panelClosed()
    }

    private func panelClosed() {
        url = nil
        if let panel = QLPreviewPanel.shared(), panel.dataSource === self { panel.dataSource = nil }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        guard Thread.isMainThread else { return 0 }
        return MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { url as NSURL? }
    }
}
