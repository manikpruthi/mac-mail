import AppKit

/// The composer's one-row formatting strip, Outlook-style but minimal: font, size, bold/italic/underline/strike,
/// text colour and clear formatting. It edits the text view's attributes directly (undoable), and RichText.html
/// turns them into the sent HTML. Plain AppKit controls; it keeps no caches.
final class FormatBar: NSStackView {
    /// Fonts recipients are likely to have, so the mail looks the same in Outlook and Gmail.
    static let families = ["System", "Arial", "Helvetica", "Verdana", "Georgia", "Times New Roman", "Courier New"]
    static let sizes: [CGFloat] = [10, 11, 12, 14, 16, 18, 20, 24, 32]
    static let defaultSize: CGFloat = 14

    weak var textView: NSTextView?

    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Bold, italic, underline, strikethrough: recessed toggles (lit when on) with self-drawn glyphs.
    private var toggles: [NSButton] = []
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let clear = NSButton()
    private var fm: NSFontManager { .shared }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .centerY

        for p in [fontPopup, sizePopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            p.target = self
        }
        // Plain titles: previewing each family in its own face would load every font file up front.
        for f in Self.families { fontPopup.addItem(withTitle: f) }
        fontPopup.menu?.addItem(.separator())
        fontPopup.addItem(withTitle: "More Fonts…")
        fontPopup.lastItem?.tag = -1
        fontPopup.action = #selector(fontChosen)
        fontPopup.toolTip = "Font"
        fontPopup.widthAnchor.constraint(equalToConstant: 130).isActive = true

        for s in Self.sizes { sizePopup.addItem(withTitle: "\(Int(s))") }
        sizePopup.action = #selector(sizeChosen)
        sizePopup.toolTip = "Size"
        sizePopup.widthAnchor.constraint(equalToConstant: 52).isActive = true

        // Text glyphs in borderless toggles: lighter than SF Symbols in a segmented control, and quieter.
        let glyphs: [(String, String, [NSAttributedString.Key: Any])] = [
            ("B", "Bold (⌘B)", [.font: NSFont.systemFont(ofSize: 12, weight: .bold)]),
            ("I", "Italic (⌘I)", [.font: Self.italicSystemFont(12)]),
            ("U", "Underline (⌘U)", [.underlineStyle: NSUnderlineStyle.single.rawValue]),
            ("S", "Strikethrough", [.strikethroughStyle: NSUnderlineStyle.single.rawValue]),
        ]
        for (i, g) in glyphs.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(styleClicked(_:)))
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
            attrs.merge(g.2) { $1 }
            b.attributedTitle = NSAttributedString(string: g.0, attributes: attrs)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.showsBorderOnlyWhileMouseInside = true
            b.controlSize = .small
            b.tag = i
            b.toolTip = g.1
            b.setAccessibilityLabel(g.1)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            toggles.append(b)
        }

        colorPopup.controlSize = .small
        colorPopup.addItem(withTitle: "")   // pull-down title slot; its image shows the current colour
        for (name, color) in Self.colors {
            colorPopup.addItem(withTitle: name)
            colorPopup.lastItem?.image = Self.swatch(color ?? .textColor, size: NSSize(width: 12, height: 12))
            colorPopup.lastItem?.representedObject = color
        }
        colorPopup.menu?.addItem(.separator())
        colorPopup.addItem(withTitle: "More Colours…")
        colorPopup.lastItem?.tag = -1
        colorPopup.target = self
        colorPopup.action = #selector(colorChosen)
        colorPopup.toolTip = "Text colour"

        clear.attributedTitle = NSAttributedString(string: "A", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor])
        clear.bezelStyle = .recessed
        clear.showsBorderOnlyWhileMouseInside = true
        clear.controlSize = .small
        clear.setAccessibilityLabel("Clear formatting")
        clear.target = self
        clear.action = #selector(clearFormatting)
        clear.toolTip = "Clear formatting"

        for v in [fontPopup, sizePopup] + toggles + [colorPopup, clear] as [NSView] { addArrangedSubview(v) }
        spacing = 2
        setCustomSpacing(8, after: fontPopup)
        setCustomSpacing(8, after: sizePopup)
        setCustomSpacing(8, after: toggles[3])
        setContentHuggingPriority(.required, for: .vertical)
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: State

    /// Attributes at the caret, or at the start of the selection.
    private var current: [NSAttributedString.Key: Any] {
        guard let tv = textView else { return [:] }
        let r = tv.selectedRange()
        if r.length > 0, let s = tv.textStorage, r.location < s.length {
            return s.attributes(at: r.location, effectiveRange: nil)
        }
        return tv.typingAttributes
    }

    private var currentFont: NSFont { current[.font] as? NSFont ?? .systemFont(ofSize: Self.defaultSize) }

    private static func italicSystemFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
    }

    /// Mirrors the caret's formatting in the controls.
    func refresh() {
        let a = current, font = currentFont
        let family = Self.displayFamily(font)
        if let item = fontPopup.item(withTitle: family), item.tag != -1 {
            fontPopup.select(item)
        } else {
            fontPopup.select(nil)
            fontPopup.setTitle(family)
        }
        let size = "\(Int(font.pointSize.rounded()))"
        if let item = sizePopup.item(withTitle: size) { sizePopup.select(item) } else { sizePopup.setTitle(size) }
        // setTitle adds an item for a size that isn't in the list; keep only the current one so the menu
        // doesn't grow for the app's lifetime (C-20).
        while sizePopup.numberOfItems > Self.sizes.count + 1 { sizePopup.removeItem(at: Self.sizes.count) }
        // Descriptor traits, not NSFontManager: creating the shared font manager costs ~2 MB, so it's
        // only touched when the user actually changes the formatting.
        let traits = font.fontDescriptor.symbolicTraits
        let on = [traits.contains(.bold), traits.contains(.italic),
                  (a[.underlineStyle] as? Int ?? 0) != 0, (a[.strikethroughStyle] as? Int ?? 0) != 0]
        for (b, isOn) in zip(toggles, on) { b.state = isOn ? .on : .off }
        colorPopup.item(at: 0)?.image = Self.letterSwatch(a[.foregroundColor] as? NSColor ?? .textColor)
        // A popup's setTitle adds an item for a font not in the list; drop stale ones so the menu stays short.
        while fontPopup.numberOfItems > Self.families.count + 3 { fontPopup.removeItem(at: Self.families.count + 2) }
    }

    private static func displayFamily(_ font: NSFont) -> String {
        let family = font.familyName ?? "System"
        return family.hasPrefix(".") ? "System" : family
    }

    // MARK: Editing

    /// Applies `change` to every selected range (one undo step), or to the typing attributes at a bare caret.
    private func edit(_ change: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ranges = tv.selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= storage.length }
        if ranges.isEmpty {
            var t = tv.typingAttributes
            change(&t)
            tv.typingAttributes = t
        } else if tv.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) {
            // Snapshot every run before changing anything: mutating the storage invalidates the enumeration,
            // and the old attributes are what Undo needs to restore (C-20).
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            for r in ranges {
                storage.enumerateAttributes(in: r) { attrs, sub, _ in runs.append((sub, attrs)) }
            }
            let updated = runs.map { run -> (NSRange, [NSAttributedString.Key: Any]) in
                var a = run.1
                change(&a)
                return (run.0, a)
            }
            let undo = tv.undoManager
            undo?.beginUndoGrouping()
            undo?.registerUndo(withTarget: self) { bar in bar.restore(runs) }
            undo?.setActionName("Formatting")
            storage.beginEditing()
            for (r, a) in updated { storage.setAttributes(a, range: r) }
            storage.endEditing()
            tv.didChangeText()
            undo?.endUndoGrouping()
        }
        tv.window?.makeFirstResponder(tv)
        refresh()
    }

    /// Undo/redo of a formatting change: puts each run's attributes back.
    private func restore(_ runs: [(NSRange, [NSAttributedString.Key: Any])]) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let valid = runs.filter { NSMaxRange($0.0) <= storage.length }
        guard !valid.isEmpty,
              tv.shouldChangeText(inRanges: valid.map { NSValue(range: $0.0) }, replacementStrings: nil) else { return }
        let current = valid.map { ($0.0, storage.attributes(at: $0.0.location, effectiveRange: nil)) }
        let undo = tv.undoManager
        undo?.beginUndoGrouping()
        undo?.registerUndo(withTarget: self) { bar in bar.restore(current) }
        undo?.setActionName("Formatting")
        storage.beginEditing()
        for (r, a) in valid { storage.setAttributes(a, range: r) }
        storage.endEditing()
        tv.didChangeText()
        undo?.endUndoGrouping()
        refresh()
    }

    private func editFont(_ transform: @escaping (NSFont) -> NSFont) {
        edit { a in a[.font] = transform(a[.font] as? NSFont ?? .systemFont(ofSize: Self.defaultSize)) }
    }

    private func toggle(_ key: NSAttributedString.Key, on: Bool) {
        edit { a in a[key] = on ? NSUnderlineStyle.single.rawValue : nil }
    }

    @objc private func fontChosen() {
        guard let item = fontPopup.selectedItem else { return }
        if item.tag == -1 {
            refresh()
            textView?.window?.makeFirstResponder(textView)
            fm.orderFrontFontPanel(self)
            return
        }
        let family = item.title
        let fm = self.fm
        editFont { f in
            let traits = fm.traits(of: f).intersection([.boldFontMask, .italicFontMask])
            var out = family == "System" ? NSFont.systemFont(ofSize: f.pointSize) : fm.convert(f, toFamily: family)
            for t in [NSFontTraitMask.boldFontMask, .italicFontMask] where traits.contains(t) {
                out = fm.convert(out, toHaveTrait: t)
            }
            return out
        }
    }

    @objc private func sizeChosen() {
        guard let title = sizePopup.titleOfSelectedItem, let size = Double(title) else { return }
        let fm = self.fm
        editFont { fm.convert($0, toSize: CGFloat(size)) }
    }

    @objc private func styleClicked(_ sender: NSButton) {
        let seg = sender.tag
        let on = sender.state == .on
        let fm = self.fm
        switch seg {
        case 0, 1:
            let trait: NSFontTraitMask = seg == 0 ? .boldFontMask : .italicFontMask
            editFont { on ? fm.convert($0, toHaveTrait: trait) : fm.convert($0, toNotHaveTrait: trait) }
        case 2: toggle(.underlineStyle, on: on)
        default: toggle(.strikethroughStyle, on: on)
        }
    }

    @objc private func colorChosen() {
        guard let item = colorPopup.selectedItem else { return }
        if item.tag == -1 {
            // The standard colour panel sends changeColor: to the text view (first responder).
            textView?.window?.makeFirstResponder(textView)
            NSColorPanel.shared.orderFront(nil)
            return
        }
        let c = item.representedObject as? NSColor
        edit { a in a[.foregroundColor] = c }
    }

    /// Automatic (nil) follows the theme; the rest read well on white and dark backgrounds alike.
    static let colors: [(String, NSColor?)] = [
        ("Automatic", nil),
        ("Red", NSColor(srgbRed: 0.84, green: 0.16, blue: 0.16, alpha: 1)),
        ("Orange", NSColor(srgbRed: 0.90, green: 0.45, blue: 0.05, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.13, green: 0.55, blue: 0.20, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.10, green: 0.40, blue: 0.85, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.50, green: 0.25, blue: 0.75, alpha: 1)),
        ("Grey", NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)),
    ]

    private static func swatch(_ color: NSColor, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5).stroke()
            return true
        }
    }

    /// "A" over a colour bar, like Outlook's font-colour button.
    private static func letterSwatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let a = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                  .foregroundColor: NSColor.labelColor])
            let sz = a.size()
            a.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: 3))
            color.setFill()
            NSRect(x: 1, y: 0, width: r.width - 2, height: 3).fill()
            return true
        }
    }

    @objc private func clearFormatting() {
        edit { a in
            a[.font] = NSFont.systemFont(ofSize: Self.defaultSize)
            a[.underlineStyle] = nil
            a[.strikethroughStyle] = nil
            a[.foregroundColor] = nil
            a[.backgroundColor] = nil
        }
    }

    /// Demo selftest: drives the controls the way clicks do.
    func selfTestApply(family: String, size: Int, boldSegment: Bool) {
        fontPopup.selectItem(withTitle: family); fontChosen()
        sizePopup.selectItem(withTitle: "\(size)"); sizeChosen()
        if boldSegment { toggles[0].state = .on; styleClicked(toggles[0]) }
    }

    var selfTestState: String {
        "\(fontPopup.titleOfSelectedItem ?? "-")/\(sizePopup.titleOfSelectedItem ?? "-")/b=\(toggles[0].state == .on)"
    }

}
