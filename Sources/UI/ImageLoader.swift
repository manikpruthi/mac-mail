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
    /// Requests already started for this page (budget is reserved before contacting a host).
    var requestsStarted = 0
    var hostRequests: [String: Int] = [:]
    /// Dark placeholders when the page is shown in dark mode.
    var dark = false

    private var cidParts: [String: BodyPart?] = [:]

    /// cid → part, resolved once per message (the detail row and BODYSTRUCTURE JSON are not re-fetched per image).
    func part(forCID cid: String) -> BodyPart? {
        if let hit = cidParts[cid] { return hit }
        let part = MailService.shared.store.detail(messageID)?.structure?.part(withContentID: cid)
        cidParts[cid] = part
        return part
    }

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
    /// Redirects are followed only to https URLs on public hosts (image CDNs and mail trackers redirect a lot);
    /// http targets are upgraded to https, and anything resolving to a local/private address is refused.
    private final class RedirectBlocker: NSObject, URLSessionDataDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url.flatMap(ImageLoader.httpsURL), let host = url.host,
                  !ImageLoader.resolvesToPrivateAddressSync(host) else { completionHandler(nil); return }
            var next = request
            next.url = url
            completionHandler(next)
        }
    }

    /// https URLs pass through; http ones are upgraded (App Transport Security refuses plain http, and nearly
    /// every image host serves both). Anything else is nil.
    nonisolated static func httpsURL(_ url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http":
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.scheme = "https"
            if c?.port == 80 { c?.port = nil }
            return c?.url
        default: return nil
        }
    }
    private static let redirectBlocker = RedirectBlocker()
    // Newsletters serve every image from one CDN host, so the per-host cap matches the per-message one.
    private static let maxRequestsPerPage = 60
    private static let maxRequestsPerHost = 60
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 4
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) MacMail/1.0", "Accept": "image/*,*/*;q=0.5"]
        return URLSession(configuration: c, delegate: ImageLoader.redirectBlocker, delegateQueue: nil)
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
              let part = page.part(forCID: cid),
              let engine = MailService.shared.engine(page.accountID),
              let raw = try? await engine.partData(messageID: page.messageID, partID: part.partID) else {
            return (Self.transparentGIF, "image/gif")
        }
        return await Self.processed(raw, fallbackMime: part.mimeType)
    }

    // MARK: Remote images

    private func loadRemote(id: Int, isBackground: Bool, page: ImagePage) async -> (Data, String) {
        guard let original = page.prepared.remote[id] else { return (Self.transparentGIF, "image/gif") }
        let forced = page.forced.contains(id)
        if !page.autoLoad && !forced {
            return hold(id: id, bytes: 0, isBackground: isBackground, page: page)
        }
        // Only https to a named host: plain http is upgraded, never contacted in the clear.
        guard let url = Self.httpsURL(original), let host = url.host, !host.isEmpty else {
            Debug.log("image rejected \(original)")
            return (Self.transparentGIF, "image/gif")
        }
        if let cached = Self.cached(url) { return cached }

        let perImage = Prefs.imageMaxBytes
        let perMessage = Prefs.imageMessageMaxBytes
        let unlimited = forced || page.ignoreLimits
        // Budget and request caps are reserved before contacting the host, so a crafted message can't
        // queue unlimited fetches; user-forced images still get through.
        if !unlimited {
            guard page.requestsStarted < Self.maxRequestsPerPage,
                  (page.hostRequests[host] ?? 0) < Self.maxRequestsPerHost,
                  page.bytesLoaded < perMessage else {
                return hold(id: id, bytes: 0, isBackground: isBackground, page: page)
            }
            page.requestsStarted += 1
            page.hostRequests[host, default: 0] += 1
        }
        if await Self.resolvesToPrivateAddress(host) {
            Debug.log("image blocked \(url) (private address)")
            return (Self.transparentGIF, "image/gif")
        }
        do {
            let (byteStream, response) = try await session.bytes(from: url)
            // Error pages (404, 403, HTML) must not be handed to WebKit as images.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let type = response.mimeType?.lowercased() ?? ""
            guard (200..<300).contains(status), type.hasPrefix("image/") || type == "application/octet-stream" || type.isEmpty else {
                byteStream.task.cancel()
                Debug.log("image rejected \(url) status=\(status) type=\(type)")
                return (Self.transparentGIF, "image/gif")
            }
            let expected = Int(response.expectedContentLength)
            if !unlimited {
                if expected > perImage || (expected > 0 && page.bytesLoaded + expected > perMessage) {
                    byteStream.task.cancel()
                    return hold(id: id, bytes: expected, isBackground: isBackground, page: page)
                }
            }
            let hardCap = unlimited ? 40 * 1_048_576 : perImage
            // The byte stream is consumed off the main actor, buffered into 64 KB chunks —
            // per-element awaits would otherwise stall the UI for seconds on a few MB.
            enum Download { case ok(Data); case overCap(Int) }
            let outcome = try await Task.detached(priority: .userInitiated) { () -> Download in
                var data = Data()
                if expected > 0 { data.reserveCapacity(min(expected, 32 * 1_048_576)) }
                let bytes = byteStream
                var chunk = Data()
                chunk.reserveCapacity(65_536)
                do {
                    for try await b in bytes {
                        chunk.append(b)
                        if chunk.count >= 65_536 {
                            data.append(chunk)
                            chunk.removeAll(keepingCapacity: true)
                            if data.count > hardCap { bytes.task.cancel(); return .overCap(data.count) }
                        }
                    }
                } catch {
                    bytes.task.cancel()
                    throw error
                }
                data.append(chunk)
                return .ok(data)
            }.value
            switch outcome {
            case .overCap(let size):
                return hold(id: id, bytes: size, isBackground: isBackground, page: page)
            case .ok(let data):
                if !unlimited && page.bytesLoaded + data.count > perMessage {
                    return hold(id: id, bytes: data.count, isBackground: isBackground, page: page)
                }
                page.bytesLoaded += data.count
                let mime = type.hasPrefix("image/") ? type : "image/jpeg"
                let result = await Self.processed(data, fallbackMime: mime)
                Self.store(url, result)
                return result
            }
        } catch {
            Debug.log("image fetch failed \(url): \(error)")
            return (Self.transparentGIF, "image/gif")
        }
    }

    // MARK: Private-address filtering (SSRF)

    /// True if any address the host resolves to is loopback, link-local, private, CGNAT or unroutable.
    nonisolated private static func resolvesToPrivateAddress(_ host: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { resolvesToPrivateAddressSync(host) }.value
    }

    /// Blocking DNS lookup; call off the main thread (the URLSession delegate queue or a detached task).
    nonisolated static func resolvesToPrivateAddressSync(_ host: String) -> Bool {
        do {
            var info: UnsafeMutablePointer<addrinfo>?
            // Unresolvable hosts fail closed.
            guard getaddrinfo(host, nil, nil, &info) == 0, let first = info else { return true }
            defer { freeaddrinfo(first) }
            var cur: UnsafeMutablePointer<addrinfo>? = first
            while let p = cur {
                let addr = p.pointee.ai_addr
                if let addr {
                    let len = Int(addr.pointee.sa_len)
                    if len >= 8, isBlockedAddress(Array(UnsafeRawBufferPointer(start: addr, count: len))) { return true }
                }
                cur = p.pointee.ai_next
            }
            return false
        }
    }

    /// `b` is a raw sockaddr: byte 0 is sa_len, byte 1 sa_family (Darwin layout).
    nonisolated private static func isBlockedAddress(_ b: [UInt8]) -> Bool {
        guard b.count > 1 else { return true }
        switch b[1] {
        case 2: // AF_INET
            guard b.count >= 8 else { return true }
            let a0 = b[4], a1 = b[5]
            if a0 == 0 || a0 == 10 || a0 == 127 { return true }
            if a0 == 169 && a1 == 254 { return true }            // link-local
            if a0 == 172 && (a1 & 0xF0) == 16 { return true }    // 172.16/12
            if a0 == 192 && a1 == 168 { return true }
            if a0 == 100 && (a1 & 0xC0) == 64 { return true }    // CGNAT 100.64/10
            return false
        case 30: // AF_INET6
            guard b.count >= 24 else { return true }
            let a = Array(b[8...23])
            if a.prefix(15).allSatisfy({ $0 == 0 }) { return true } // :: and ::1
            if a[0] == 0xfe && (a[1] & 0xC0) == 0x80 { return true } // fe80::/10 link-local
            if (a[0] & 0xFE) == 0xFC { return true }                 // fc00::/7 unique local
            if a.prefix(10).allSatisfy({ $0 == 0 }), a[10] == 0xff, a[11] == 0xff { // ::ffff:v4
                return isBlockedAddress([8, 2, 0, 0, a[12], a[13], a[14], a[15]])
            }
            return false
        default:
            return true
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
            // Within the pixel budget everything passes through, animated images included. Anything larger —
            // animated or not — is downsampled from frame 0 so a huge GIF never decodes at full size.
            if max(w, h) <= Prefs.imageMaxPixels { return (data, mime) }
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
