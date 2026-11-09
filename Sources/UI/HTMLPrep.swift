import Foundation

/// Rewrites an email's HTML before WebKit sees it: every remote image is routed through the app's own loader
/// (lm:// URLs), tracking pixels and active content are removed, and huge messages are clipped.
struct PreparedHTML {
    var html: String
    var remote: [Int: URL] = [:]
    var cids: [Int: String] = [:]
    var backgrounds: Set<Int> = []
    var clipped = false
    var trackersRemoved = 0
    var hasRemoteImages: Bool { !remote.isEmpty }
}

enum HTMLPrep {
    private static let imgTag = try! NSRegularExpression(pattern: "<(?:img|image|input)\\b[^>]*>", options: [.caseInsensitive])
    // Attributes may follow "/" as well as whitespace (<img/src=x>, <img width=1/src=…>) and be unquoted.
    private static let srcAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)src\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive])
    // SVG <image> uses href/xlink:href instead of src.
    private static let hrefAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)(?:xlink:)?href\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive])
    private static let srcsetAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)(?:srcset|imagesrcset)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive])
    private static let posterAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)poster\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive])
    private static let dimAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)(width|height)\\s*=\\s*[\"']?\\s*(\\d+)", options: [.caseInsensitive])
    private static let styleAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)style\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
    private static let cssDim = try! NSRegularExpression(
        pattern: "(?:^|[;\\s])(width|height)\\s*:\\s*([0-9.]+)px", options: [.caseInsensitive])
    private static let cssURL = try! NSRegularExpression(
        pattern: "url\\(\\s*(['\"]?)([^)'\"]+)\\1\\s*\\)", options: [.caseInsensitive])
    private static let cssImport = try! NSRegularExpression(
        pattern: "@import\\s+(?:url\\s*\\(\\s*)?(['\"]?)(?:https?:)?//[^'\"\\s)]+\\1?\\s*\\)?\\s*;?", options: [.caseInsensitive])
    private static let bgAttr = try! NSRegularExpression(
        pattern: "(?:\\s|/)background\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive])
    // Bodyless tags that can still trigger loads or rewrites (meta refresh, base, remote styles).
    private static let voidActive = try! NSRegularExpression(
        pattern: "<(?:meta\\b[^>]*http-equiv[^>]*|base\\b[^>]*|link\\b[^>]*)>", options: [.caseInsensitive])
    private static let headOpen = try! NSRegularExpression(pattern: "<head\\b[^>]*>", options: [.caseInsensitive])
    private static let urlLink = try! NSRegularExpression(pattern: "(https?://[^\\s<>\"]+)", options: [])

    /// `forceLight`: show the email exactly as designed on white ("Show with light background").
    /// `page` makes every image URL unique to this render (lm://img/<page>/<n>). WebKit caches by URL, so if two
    /// emails both used lm://img/1, the second would show the first one's picture.
    static func prepare(html: String?, text: String?, clip: Bool = true, forceLight: Bool = false, page: Int = 0) -> PreparedHTML {
        if let html, !html.isEmpty { return prepareHTML(html, clip: clip, forceLight: forceLight, page: page) }
        return PreparedHTML(html: wrapPlain(text ?? "", forceLight: forceLight))
    }

    /// Same as prepare(), but the heavy regex passes run off the main actor (large HTML takes real time).
    static func prepareOffMain(html: String?, text: String?, clip: Bool = true, forceLight: Bool = false, page: Int = 0) async -> PreparedHTML {
        await Task.detached(priority: .userInitiated) {
            prepare(html: html, text: text, clip: clip, forceLight: forceLight, page: page)
        }.value
    }

    /// Matches ReadingPaneView's dark background so the email blends into the app.
    static let darkBackground = "#1e1e1e"

    /// Strict CSP: whatever the regex sanitiser misses fails closed — no script, no remote fonts or styles,
    /// images only from the app's own loader (lm:) or inline data:.
    static let cspMeta = "<meta http-equiv=\"Content-Security-Policy\" " +
        "content=\"default-src 'none'; img-src lm: data:; style-src 'unsafe-inline'; font-src data:; " +
        "media-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'\">"

    private static func prepareHTML(_ input: String, clip: Bool, forceLight: Bool, page: Int) -> PreparedHTML {
        var out = PreparedHTML(html: "")
        var s = input
        if clip, s.utf8.count > Prefs.htmlClipBytes {
            // Cut at a tag boundary near the limit; WebKit closes open tags itself.
            let cut = s.utf8.index(s.utf8.startIndex, offsetBy: Prefs.htmlClipBytes)
            var head = String(s[..<cut])
            if let lt = head.lastIndex(of: "<") { head = String(head[..<lt]) }
            s = head
            out.clipped = true
        }
        s = stripActive(s)
        s = replace(voidActive, in: s) { _, _ in "" }
        s = replace(srcsetAttr, in: s) { _, _ in "" }
        s = replace(posterAttr, in: s) { _, _ in "" }
        s = replace(cssImport, in: s) { _, _ in "" }

        var nextID = 0
        s = replace(imgTag, in: s) { tag, _ in
            var t = tag
            let tns = t as NSString
            let tlen = tns.length
            // Dimensions from attributes and inline CSS (width/height in px) — for tracking-pixel detection.
            let known = Array(pixelDims(t).values)
            t = srcsetAttr.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: tlen), withTemplate: "")
            t = posterAttr.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: tlen), withTemplate: "")
            let tn = t as NSString
            let nlen = tn.length
            func attrMatch(_ re: NSRegularExpression) -> (String, NSRange)? {
                guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: nlen)) else { return nil }
                for g in 1...3 where m.range(at: g).location != NSNotFound {
                    return (tn.substring(with: m.range(at: g)), m.range(at: g))
                }
                return nil
            }
            guard let hit = attrMatch(srcAttr) ?? attrMatch(hrefAttr) else { return t }
            let src = MIME.decodeEntities(hit.0).trimmingCharacters(in: .whitespaces)
            let lower = src.lowercased()
            // Tracking pixels: remote images whose known dimensions are all ≤ 2px (attrs, CSS, or one of them).
            if lower.hasPrefix("http"), !known.isEmpty, known.allSatisfy({ $0 <= 2 }) {
                out.trackersRemoved += 1
                return ""
            }
            let id = nextID
            nextID += 1
            let replacement: String
            if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: src) {
                out.remote[id] = url
                replacement = " src=\"lm://img/\(page)/\(id)\" data-lm=\"\(id)\""
            } else if lower.hasPrefix("cid:") {
                out.cids[id] = String(src.dropFirst(4))
                replacement = " src=\"lm://cid/\(page)/\(id)\" data-lm=\"\(id)\""
            } else if lower.hasPrefix("data:") {
                return t
            } else {
                replacement = " data-lm-dropped=\"1\""
            }
            return tn.replacingCharacters(in: hit.1, with: replacement)
        }
        s = replace(cssURL, in: s) { _, m in
            // Entity-encoded URLs (&quot;https://…&quot;) decode to the same thing.
            let decoded = MIME.decodeEntities(m[2]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            guard decoded.lowercased().hasPrefix("http"), let url = URL(string: decoded) else { return m[0] }
            let id = nextID
            nextID += 1
            out.remote[id] = url
            out.backgrounds.insert(id)
            return "url(lm://bg/\(page)/\(id))"
        }
        s = replace(bgAttr, in: s) { _, m in
            guard var v = [m[1], m[2], m[3]].first(where: { !$0.isEmpty }) else { return m[0] }
            v = MIME.decodeEntities(v).trimmingCharacters(in: .whitespaces)
            guard v.lowercased().hasPrefix("http"), let url = URL(string: v) else { return m[0] }
            let id = nextID
            nextID += 1
            out.remote[id] = url
            out.backgrounds.insert(id)
            return " background=\"lm://bg/\(page)/\(id)\""
        }

        let scheme = forceLight ? "light" : "light dark"
        let darkCSS = forceLight ? "<meta name=\"lm-light\" content=\"1\">" : """
        <style>
        @media (prefers-color-scheme: dark) {
          html{background:\(darkBackground)}
          body{color:#e4e4e4}
          a{color:#6cb4ff}
          blockquote{border-left-color:#555;color:#b0b0b0}
        }
        </style>
        """
        let style = """
        \(cspMeta)<meta charset="utf-8"><meta name="color-scheme" content="\(scheme)">
        <style>
        html{background:#fff}
        body{margin:0;padding:16px 20px;font:14px/1.45 -apple-system,BlinkMacSystemFont,Helvetica,sans-serif;color:#1d1d1f;
             overflow-wrap:break-word;word-wrap:break-word}
        img{max-width:100%}
        img[data-lm-blocked="1"]{cursor:pointer}
        blockquote{margin:0 0 0 .8ex;border-left:2px solid #c9ccd1;padding-left:1ex;color:#555}
        pre{white-space:pre-wrap}
        </style>
        \(darkCSS)
        """
        let ns = s as NSString
        if let m = headOpen.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            s = ns.replacingCharacters(in: NSRange(location: m.range.location + m.range.length, length: 0), with: style)
        } else {
            s = "<!doctype html><html><head>\(style)</head><body>\(s)</body></html>"
        }
        out.html = s
        return out
    }

    /// Linear removal of <script>/<iframe>/<object>/<embed>/<applet>/<form>: a properly closed tag loses its
    /// body too, an unclosed one loses only its tag (the leftover content is inert — scripts are disabled and
    /// the CSP blocks every load). Single pass, no scan to end-of-string per unclosed tag.
    private static func stripActive(_ s: String) -> String {
        let names: [[UInt8]] = ["script", "iframe", "object", "embed", "applet", "form"].map { Array($0.utf8) }
        let b = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var pending: [UInt8]?
        var i = 0

        func isTag(_ at: Int, _ name: [UInt8]) -> Bool {
            guard at + name.count <= b.count else { return false }
            for k in 0..<name.count {
                var c = b[at + k]
                if c >= 65, c <= 90 { c += 32 }
                if c != name[k] { return false }
            }
            let after = at + name.count
            if after == b.count { return true }
            switch b[after] {
            case 0x3E, 0x2F, 0x20, 0x09, 0x0A, 0x0D: return true
            default: return false
            }
        }
        func skipToGT(_ from: Int) -> Int {
            var j = from
            while j < b.count, b[j] != 0x3E { j += 1 }
            return j + 1
        }

        while i < b.count {
            if b[i] == 0x3C, i + 1 < b.count {
                if b[i + 1] == 0x2F {
                    let j = i + 2
                    if let n = names.first(where: { isTag(j, $0) }) {
                        i = skipToGT(j + n.count)
                        if pending == n { pending = nil }
                        continue
                    }
                } else if let n = names.first(where: { isTag(i + 1, $0) }) {
                    i = skipToGT(i + 1 + n.count)
                    if pending == nil { pending = n }
                    continue
                }
            }
            out.append(b[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func wrapPlain(_ text: String, forceLight: Bool) -> String {
        var escaped = MIME.escapeHTML(text)
        escaped = urlLink.stringByReplacingMatches(in: escaped, range: NSRange(location: 0, length: (escaped as NSString).length),
                                                   withTemplate: "<a href=\"$1\">$1</a>")
        return """
        <!doctype html><html><head>\(cspMeta)<meta charset="utf-8"><meta name="color-scheme" content="\(forceLight ? "light" : "light dark")">
        <style>
        html{background:#fff}
        body{margin:0;padding:16px 20px;font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;white-space:pre-wrap;
             overflow-wrap:anywhere;color:#1d1d1f}
        \(forceLight ? "" : "@media (prefers-color-scheme: dark){html{background:\(darkBackground)} body{color:#e6e6e6} a{color:#6cb4ff}}")
        </style></head><body>\(escaped)</body></html>
        """
    }

    /// Regex replace with access to the whole match and its capture groups.
    private static func replace(_ re: NSRegularExpression, in s: String, _ f: (String, [String]) -> String) -> String {
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        out.reserveCapacity(ns.length)
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            out += f(groups[0], groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Dimensions declared by an <img> tag: attributes and inline CSS (width/height in px).
    private static func pixelDims(_ tag: String) -> [String: Int] {
        let tns = tag as NSString
        let tlen = tns.length
        var dims: [String: Int] = [:]
        for m in dimAttr.matches(in: tag, range: NSRange(location: 0, length: tlen)) {
            dims[tns.substring(with: m.range(at: 1)).lowercased()] = Int(tns.substring(with: m.range(at: 2)))
        }
        for m in styleAttr.matches(in: tag, range: NSRange(location: 0, length: tlen)) {
            let raw = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let style = MIME.decodeEntities(tns.substring(with: raw))
            let sns = style as NSString
            for c in cssDim.matches(in: style, range: NSRange(location: 0, length: sns.length)) {
                dims[sns.substring(with: c.range(at: 1)).lowercased()] =
                    Int((Double(sns.substring(with: c.range(at: 2))) ?? 0).rounded())
            }
        }
        return dims
    }

    /// First src/href-style attribute value of a tag, if any.
    private static func attrValue(_ tag: String, _ re: NSRegularExpression) -> String? {
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for g in 1...3 where m.range(at: g).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: g))
        }
        return nil
    }

    /// Tracking pixels: remote images whose known dimensions are all ≤ 2px (attrs, CSS, or one of them).
    private static func isTrackingPixel(_ tag: String) -> Bool {
        guard let src = attrValue(tag, srcAttr) ?? attrValue(tag, hrefAttr) else { return false }
        let lower = MIME.decodeEntities(src).trimmingCharacters(in: .whitespaces).lowercased()
        let dims = pixelDims(tag)
        return lower.hasPrefix("http") && !dims.isEmpty && dims.values.allSatisfy { $0 <= 2 }
    }

    /// Body fragment safe to quote into an outgoing reply/forward: the same sanitising as the display
    /// path (active content, remote-setting meta/base/link tags, srcset and tracking pixels removed),
    /// but images keep their original URLs — the recipient's mail client loads them.
    static func quoteSanitized(_ html: String) -> String {
        var s = stripActive(html)
        s = replace(voidActive, in: s) { _, _ in "" }
        s = replace(srcsetAttr, in: s) { _, _ in "" }
        s = replace(posterAttr, in: s) { _, _ in "" }
        s = replace(cssImport, in: s) { _, _ in "" }
        s = replace(imgTag, in: s) { tag, _ in isTrackingPixel(tag) ? "" : tag }
        return s
    }

    /// Body inner HTML, for quoting in replies.
    static func bodyInner(_ html: String) -> String {
        let lower = html.lowercased()
        guard let bodyStart = lower.range(of: "<body") else { return html }
        guard let gt = lower[bodyStart.upperBound...].firstIndex(of: ">") else { return html }
        let startOffset = lower.distance(from: lower.startIndex, to: gt) + 1
        let endOffset = lower.range(of: "</body>").map { lower.distance(from: lower.startIndex, to: $0.lowerBound) } ?? lower.count
        guard endOffset > startOffset else { return html }
        let si = html.index(html.startIndex, offsetBy: startOffset)
        let ei = html.index(html.startIndex, offsetBy: endOffset)
        return String(html[si..<ei])
    }
}

/// Outlook-style dark mode for HTML email, run in the app's own script world (the email's scripts stay off).
/// Light, unsaturated backgrounds are darkened keeping their hue; text that ends up dark-on-dark is lightened.
/// Images, gradients and saturated brand colours are left alone. Skipped in light mode or "light background" view.
enum DarkReader {
    static let script = """
    (function(){
      if (!window.matchMedia || !window.matchMedia('(prefers-color-scheme: dark)').matches) return;
      if (document.querySelector('meta[name="lm-light"]') || !document.body) return;
      var PAGE = {r:30, g:30, b:30, a:1};
      function parse(s){ var m = /rgba?\\(([^)]+)\\)/.exec(s || ''); if (!m) return null;
        var p = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(parseFloat);
        return {r:p[0], g:p[1], b:p[2], a: p.length > 3 ? p[3] : 1}; }
      function lum(c){ return (0.2126*c.r + 0.7152*c.g + 0.0722*c.b) / 255; }
      function hsl(c){ var r=c.r/255, g=c.g/255, b=c.b/255, mx=Math.max(r,g,b), mn=Math.min(r,g,b), h=0, s=0, l=(mx+mn)/2;
        if (mx !== mn) { var d = mx - mn; s = l > 0.5 ? d/(2-mx-mn) : d/(mx+mn);
          h = mx === r ? (g-b)/d + (g < b ? 6 : 0) : mx === g ? (b-r)/d + 2 : (r-g)/d + 4; h /= 6; }
        return [h, s, l]; }
      function rgb(h, s, l){ function f(p,q,t){ if(t<0)t+=1; if(t>1)t-=1; if(t<1/6)return p+(q-p)*6*t; if(t<1/2)return q;
          if(t<2/3)return p+(q-p)*(2/3-t)*6; return p; }
        var r, g, b; if (s === 0) { r = g = b = l; } else { var q = l < 0.5 ? l*(1+s) : l+s-l*s, p = 2*l-q;
          r = f(p,q,h+1/3); g = f(p,q,h); b = f(p,q,h-1/3); }
        return {r: Math.round(r*255), g: Math.round(g*255), b: Math.round(b*255), a: 1}; }
      function css(c){ return 'rgb(' + c.r + ',' + c.g + ',' + c.b + ')'; }
      var els = [document.body].concat(Array.prototype.slice.call(document.body.getElementsByTagName('*'), 0, 8000));
      var bgOf = new Map();
      els.forEach(function(el){
        var bg = parse(getComputedStyle(el).backgroundColor);
        if (!bg || bg.a < 0.1) return;
        var h = hsl(bg);
        if (h[2] > 0.55 && h[1] < 0.65) {
          var dark = rgb(h[0], h[1] * 0.45, 0.12 + (1 - h[2]) * 0.45);
          el.style.setProperty('background-color', css(dark), 'important');
          bgOf.set(el, dark);
        } else { bgOf.set(el, bg); }
        var bc = parse(getComputedStyle(el).borderTopColor);
        if (bc && bc.a > 0.1 && lum(bc) > 0.7) el.style.setProperty('border-color', 'rgba(255,255,255,0.15)', 'important');
      });
      function effective(el){ for (var e = el; e && e.nodeType === 1; e = e.parentElement) {
          var b = bgOf.get(e); if (b && b.a >= 0.5) return b; } return PAGE; }
      els.forEach(function(el){
        var text = false;
        for (var n = el.firstChild; n; n = n.nextSibling) { if (n.nodeType === 3 && n.nodeValue.trim()) { text = true; break; } }
        if (!text) return;
        var c = parse(getComputedStyle(el).color); if (!c) return;
        var bgL = lum(effective(el));
        if (bgL < 0.45 && lum(c) < 0.55) {
          var h = hsl(c);
          el.style.setProperty('color', css(rgb(h[0], Math.min(h[1], 0.7), Math.max(0.8, 1 - h[2]))), 'important');
        }
      });
    })();
    """
}
