import AppKit
import WebKit

/// Demo-mode window capture for README screenshots and UI checks, without Screen Recording permission:
/// AppKit views draw into a bitmap, and each WKWebView contributes its own snapshot at its frame.
@MainActor
enum Snapshot {
    static func write(window: NSWindow, to path: String) async {
        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        var webs: [WKWebView] = []
        func collect(_ v: NSView) {
            if let w = v as? WKWebView { webs.append(w) } else { v.subviews.forEach(collect) }
        }
        collect(frameView)
        for web in webs where !web.isHiddenOrHasHiddenAncestor {
            let config = WKSnapshotConfiguration()
            guard let shot = try? await web.takeSnapshot(configuration: config) else { continue }
            let rect = web.convert(web.bounds, to: frameView)
            image.lockFocus()
            NSColor.white.setFill()
            rect.fill()
            shot.draw(in: rect)
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
