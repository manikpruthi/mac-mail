import Foundation

/// A MIME part tree, parsed from IMAP BODYSTRUCTURE and cached as JSON per message so the app knows
/// which parts to fetch (text only for reading, attachments on demand) without downloading the whole message.
struct BodyPart: Codable, Equatable {
    var partID: String
    var type: String          // lowercased, e.g. "text"
    var subtype: String       // lowercased, e.g. "html"
    var params: [String: String] = [:]
    var contentID: String?
    var encoding: String = "7bit"
    var size: Int = 0
    var disposition: String?
    var dispositionParams: [String: String] = [:]
    var children: [BodyPart] = []

    var mimeType: String { "\(type)/\(subtype)" }
    var isMultipart: Bool { type == "multipart" }
    var charset: String? { params["charset"] }

    var filename: String? {
        MIME.parameter("filename", in: dispositionParams) ?? MIME.parameter("name", in: params)
    }

    /// Approximate decoded size (base64 inflates by 4/3).
    var decodedSize: Int { encoding.lowercased() == "base64" ? size * 3 / 4 : size }

    var isAttachmentDisposition: Bool { disposition?.lowercased() == "attachment" }

    // MARK: Parsing

    static func parse(_ value: IMAPValue) -> BodyPart? {
        guard let list = value.list else { return nil }
        return parse(list, partID: "")
    }

    private static func parse(_ v: [IMAPValue], partID: String) -> BodyPart? {
        guard !v.isEmpty else { return nil }
        if v.first?.list != nil {
            // Multipart: (child)(child)... "SUBTYPE" [params [disposition [language [location]]]]
            var children: [BodyPart] = []
            var i = 0
            while i < v.count, let childList = v[i].list {
                let childID = partID.isEmpty ? "\(i + 1)" : "\(partID).\(i + 1)"
                if let child = parse(childList, partID: childID) { children.append(child) }
                i += 1
            }
            var part = BodyPart(partID: partID.isEmpty ? "TEXT" : partID, type: "multipart",
                                subtype: (i < v.count ? v[i].text ?? "mixed" : "mixed").lowercased())
            part.children = children
            if i + 1 < v.count { part.params = pairs(v[i + 1]) }
            if i + 2 < v.count { (part.disposition, part.dispositionParams) = disposition(v[i + 2]) }
            return part
        }
        // Single part: type subtype params id description encoding size ...
        let myID = partID.isEmpty ? "1" : partID
        var part = BodyPart(partID: myID, type: (v[0].text ?? "application").lowercased(),
                            subtype: (v.count > 1 ? v[1].text ?? "octet-stream" : "octet-stream").lowercased())
        if v.count > 2 { part.params = pairs(v[2]) }
        if v.count > 3, let cid = v[3].text { part.contentID = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
        if v.count > 5, let enc = v[5].text { part.encoding = enc.lowercased() }
        if v.count > 6, let size = v[6].number { part.size = Int(size) }
        var extStart = 7
        if part.type == "text" { extStart = 8 }
        if part.type == "message" && part.subtype == "rfc822" { extStart = 10 }
        // Extension data: md5, disposition, language, location.
        if v.count > extStart + 1 { (part.disposition, part.dispositionParams) = disposition(v[extStart + 1]) }
        return part
    }

    private static func pairs(_ v: IMAPValue) -> [String: String] {
        guard let l = v.list else { return [:] }
        var out: [String: String] = [:]
        var i = 0
        while i + 1 < l.count {
            if let k = l[i].text?.lowercased(), let val = l[i + 1].text { out[k] = val }
            i += 2
        }
        return out
    }

    private static func disposition(_ v: IMAPValue) -> (String?, [String: String]) {
        guard let l = v.list, let first = l.first?.text else { return (nil, [:]) }
        return (first.lowercased(), l.count > 1 ? pairs(l[1]) : [:])
    }

    // MARK: Queries

    var leaves: [BodyPart] {
        isMultipart ? children.flatMap { $0.leaves } : [self]
    }

    /// The parts used to render the message: the best HTML part and the best plain-text part.
    func displayParts() -> (html: BodyPart?, text: BodyPart?) {
        var html: BodyPart?
        var text: BodyPart?
        func walk(_ p: BodyPart) {
            if p.isMultipart {
                for c in p.children { walk(c) }
                return
            }
            guard p.type == "text", !p.isAttachmentDisposition else { return }
            if p.filename != nil && p.disposition != nil && p.disposition != "inline" { return }
            if p.subtype == "html", html == nil { html = p }
            if p.subtype == "plain", text == nil { text = p }
        }
        walk(self)
        return (html, text)
    }

    /// Parts shown as attachment chips. Inline images referenced by Content-ID are not listed.
    func attachments() -> [BodyPart] {
        let display = displayParts()
        return leaves.filter { p in
            if p.partID == display.html?.partID || p.partID == display.text?.partID { return false }
            if p.isAttachmentDisposition { return true }
            if p.type == "image", p.contentID != nil, p.disposition != "attachment" { return false }
            if p.type == "text" && p.filename == nil { return false }
            return p.filename != nil || p.type == "application" || p.type == "message" || p.type == "audio" || p.type == "video"
                || p.type == "image"
        }
    }

    func part(withContentID cid: String) -> BodyPart? {
        let target = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
        return leaves.first { $0.contentID?.lowercased() == target }
    }

    func part(withID id: String) -> BodyPart? {
        leaves.first { $0.partID == id }
    }

    var hasAttachments: Bool { !attachments().isEmpty }

    var suggestedFilename: String {
        if let f = filename, !f.isEmpty { return f.replacingOccurrences(of: "/", with: "-") }
        let ext: String
        switch mimeType {
        case "message/rfc822": ext = "eml"
        case "application/pdf": ext = "pdf"
        case "image/jpeg": ext = "jpg"
        case "image/png": ext = "png"
        case "text/calendar": ext = "ics"
        case "text/plain": ext = "txt"
        default: ext = subtype.isEmpty ? "bin" : subtype
        }
        return "attachment-\(partID).\(ext)"
    }

    func json() -> String? {
        guard let d = try? JSONEncoder().encode(self) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func fromJSON(_ s: String?) -> BodyPart? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BodyPart.self, from: d)
    }
}
