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
    private static let activeContent = try! NSRegularExpression(
        pattern: "<(script|iframe|object|embed|applet|form)\\b[^>]*>.*?</\\1\\s*>|<(script|iframe|object|embed|meta\\s+http-equiv|base|link)\\b[^>]*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let imgTag = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive])
    private static let srcAttr = try! NSRegularExpression(
        pattern: "\\ssrc\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive])
    private static let srcsetAttr = try! NSRegularExpression(
        pattern: "\\ssrcset\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive])
    private static let dimAttr = try! NSRegularExpression(
        pattern: "\\s(width|height)\\s*=\\s*[\"']?\\s*(\\d+)", options: [.caseInsensitive])
    private static let cssURL = try! NSRegularExpression(
        pattern: "url\\(\\s*(['\"]?)(https?://[^'\")\\s]+)\\1\\s*\\)", options: [.caseInsensitive])
    private static let bgAttr = try! NSRegularExpression(
        pattern: "\\sbackground\\s*=\\s*([\"'])(https?://[^\"']+)\\1", options: [.caseInsensitive])
    private static let headOpen = try! NSRegularExpression(pattern: "<head\\b[^>]*>", options: [.caseInsensitive])
    private static let urlLink = try! NSRegularExpression(pattern: "(https?://[^\\s<>\"]+)", options: [])

    /// `forceLight`: show the email exactly as designed on white ("Show with light background").
    static func prepare(html: String?, text: String?, clip: Bool = true, forceLight: Bool = false) -> PreparedHTML {
        if let html, !html.isEmpty { return prepareHTML(html, clip: clip, forceLight: forceLight) }
        return PreparedHTML(html: wrapPlain(text ?? "", forceLight: forceLight))
    }

    /// Matches ReadingPaneView's dark background so the email blends into the app.
    static let darkBackground = "#1e1e1e"

    private static func prepareHTML(_ input: String, clip: Bool, forceLight: Bool) -> PreparedHTML {
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
        s = replace(activeContent, in: s) { _, _ in "" }

        var nextID = 0
        s = replace(imgTag, in: s) { tag, _ in
            var t = tag
            let tns = t as NSString
            var w: Int?
            var h: Int?
            for m in dimAttr.matches(in: t, range: NSRange(location: 0, length: tns.length)) {
                let name = tns.substring(with: m.range(at: 1)).lowercased()
                let v = Int(tns.substring(with: m.range(at: 2)))
                if name == "width" { w = v } else { h = v }
            }
            t = srcsetAttr.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
            let tn = t as NSString
            guard let m = srcAttr.firstMatch(in: t, range: NSRange(location: 0, length: tn.length)) else { return t }
            var src = ""
            for g in 1...3 where m.range(at: g).location != NSNotFound { src = tn.substring(with: m.range(at: g)) }
            src = MIME.decodeEntities(src).trimmingCharacters(in: .whitespaces)
            let lower = src.lowercased()
            // Tracking pixels: 1×1 (or 0×0) remote images. Dropped entirely.
            if lower.hasPrefix("http"), let w, let h, w <= 2, h <= 2 {
                out.trackersRemoved += 1
                return ""
            }
            let id = nextID
            nextID += 1
            let replacement: String
            if lower.hasPrefix("http://") || lower.hasPrefix("https://"), let url = URL(string: src) {
                out.remote[id] = url
                replacement = " src=\"lm://img/\(id)\" data-lm=\"\(id)\""
            } else if lower.hasPrefix("cid:") {
                out.cids[id] = String(src.dropFirst(4))
                replacement = " src=\"lm://cid/\(id)\" data-lm=\"\(id)\""
            } else if lower.hasPrefix("data:") {
                return t
            } else {
                replacement = " data-lm-dropped=\"1\""
            }
            return tn.replacingCharacters(in: m.range, with: replacement)
        }
        s = replace(cssURL, in: s) { _, m in
            guard let url = URL(string: m[2]) else { return "none" }
            let id = nextID
            nextID += 1
            out.remote[id] = url
            out.backgrounds.insert(id)
            return "url(lm://bg/\(id))"
        }
        s = replace(bgAttr, in: s) { _, m in
            guard let url = URL(string: m[2]) else { return "" }
            let id = nextID
            nextID += 1
            out.remote[id] = url
            out.backgrounds.insert(id)
            return " background=\"lm://bg/\(id)\""
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
        <meta charset="utf-8"><meta name="color-scheme" content="\(scheme)">
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

    private static func wrapPlain(_ text: String, forceLight: Bool) -> String {
        var escaped = MIME.escapeHTML(text)
        escaped = urlLink.stringByReplacingMatches(in: escaped, range: NSRange(location: 0, length: (escaped as NSString).length),
                                                   withTemplate: "<a href=\"$1\">$1</a>")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="\(forceLight ? "light" : "light dark")">
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
