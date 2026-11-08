import AppKit
import UniformTypeIdentifiers

/// Attachment chips under the message header. Click a chip (or right-click → Save As…) to save it;
/// "Save All…" zips every attachment into one file. Nothing opens inside the app.
final class AttachmentBar: NSView {
    var onSave: ((BodyPart) -> Void)?
    var onSaveAll: (() -> Void)?

    private let scroll = NSScrollView()
    private let chips = NSStackView()
    private let saveAll = NSButton(title: "Save All…", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var parts: [BodyPart] = []

    var isEmpty: Bool { parts.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
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

        let separator = NSBox()
        separator.boxType = .separator
        for v in [scroll, saveAll, status, progress, separator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -6),
            scroll.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -8),
            chips.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            chips.topAnchor.constraint(equalTo: doc.topAnchor),
            chips.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.trailingAnchor.constraint(equalTo: chips.trailingAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            progress.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: saveAll.leadingAnchor, constant: -8),
            saveAll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            saveAll.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: saveAll.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -1),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ parts: [BodyPart]) {
        self.parts = parts
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, p) in parts.enumerated() {
            let chip = AttachmentChip(part: p)
            chip.tag = i
            chip.target = self
            chip.action = #selector(chipTapped(_:))
            chip.menu = menu(for: i)
            chips.addArrangedSubview(chip)
        }
        // Single attachment: the chip itself saves it (Save As). Several: Save All zips them.
        saveAll.isHidden = parts.count < 2
        setBusy(false)
    }

    private func menu(for index: Int) -> NSMenu {
        let m = NSMenu()
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

    func setBusy(_ busy: Bool, text: String = "") {
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        status.stringValue = busy ? text : ""
        saveAll.isEnabled = !busy
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard sender.tag < parts.count else { return }
        onSave?(parts[sender.tag])
    }

    @objc private func menuSave(_ sender: NSMenuItem) {
        guard sender.tag < parts.count else { return }
        onSave?(parts[sender.tag])
    }

    @objc private func saveAllTapped() { onSaveAll?() }

    /// Saves every attachment of the message shown (menu command).
    func triggerSaveAll() {
        if parts.count > 1 { onSaveAll?() } else if let p = parts.first { onSave?(p) }
    }
}

final class AttachmentChip: NSButton {
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
        toolTip = "Save “\(name)”…"
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
