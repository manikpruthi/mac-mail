import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Images placed in the message body (pasted, dropped, or copied as files in Finder / Mac Explorer), like Outlook.
/// Each one is an `NSTextAttachment` whose file wrapper holds the bytes that will be sent (PNG, JPEG or GIF;
/// anything else is converted). On screen it shows a downsampled copy sized to the editor, so a 12-megapixel photo
/// costs a few MB of RAM, not 48. On send, each becomes a `cid:` part inside multipart/related.
@MainActor
enum InlineImage {
    /// Larger images go in as ordinary attachments.
    nonisolated static let maxBytes = 20 * 1024 * 1024
    nonisolated private static let sendable: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier]

    /// Whether a file should go into the body rather than the attachment list.
    nonisolated static func isCandidate(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image), !t.conforms(to: .svg) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 && size <= maxBytes
    }

    /// An attachment for raw image data, or nil when it can't be decoded.
    static func attachment(data: Data, name: String, maxWidth: CGFloat) -> NSTextAttachment? {
        guard data.count <= maxBytes, let (payload, type) = sendableData(data) else { return nil }
        let wrapper = FileWrapper(regularFileWithContents: payload)
        let ext = UTType(type)?.preferredFilenameExtension ?? "png"
        let base = (name as NSString).deletingPathExtension
        wrapper.preferredFilename = (base.isEmpty ? "image" : base) + "." + ext
        let att = InlineImageAttachment(fileWrapper: wrapper)
        att.payload = payload
        guard applyDisplay(att, maxWidth: maxWidth) else { return nil }
        return att
    }

    static func attachment(file url: URL, maxWidth: CGFloat, width: CGFloat? = nil) -> NSTextAttachment? {
        guard let data = try? Data(contentsOf: url), let att = attachment(data: data, name: url.lastPathComponent, maxWidth: maxWidth)
        else { return nil }
        if let width { applyDisplay(att, maxWidth: maxWidth, width: width) }
        return att
    }

    /// The bytes to send: PNG/JPEG/GIF as they are; HEIC, TIFF, BMP, WebP… re-encoded (PNG when there's
    /// transparency, else JPEG) because Outlook and Gmail don't show those inline.
    nonisolated static func sendableData(_ data: Data) -> (Data, String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src) as String? else { return nil }
        if sendable.contains(type) { return (data, type) }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let alpha = image.alphaInfo
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        let outType = opaque ? UTType.jpeg.identifier : UTType.png.identifier
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, outType as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, outType)
    }

    /// Sizes the attachment to fit `maxWidth` points (keeping its own size when smaller; Retina screenshots
    /// count at their point size) and gives it a screen-resolution thumbnail instead of the full image.
    /// `width` (points) is a size the user chose by dragging a handle or from the Image Size menu.
    @discardableResult
    static func applyDisplay(_ att: NSTextAttachment, maxWidth: CGFloat, width: CGFloat? = nil) -> Bool {
        guard let data = bytes(att),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return false }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi > 100 ? dpi / 72 : 1
        var size = CGSize(width: w / scale, height: h / scale)
        let limit = max(120, maxWidth)
        if let width, width > 0 {
            let wanted = min(max(minWidth, width), limit)
            size = CGSize(width: wanted.rounded(), height: max(1, (size.height * wanted / size.width).rounded()))
        } else if size.width > limit {
            size = CGSize(width: limit, height: max(1, (size.height * limit / size.width).rounded()))
        }
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * backing)]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return false }
        let image = NSImage(cgImage: thumb, size: size)
        att.bounds = CGRect(origin: .zero, size: size)
        att.attachmentCell = InlineImageCell(imageCell: image)
        return true
    }

    static let minWidth: CGFloat = 32

    /// The bytes to send for an attachment in the body.
    static func bytes(_ att: NSTextAttachment) -> Data? {
        if let a = att as? InlineImageAttachment, !a.payload.isEmpty { return a.payload }
        return att.fileWrapper?.regularFileContents
    }

    /// The image's own size in points (Retina screenshots at their point size).
    static func naturalSize(_ att: NSTextAttachment) -> CGSize? {
        guard let data = bytes(att),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, o >= 5 { swap(&w, &h) }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi > 100 ? dpi / 72 : 1
        return CGSize(width: w / scale, height: h / scale)
    }

    /// Live resize while a handle is dragged: only the bounds change (the current thumbnail is scaled);
    /// `applyDisplay` makes a sharp one when the drag ends.
    static func previewResize(_ att: NSTextAttachment, width: CGFloat, maxWidth: CGFloat) {
        let b = att.bounds.size
        guard b.width > 0 else { return }
        let w = min(max(minWidth, width), max(120, maxWidth)).rounded()
        let size = CGSize(width: w, height: max(1, (b.height * w / b.width).rounded()))
        att.bounds = CGRect(origin: .zero, size: size)
        (att.attachmentCell as? NSTextAttachmentCell)?.image?.size = size
    }

    /// Gives every attachment in `storage` that isn't displayed yet (just pasted as rich text, restored from an
    /// autosave) its inline display. Anything that isn't a decodable image is left untouched: AppKit inserts
    /// file promises and other files into rich text, and deleting them would lose what the user pasted (C-03).
    /// `widths` gives restored images (in document order) the sizes they had; RTFD doesn't keep them.
    static func normalize(_ storage: NSTextStorage, maxWidth: CGFloat, widths: [CGFloat]? = nil) {
        var changes: [(NSRange, NSTextAttachment)] = []
        var n = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let att = value as? NSTextAttachment, !(att is InlineImageAttachment) else { return }
            var data = att.fileWrapper?.regularFileContents
            if data == nil, let image = att.image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                data = rep.representation(using: .png, properties: [:])
            }
            let name = att.fileWrapper?.preferredFilename ?? "image.png"
            let saved = widths.flatMap { n < $0.count ? $0[n] : nil }
            n += 1
            let width = saved ?? (att.bounds.width > 0 ? att.bounds.width : nil)
            if let data, let new = attachment(data: data, name: name, maxWidth: maxWidth) {
                if let width { applyDisplay(new, maxWidth: maxWidth, width: width) }
                changes.append((range, new))
            }
        }
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for (r, att) in changes.reversed() { storage.addAttribute(.attachment, value: att, range: r) }
        storage.endEditing()
    }

    /// RTFD of the body with each image's original bytes (AppKit may have rewritten the display file wrapper).
    static func rtfd(_ attr: NSAttributedString) -> Data? {
        let copy = NSMutableAttributedString(attributedString: attr)
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
            guard let a = v as? InlineImageAttachment, !a.payload.isEmpty else { return }
            let w = FileWrapper(regularFileWithContents: a.payload)
            w.preferredFilename = a.fileWrapper?.preferredFilename ?? "image.png"
            copy.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: w), range: r)
        }
        return copy.rtfd(from: NSRange(location: 0, length: copy.length), documentAttributes: [:])
    }

    /// Displayed widths of the images in `attr`, in document order (saved with an autosave).
    static func widths(_ attr: NSAttributedString) -> [CGFloat] {
        var out: [CGFloat] = []
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
            if let a = v as? NSTextAttachment { out.append(a.bounds.width) }
        }
        return out
    }

    /// Image MIME type of an attachment's bytes.
    nonisolated static func mimeType(_ data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let t = CGImageSourceGetType(src) as String?,
              let m = UTType(t)?.preferredMIMEType else { return "application/octet-stream" }
        return m
    }

    // MARK: Drafts

    /// Placeholder text that stands in for a `cid:` image while a saved draft's HTML is parsed; the images are
    /// downloaded and swapped in afterwards.
    nonisolated static func token(_ n: Int) -> String { "\u{2063}[inline-image-\(n)]\u{2063}" }

    /// Ranges of any draft image token left in `s`, in document order.
    nonisolated static func tokenRanges(in s: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: "\u{2063}\\[inline-image-\\d+\\]\u{2063}") else { return [] }
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }

    /// Replaces every `<img src="cid:…">` with a token; returns the new HTML and, in token order, each content id
    /// with the width the image was given (so a resized image keeps its size when a draft is reopened).
    nonisolated static func tokenizeCIDImages(_ html: String) -> (String, [(cid: String, width: CGFloat?)]) {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*["']?cid:([^"'\s>]+)[^>]*>"#,
                                                options: [.caseInsensitive]),
              let widthRE = try? NSRegularExpression(pattern: #"\bwidth\s*=\s*["']?(\d+)"#, options: [.caseInsensitive])
        else { return (html, []) }
        let ns = html as NSString
        var out = ""
        var cids: [(cid: String, width: CGFloat?)] = []
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += token(cids.count)
            let raw = ns.substring(with: m.range(at: 1))
            let tag = ns.substring(with: m.range)
            let width = widthRE.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
                .flatMap { Double((tag as NSString).substring(with: $0.range(at: 1))) }.map { CGFloat($0) }
            cids.append((raw.removingPercentEncoding ?? raw, width))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, cids)
    }
}

/// An image in the body that has its inline display (see `InlineImage.normalize`).
/// `payload` holds the bytes that are sent: AppKit may rewrite the file wrapper once a display image is set.
final class InlineImageAttachment: NSTextAttachment {
    var payload = Data()
    /// The part built for sending, kept on the attachment itself. Caching it by `ObjectIdentifier` in the
    /// composer could return another image's part once an object address is reused (C-08).
    var outgoingPart: OutgoingAttachment?
}

final class InlineImageCell: NSTextAttachmentCell {}
