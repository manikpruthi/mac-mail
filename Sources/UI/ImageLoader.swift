import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Per-message image policy and bookkeeping for one rendered page.
@MainActor
final class ImagePage {
    let generation: Int
    let messageID: Int64
    let accountID: String
    let prepared: PreparedHTML
    /// false → every remote image waits for a click (Spam, or "Ask before loading images").
    var autoLoad: Bool
    /// "Load all" / always-from-sender: ignore size limits (images are still shrunk).
    var ignoreLimits: Bool
    var forced: Set<Int> = []
    var bytesLoaded = 0
    var blocked: [Int: Int] = [:]   // id → bytes (0 if unknown)
    /// Dark placeholders when the page is shown in dark mode.
    var dark = false

    init(generation: Int, messageID: Int64, accountID: String, prepared: PreparedHTML, autoLoad: Bool, ignoreLimits: Bool) {
        self.generation = generation
        self.messageID = messageID
        self.accountID = accountID
        self.prepared = prepared
        self.autoLoad = autoLoad
        self.ignoreLimits = ignoreLimits
    }
}

/// Serves lm:// requests from the email web view. Remote images are fetched here, not by WebKit, so the app decides:
/// small images load automatically, anything over the per-image or per-message budget becomes a "Load image" box,
/// and big images are shrunk before WebKit decodes them, which is what actually bounds memory.
@MainActor
final class ImageLoader: NSObject, WKURLSchemeHandler {
    var page: ImagePage?
    /// Called when an image is held back, so the preview can show its banner.
    var onBlocked: ((ImagePage) -> Void)?
    /// Called to mark held-back <img> elements clickable.
    var markBlocked: ((Int) -> Void)?

    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 4
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) MacMail/1.0", "Accept": "image/*,*/*;q=0.5"]
        return URLSession(configuration: c)
    }()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        guard let url = task.request.url, let page else {
            finish(task, key: key, data: Self.transparentGIF, mime: "image/gif")
            return
        }
        let kind = url.host ?? ""
        Debug.log("image request \(url.absoluteString)")
        // lm://<kind>/<page>/<id>: a request from an earlier render (stale cache or late load) gets nothing.
        let parts = Array(url.pathComponents.dropFirst())
        let id = parts.count == 2 ? Int(parts[1]) ?? -1 : -1
        guard parts.count == 2, Int(parts[0]) == page.generation else {
            finish(task, key: key, data: Self.transparentGIF, mime: "image/gif")
            return
        }
        let t = Task { [weak self] in
            guard let self else { return }
            let result: (Data, String)
            switch kind {
            case "cid": result = await self.loadCID(id: id, page: page)
            case "img", "bg": result = await self.loadRemote(id: id, isBackground: kind == "bg", page: page)
            default: result = (Self.transparentGIF, "image/gif")
            }
            self.finish(task, key: key, data: result.0, mime: result.1)
        }
        active[key] = t
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        active.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        for t in active.values { t.cancel() }
        active.removeAll()
    }

    private func finish(_ task: WKURLSchemeTask, key: ObjectIdentifier, data: Data, mime: String) {
        // Responding to a stopped task raises an exception, so only answer tasks still in flight.
        guard active.removeValue(forKey: key) != nil || !Task.isCancelled else { return }
        guard let url = task.request.url else { return }
        Debug.log("image respond \(url.absoluteString) \(mime) \(data.count) bytes")
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: Inline (cid:) images

    private func loadCID(id: Int, page: ImagePage) async -> (Data, String) {
        guard let cid = page.prepared.cids[id],
              let detail = MailService.shared.store.detail(page.messageID),
              let part = detail.structure?.part(withContentID: cid),
              let engine = MailService.shared.engine(page.accountID),
              let raw = try? await engine.partData(messageID: page.messageID, partID: part.partID) else {
            return (Self.transparentGIF, "image/gif")
        }
        return await Self.processed(raw, fallbackMime: part.mimeType)
    }

    // MARK: Remote images

    private func loadRemote(id: Int, isBackground: Bool, page: ImagePage) async -> (Data, String) {
        guard let url = page.prepared.remote[id] else { return (Self.transparentGIF, "image/gif") }
        let forced = page.forced.contains(id)
        if !page.autoLoad && !forced {
            return hold(id: id, bytes: 0, isBackground: isBackground, page: page)
        }
        if let cached = Self.cached(url) { return cached }

        let perImage = Prefs.imageMaxBytes
        let perMessage = Prefs.imageMessageMaxBytes
        let unlimited = forced || page.ignoreLimits
        do {
            let (bytes, response) = try await session.bytes(from: url)
            // Error pages (404, 403, HTML) must not be handed to WebKit as images.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let type = response.mimeType?.lowercased() ?? ""
            guard (200..<300).contains(status), type.hasPrefix("image/") || type == "application/octet-stream" || type.isEmpty else {
                bytes.task.cancel()
                Debug.log("image rejected \(url) status=\(status) type=\(type)")
                return (Self.transparentGIF, "image/gif")
            }
            let expected = Int(response.expectedContentLength)
            if !unlimited {
                if expected > perImage || (expected > 0 && page.bytesLoaded + expected > perMessage) {
                    bytes.task.cancel()
                    return hold(id: id, bytes: expected, isBackground: isBackground, page: page)
                }
            }
            var data = Data()
            if expected > 0 { data.reserveCapacity(min(expected, 32 * 1_048_576)) }
            let hardCap = unlimited ? 40 * 1_048_576 : perImage
            for try await b in bytes {
                data.append(b)
                if data.count > hardCap {
                    bytes.task.cancel()
                    return hold(id: id, bytes: data.count, isBackground: isBackground, page: page)
                }
            }
            if !unlimited && page.bytesLoaded + data.count > perMessage {
                return hold(id: id, bytes: data.count, isBackground: isBackground, page: page)
            }
            page.bytesLoaded += data.count
            let mime = type.hasPrefix("image/") ? type : "image/jpeg"
            let result = await Self.processed(data, fallbackMime: mime)
            Self.store(url, result)
            return result
        } catch {
            Debug.log("image fetch failed \(url): \(error)")
            return (Self.transparentGIF, "image/gif")
        }
    }

    private func hold(id: Int, bytes: Int, isBackground: Bool, page: ImagePage) -> (Data, String) {
        page.blocked[id] = bytes
        onBlocked?(page)
        if isBackground { return (Self.transparentGIF, "image/gif") }
        markBlocked?(id)
        return (Self.placeholderSVG(bytes: bytes, spam: !page.autoLoad, dark: page.dark), "image/svg+xml")
    }

    // MARK: Processing

    /// Shrinks images larger than the pixel cap (decoded size is what costs RAM, not file size).
    /// Animated images and formats ImageIO can't read pass through unchanged.
    nonisolated static func processed(_ data: Data, fallbackMime: String) async -> (Data, String) {
        await Task.detached(priority: .userInitiated) { () -> (Data, String) in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(src) as String? else { return (data, fallbackMime) }
            let mime = UTType(type)?.preferredMIMEType ?? fallbackMime
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if w > 0, h > 0, w * h <= 4 { return (transparentGIF, "image/gif") }
            if CGImageSourceGetCount(src) > 1 || max(w, h) <= Prefs.imageMaxPixels { return (data, mime) }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Prefs.imageMaxPixels,
                kCGImageSourceShouldCacheImmediately: false,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return (data, mime) }
            let hasAlpha: Bool = {
                switch thumb.alphaInfo {
                case .none, .noneSkipFirst, .noneSkipLast: return false
                default: return true
                }
            }()
            let outType = hasAlpha ? UTType.png : UTType.jpeg
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, outType.identifier as CFString, 1, nil) else { return (data, mime) }
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return (data, mime) }
            return (out as Data, outType.preferredMIMEType ?? "image/jpeg")
        }.value
    }

    // MARK: Disk cache (processed images, LRU-pruned to 200 MB)

    nonisolated private static func cacheURL(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return AppPaths.imageCache.appendingPathComponent(String(digest.prefix(40)))
    }

    nonisolated private static func cached(_ url: URL) -> (Data, String)? {
        let file = cacheURL(url)
        guard let data = try? Data(contentsOf: file), data.count > 1,
              let mimeLen = data.first, data.count > Int(mimeLen) + 1 else { return nil }
        let mime = String(decoding: data[1...Int(mimeLen)], as: UTF8.self)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return (data.subdata(in: (Int(mimeLen) + 1)..<data.count), mime)
    }

    nonisolated private static func store(_ url: URL, _ value: (Data, String)) {
        let mime = Data(value.1.utf8.prefix(255))
        var out = Data([UInt8(mime.count)])
        out.append(mime)
        out.append(value.0)
        try? out.write(to: cacheURL(url), options: .atomic)
    }

    nonisolated static func pruneCache() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let files = try? fm.contentsOfDirectory(at: AppPaths.imageCache, includingPropertiesForKeys: keys) else { return }
            var entries = files.compactMap { f -> (URL, Date, Int)? in
                guard let v = try? f.resourceValues(forKeys: Set(keys)) else { return nil }
                return (f, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
            }
            var total = entries.reduce(0) { $0 + $1.2 }
            guard total > Prefs.imageCacheBytes else { return }
            entries.sort { $0.1 < $1.1 }
            for e in entries where total > Prefs.imageCacheBytes * 8 / 10 {
                try? fm.removeItem(at: e.0)
                total -= e.2
            }
        }
    }

    // MARK: Placeholders

    nonisolated static let transparentGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    nonisolated static func placeholderSVG(bytes: Int, spam: Bool, dark: Bool = false) -> Data {
        let (fill, stroke, ink) = dark ? ("#2a2a2c", "#4a4a4e", "#c8c8cc") : ("#f2f3f5", "#c9ccd1", "#4a4f57")
        let label: String
        if spam { label = "Image hidden · click to load" }
        else if bytes > 0 { label = "Load image · \(MIME.formatSize(bytes))" }
        else { label = "Load image" }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="360" height="120" viewBox="0 0 360 120">
        <rect x="1" y="1" width="358" height="118" rx="10" fill="\(fill)" stroke="\(stroke)" stroke-dasharray="5 4"/>
        <g fill="none" stroke="#8a8f98" stroke-width="2" transform="translate(162 26)"><rect x="0" y="0" width="36" height="28" rx="4"/>
        <circle cx="11" cy="10" r="3.5"/><path d="M2 25 l11-10 8 7 5-4 8 7"/></g>
        <text x="180" y="88" font-family="-apple-system,Helvetica" font-size="14" fill="\(ink)" text-anchor="middle">\(label)</text>
        </svg>
        """
        return Data(svg.utf8)
    }
}
