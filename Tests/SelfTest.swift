import AppKit
import Foundation

// Offline checks for the protocol and MIME code. Run with tools/selftest.sh.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func parts(_ lines: [String], literals: [String] = []) -> [ResponsePart] {
    var out: [ResponsePart] = []
    var lit = literals.makeIterator()
    for l in lines {
        out.append(.text(Array(l.utf8)))
        if IMAPParser.literalLength(Array(l.utf8)) != nil, let d = lit.next() { out.append(.literal(Data(d.utf8))) }
    }
    return out
}

// Status response with code
let ok = IMAPParser.parse(parts(["* OK [UIDVALIDITY 3857529045] UIDs valid"]))
check("status code parsed", ok.status == "OK" && ok.code == "UIDVALIDITY 3857529045")

// FETCH with literal header + Gmail extensions + bodystructure
let header = "From: =?UTF-8?B?Sm9zw6k=?= <jose@example.com>\r\nSubject: =?utf-8?Q?Caf=C3=A9_menu?=\r\n\r\n"
let fetchLine1 = "* 12 FETCH (UID 4521 FLAGS (\\Seen \\Flagged) X-GM-THRID 1278455344230334865 INTERNALDATE \"17-Jul-2026 02:44:25 -0700\" RFC822.SIZE 4286 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 120 4 NIL NIL NIL)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"BASE64\" 900 12 NIL NIL NIL) \"ALTERNATIVE\" (\"BOUNDARY\" \"x\") NIL NIL) BODY[HEADER.FIELDS (FROM SUBJECT)] {\(header.utf8.count)}"
let fetch = IMAPParser.parse(parts([fetchLine1, ")"], literals: [header]))
let fr = FetchResult.from(fetch)
check("fetch parsed", fr?.uid == 4521)
let ph = fr.flatMap { IMAPClient.parseHeader($0, gmail: true) }
check("encoded-word from", ph?.from.name == "José" && ph?.from.email == "jose@example.com")
check("encoded-word subject", ph?.subject == "Café menu")
check("flags", ph?.flags.contains(.seen) == true && ph?.flags.contains(.flagged) == true)
check("gmail thread id", ph?.threadID == 1278455344230334865)
let bs = BodyPart.fromJSON(ph?.structureJSON)
let dp = bs?.displayParts()
check("alternative parts", dp?.html?.partID == "2" && dp?.text?.partID == "1" && bs?.hasAttachments == false)

// Mixed with attachment
let mixedLine = "* 1 FETCH (UID 7 BODYSTRUCTURE (((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 10 1 NIL NIL NIL)(\"TEXT\" \"HTML\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 20 1 NIL NIL NIL) \"ALTERNATIVE\" NIL NIL NIL)(\"IMAGE\" \"PNG\" (\"NAME\" \"logo.png\") \"<logo@x>\" NIL \"BASE64\" 4000 NIL (\"INLINE\" NIL) NIL NIL)(\"APPLICATION\" \"PDF\" (\"NAME\" \"Invoice.pdf\") NIL NIL \"BASE64\" 40000 NIL (\"ATTACHMENT\" (\"FILENAME*\" \"UTF-8''Rechnung%20M%C3%A4rz.pdf\")) NIL NIL) \"MIXED\" (\"BOUNDARY\" \"y\") NIL NIL))"
let mixed = FetchResult.from(IMAPParser.parse(parts([mixedLine])))
let ms = mixed?.items["BODYSTRUCTURE"].flatMap { BodyPart.parse($0) }
let atts = ms?.attachments() ?? []
check("nested part ids", ms?.displayParts().html?.partID == "1.2")
check("inline image hidden", atts.count == 1 && atts.first?.partID == "3")
check("rfc2231 filename", atts.first?.filename == "Rechnung März.pdf")
check("cid lookup", ms?.part(withContentID: "<logo@x>")?.partID == "2")

// Search, LIST, mailbox names
// STATUS UNSEEN (server unread counts): quoted, atom and modified-UTF-7 names, several items
check("STATUS unseen quoted", IMAPClient.unseen(from: [IMAPParser.parse(parts(["* STATUS \"INBOX\" (UNSEEN 2472)"]))]) == 2472)
check("STATUS unseen with other items", IMAPClient.unseen(from: [IMAPParser.parse(parts(["* STATUS Drafts (MESSAGES 9 UNSEEN 0)"]))]) == 0)
check("STATUS unseen absent", IMAPClient.unseen(from: [IMAPParser.parse(parts(["* STATUS \"[Gmail]/Spam\" (MESSAGES 3)"]))]) == nil)
let search = IMAPParser.parse(parts(["* SEARCH 2 84 882"]))
check("search values", search.values.compactMap { $0.number } == [2, 84, 882])
let list = IMAPParser.parse(parts(["* LIST (\\HasNoChildren \\Sent) \"/\" \"[Gmail]/Sent Mail\""]))
check("list parse", list.values.count == 4 && list.values[3].text == "[Gmail]/Sent Mail")
check("mutf7 roundtrip", MailboxName.decode(MailboxName.encode("Rechnungen/März & Co")) == "Rechnungen/März & Co")
check("mutf7 known", MailboxName.encode("台北") == "&U,BTFw-")
check("uid set", imapUIDSet([1, 2, 3, 7, 9, 10]) == "1:3,7,9:10")

// Encodings
check("qp decode", String(data: MIME.decodeQuotedPrintable(Data("Caf=C3=A9 =\r\nau lait".utf8)), encoding: .utf8) == "Café au lait")
var sb = StreamingBase64Decoder()
let original = Data((0..<5000).map { UInt8($0 % 251) })
let encoded = Data(original.base64EncodedString(options: .lineLength76Characters).utf8)
var decoded = Data()
for chunk in stride(from: 0, to: encoded.count, by: 777) { decoded.append(sb.feed(encoded[chunk..<min(chunk + 777, encoded.count)])) }
decoded.append(sb.finish())
check("streaming base64", decoded == original)
check("addresses", MIME.parseAddresses("\"Doe, Jane\" <jane@x.com>, bob@y.com").map { $0.email } == ["jane@x.com", "bob@y.com"])
check("mailto address cleaned", MIME.parseAddresses("<mailto:customer.service@hdfc.bank.in.>, Bank <MAILTO:a@b.com?subject=x>").map { $0.email } == ["customer.service@hdfc.bank.in", "a@b.com"])
check("plain from html", MIME.plainText(fromHTML: "<style>p{}</style><p>Hello&nbsp;<b>world</b> &amp; co</p>") == "Hello world & co")
check("literal length", IMAPParser.literalLength(Array("BODY[] {42}".utf8)) == 42 && IMAPParser.literalLength(Array("x {7+}".utf8)) == 7)

// Builder
let msg = OutgoingMessage(from: EmailAddress(name: "Manik", email: "m@example.com"), to: [EmailAddress(name: "Zoë", email: "z@example.com")],
                          cc: [], bcc: [], subject: "Hello ✓", textBody: "hi\n.dot", htmlBody: "<p>hi</p>", inReplyTo: nil, references: nil, attachments: [])
let built = String(data: (try? MessageBuilder.build(msg)) ?? Data(), encoding: .utf8) ?? ""
check("builder headers", built.contains("Subject: =?UTF-8?B?") && built.contains("To: =?UTF-8?B?") && built.contains("multipart/alternative"))
check("dot stuffing", String(data: SMTPClient.dotStuffed(Data("a\r\n.b\r\n".utf8)), encoding: .utf8) == "a\r\n..b\r\n")

// Search parsing
let sq1 = SearchQuery.parse("from: divya")
check("from with space", sq1.from == ["divya"] && sq1.words.isEmpty)
let sq2 = SearchQuery.parse("from:divya invoice has:attachment is:unread newer_than:2m")
check("operators", sq2.from == ["divya"] && sq2.words == ["invoice"] && sq2.hasAttachment && sq2.unread && sq2.withinDays == 60)
let sq3 = SearchQuery.parse("subject:\"q4 budget\" in:inbox")
check("quoted + server-only", sq3.subject == ["q4 budget"] && sq3.serverOnly == ["in:inbox"])
check("gmail raw", sq2.gmailRaw == "invoice from:divya has:attachment is:unread newer_than:60d")
check("imap criteria", SearchQuery.parse("from: bob is:starred").imapCriteria == "FROM \"bob\" FLAGGED")

// MARK: Security hardening

// Strict addr-spec validation
check("addr valid", MailSafety.isValidAddrSpec("jane@example.com"))
check("addr rejects CRLF", !MailSafety.isValidAddrSpec("a\r\nBcc: evil@x.com"))
check("addr rejects space/angle/quote/comma", !MailSafety.isValidAddrSpec("a b@x.com") && !MailSafety.isValidAddrSpec("<a@x.com>")
    && !MailSafety.isValidAddrSpec("\"a\"@x.com") && !MailSafety.isValidAddrSpec("a,b@x.com"))
check("addr rejects no-at/two-at", !MailSafety.isValidAddrSpec("nowhere") && !MailSafety.isValidAddrSpec("a@b@c"))
check("stripControls", MailSafety.stripControls("a\r\nB\u{7f}c") == "aBc")

// cleanEmail no longer percent-decodes, so %0D%0A stays inert and fails validation
let pctAddr = MIME.cleanEmail("%6Aane%40x.com%0D%0A")
check("cleanEmail keeps percent-encoding", pctAddr.contains("%") && !MailSafety.isValidAddrSpec(pctAddr))
check("smtp refuses injected envelope", (try? SMTPClient.validateAddresses(from: "m@example.com", recipients: ["a\r\nBcc: evil@x.com"])) == nil)
check("smtp accepts real envelope", (try? SMTPClient.validateAddresses(from: "m@example.com", recipients: ["a@example.com"])) != nil)

// Header injection through display names, In-Reply-To and References
let evil = EmailAddress(name: "Evil\r\nBcc: hacker@x.com", email: "evil@example.com")
let inj = EmailAddress(name: "Doe, Jane <jane@x.com>; bob@y.org", email: "jane@x.com")
let injMsg = OutgoingMessage(from: EmailAddress(name: "Manik", email: "m@example.com"), to: [evil, inj],
                             cc: [], bcc: [], subject: "hi", textBody: "b", htmlBody: "b",
                             inReplyTo: "<a@x>\r\nBcc: hacker@x.com", references: "<ok@x> <bad\r\nBcc: h@x>", attachments: [])
let built2 = String(data: (try? MessageBuilder.build(injMsg)) ?? Data(), encoding: .utf8) ?? ""
check("no injected Bcc header", !built2.contains("\r\nBcc:") && !built2.contains("\r\nReferences: hacker"))
// The To header must parse back into exactly the two intended addresses — no smuggled third (R-03).
let toHeader = MIME.parseHeaders(Data(built2.components(separatedBy: "\r\n\r\n")[0].utf8))["to"] ?? ""
check("recipients written safely", MIME.parseAddresses(toHeader).map { $0.email } == ["evil@example.com", "jane@x.com"])
check("in-reply-to sanitized", built2.contains("In-Reply-To: <a@x>"))
check("references sanitized", built2.contains("References: <ok@x>"))

// Comma-laden display names round-trip to ONE address (V2-02)
let rt = EmailAddress(name: "Doe, Jane", email: "jane@x.com")
let parsed = MIME.parseAddresses(rt.full)
check("full round-trips one address", parsed.count == 1 && parsed.first?.email == "jane@x.com" && parsed.first?.name == "Doe, Jane")

// Attachment filename cannot inject headers (SEC-03)
let tmpUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macmail-selftest-attachment.tmp")
try? Data("x".utf8).write(to: tmpUrl)
let evilAtt = OutgoingAttachment(url: tmpUrl, filename: "a\"\r\nBcc: hack@x.com;d.txt", mimeType: "text/plain")
let attMsg = OutgoingMessage(from: EmailAddress(name: "M", email: "m@example.com"), to: [EmailAddress(name: "", email: "z@example.com")],
                             cc: [], bcc: [], subject: "s", textBody: "b", htmlBody: "b",
                             inReplyTo: nil, references: nil, attachments: [evilAtt])
let built3 = String(data: (try? MessageBuilder.build(attMsg)) ?? Data(), encoding: .utf8) ?? ""
try? FileManager.default.removeItem(at: tmpUrl)
// Sender-supplied attachment names are safe for Save panels (SEC-A11)
check("filename sanitised", BodyPart.safeFilename("..\u{0A}evil:/x.pdf") == "-evil--x.pdf"
    && BodyPart.safeFilename("..") == nil && (BodyPart.safeFilename(String(repeating: "a", count: 500) + ".pdf")?.count ?? 0) == 200)
check("filename injection blocked", !built3.contains("\r\nBcc:") && built3.contains("filename*=UTF-8''")
    && built3.contains("filename=\"a_"))

// Header folding + encoded-word splitting (BUG-23)
let longSubject = String(repeating: "wörd ", count: 40)
let longMsg = OutgoingMessage(from: EmailAddress(name: "M", email: "m@example.com"), to: [EmailAddress(name: "", email: "z@example.com")],
                              cc: [], bcc: [], subject: longSubject, textBody: "b", htmlBody: "b",
                              inReplyTo: nil, references: nil, attachments: [])
let built4 = String(data: (try? MessageBuilder.build(longMsg)) ?? Data(), encoding: .utf8) ?? ""
let subjectLines = built4.components(separatedBy: "\r\n").filter { !$0.hasPrefix(" ") }
check("encoded words folded", built4.contains("=?UTF-8?B?") && subjectLines.contains { $0.hasPrefix("Subject: =?UTF-8?B?") })
let b64chunks = built4.components(separatedBy: "=?UTF-8?B?").dropFirst().map { String($0.prefix(while: { $0 != "?" })) }
check("encoded words short", !b64chunks.isEmpty && b64chunks.allSatisfy { $0.count <= 63 })

// DoS: 20-digit literal length must not trap (SEC-07)
check("huge literal clamped", IMAPParser.literalLength(Array("x {99999999999999999999}".utf8)) == IMAPParser.maxLiteralSize)
check("normal literal intact", IMAPParser.literalLength(Array("BODY[] {42}".utf8)) == 42)

// DoS: 20000 nested parens must not crash the parser or BodyStructure (V2-17)
let deep = "* 1 FETCH (UID 7 BODYSTRUCTURE " + String(repeating: "(", count: 20000) + String(repeating: ")", count: 20000) + ")"
let deepResp = IMAPParser.parse([.text(Array(deep.utf8))])
check("deep parens survive", deepResp.values.count >= 1)
var deepVal = IMAPValue.atom("TEXT")
for _ in 0..<5000 { deepVal = .list([deepVal]) }
let deepParsed = BodyPart.parse(deepVal)
// Past the depth limit the parser gives up (nil) rather than recursing; a tree, if any, stays bounded (R-03).
func depth(_ p: BodyPart?) -> Int { guard let p else { return 0 }; return 1 + (p.children.map { depth($0) }.max() ?? 0) }
check("deep bodystructure bounded", deepParsed == nil || depth(deepParsed) <= 64)

// DoS: huge BODYSTRUCTURE / RFC822.SIZE values must not trap (V2-16)
let hugeBS = FetchResult.from(IMAPParser.parse(parts(["* 1 FETCH (UID 1 RFC822.SIZE 18446744073709551615 BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"BASE64\" 18446744073709551615 1 NIL NIL NIL)"])))
let hugePart = hugeBS.flatMap { $0.items["BODYSTRUCTURE"] }.flatMap { BodyPart.parse($0) }
check("huge size clamped", hugePart?.size == 1 << 30 && hugePart!.decodedSize > 0)

// Malformed base64 padding keeps the payload (V2-29)
check("base64 tolerates inner padding", String(data: MIME.decodeBase64(Data("QUJD=RUY=".utf8)), encoding: .utf8) == "ABCEF")

// Malformed modified UTF-7 is kept verbatim, not dropped (V2-28)
check("mutf7 malformed not dropped", MailboxName.decode("&!!!!-rest") != "rest" && MailboxName.decode("&!!!!-rest").contains("rest"))

// 'Re: budget' stays a local search (BUG-22)
let sqRe = SearchQuery.parse("Re: budget")
check("Re: budget local search", sqRe.words.contains("budget") && sqRe.serverOnly.isEmpty && sqRe.hasLocalCriteria)
let sqTime = SearchQuery.parse("\"time: 5pm\"")
check("quoted colon token", sqTime.serverOnly.isEmpty && !sqTime.words.isEmpty)

// days() overflow clamps instead of trapping (BUG-43)
check("huge newer_than clamps", SearchQuery.days("99999999999999999y") == Int.max && SearchQuery.days("9223372036854775807m") == Int.max)

// Non-representable criteria are reported, never widened to ALL (BUG-10)
check("attachment not imap-representable", !SearchQuery.parse("invoice has:attachment").isIMAPRepresentable)
check("serverOnly not imap-representable", !SearchQuery.parse("in:inbox").isIMAPRepresentable)
check("non-ascii not imap-representable", !SearchQuery.parse("café").isIMAPRepresentable)
check("plain ascii imap-representable", SearchQuery.parse("invoice").isIMAPRepresentable && SearchQuery.parse("invoice").imapCriteria != "ALL")

// MARK: Review fixes (MacMail-Review.xlsx)

// B-13: cc: is its own criterion.
let sqCc = SearchQuery.parse("cc:ann to:bob")
check("cc separate from to", sqCc.cc == ["ann"] && sqCc.to == ["bob"] && sqCc.gmailRaw.contains("cc:ann")
      && sqCc.imapCriteria.contains("CC \"ann\""))

// B-12: reference-based conversation keys.
let rootKey = MIME.threadKey(messageID: "<root@x>", inReplyTo: "", references: "", subject: "Plan", participants: ["a@x"])
let replyKey = MIME.threadKey(messageID: "<r1@x>", inReplyTo: "<root@x>", references: "<root@x>", subject: "Re: Plan", participants: ["b@x"])
let otherKey = MIME.threadKey(messageID: "<other@y>", inReplyTo: "", references: "", subject: "Plan", participants: ["c@y"])
check("thread by references", rootKey == replyKey && rootKey != otherKey)
check("thread fallback uses participants",
      MIME.threadKey(messageID: "", inReplyTo: "", references: "", subject: "Hi", participants: ["a@x"])
      != MIME.threadKey(messageID: "", inReplyTo: "", references: "", subject: "Hi", participants: ["b@x"]))

// B-09: the Message-ID the composer chose is the one written.
var midMsg = msg
midMsg.messageID = "fixed-123@example.com"
let builtMid = String(data: (try? MessageBuilder.build(midMsg)) ?? Data(), encoding: .utf8) ?? ""
check("message-id respected", builtMid.contains("Message-ID: <fixed-123@example.com>"))

// O-04: slice-wise base64 decodes back to the original and keeps 76-column lines.
let blob = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
var b64 = Data()
MessageBuilder.appendBase64(blob, to: &b64)
let b64Lines = String(decoding: b64, as: UTF8.self).components(separatedBy: "\r\n")
check("streamed base64 roundtrip", MIME.decodeBase64(b64) == blob && b64Lines.allSatisfy { $0.count <= 76 })

// B-34: the DATA deadline grows with the message.
check("smtp data deadline scales", SMTPClient.dataDeadline(bytes: 25 << 20) > SMTPClient.dataDeadline(bytes: 10_000))

// F-01 / F-03: accounts saved by older builds decode with sensible defaults.
let oldJSON = #"{"id":"a","email":"me@x.com","displayName":"Me","provider":"imap","username":"me@x.com","imapHost":"i","imapPort":143,"smtpHost":"s","smtpPort":587,"signature":""}"#
let oldAcct = try? JSONDecoder().decode(Account.self, from: Data(oldJSON.utf8))
check("legacy account decodes", oldAcct?.imapSecurity == .startTLS && oldAcct?.smtpSecurity == .startTLS && oldAcct?.smtpLogin == "me@x.com")
var changed = oldAcct!
changed.signature = "x"
check("signature edit keeps connections", !changed.connectionDiffers(from: oldAcct!))
changed.imapPort = 993
check("server edit resets connections", changed.connectionDiffers(from: oldAcct!))

// B-26 / B-27 / B-28: HTML handling.
check("bodyInner case-insensitive", HTMLPrep.bodyInner("<HTML><BODY class=x>İstanbul<b>ok</b></Body></html>") == "İstanbul<b>ok</b>")
let bigHTML = String(repeating: "é", count: 400_000) // 800 KB of 2-byte characters: the clip lands mid-character
let clipped = HTMLPrep.prepare(html: "<p>" + bigHTML + "</p>", text: nil)
check("clip at character boundary", clipped.clipped && !clipped.html.contains("\u{FFFD}"))
let quoted = HTMLPrep.quoteSanitized(#"<style>body{display:none}</style><p onclick="steal()">hi</p><a href="javascript:alert(1)">x</a><a href=" JaVaScRiPt:alert(1)">y</a><img src="http://t.example/a.png"><img src="https://ok.example/b.png"><img src="cid:logo"><script>x()</script>"#)
check("quote drops style/on*/js links", !quoted.lowercased().contains("<style") && !quoted.contains("onclick")
      && !quoted.lowercased().contains("javascript:") && !quoted.contains("<script"))
check("quote keeps only https images", quoted.contains("https://ok.example/b.png") && !quoted.contains("http://t.example")
      && !quoted.contains("cid:logo"))
let display = HTMLPrep.prepare(html: #"<p>a</p><script>alert(1)</script><iframe src="https://x"></iframe><img src="https://h/i.png" width="1" height="1"><img src="https://h/real.png">"#, text: nil)
check("display strips active content", !display.html.contains("<script") && !display.html.contains("<iframe")
      && display.trackersRemoved == 1 && display.remote.count == 1 && display.html.contains("Content-Security-Policy"))

// Save As / open .eml (F-17): what the builder writes, the reader reads back — text, HTML and attachments.
let attURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macmail-eml-test.pdf")
try? Data((0..<5000).map { UInt8($0 % 256) }).write(to: attURL)
let emlMsg = OutgoingMessage(from: EmailAddress(name: "Zoë", email: "z@example.com"), to: [EmailAddress(name: "M", email: "m@example.com")],
                             cc: [EmailAddress(name: "", email: "c@example.com")], bcc: [], subject: "Quarterly ✓",
                             textBody: "Plain body", htmlBody: "<p>HTML <b>body</b></p>", inReplyTo: nil, references: nil,
                             attachments: [OutgoingAttachment(url: attURL, filename: "Report März.pdf", mimeType: "application/pdf")])
let emlData = (try? MessageBuilder.build(emlMsg)) ?? Data()
try? FileManager.default.removeItem(at: attURL)
let eml = try? EMLDocument.parse(emlData)
let emlBodies = eml?.bodies()
let emlAtts = eml?.structure.attachments() ?? []
check("eml headers", eml?.subject == "Quarterly ✓" && eml?.from.email == "z@example.com" && eml?.cc.contains("c@example.com") == true)
check("eml bodies", emlBodies?.text == "Plain body" && emlBodies?.html?.contains("<b>body</b>") == true)
check("eml attachment", emlAtts.count == 1 && emlAtts.first?.filename == "Report März.pdf"
      && emlAtts.first.flatMap { eml?.data(for: $0) } == Data((0..<5000).map { UInt8($0 % 256) }))
check("eml rejects non-mail", (try? EMLDocument.parse(Data("just some text\nwithout headers".utf8))) == nil)
let lfOnly = "From: a@b.c\nSubject: LF\nContent-Type: multipart/alternative; boundary=\"zz\"\n\n--zz\nContent-Type: text/plain\n\nline1\n--zz\nContent-Type: text/html\n\n<i>x</i>\n--zz--\n"
let lfDoc = try? EMLDocument.parse(Data(lfOnly.utf8))
check("eml LF line endings", lfDoc?.bodies().text == "line1" && lfDoc?.bodies().html == "<i>x</i>")

// Inline images (pasted/dropped into the body): alternative { text, related { html, image } } + files in mixed.
let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
let inlineURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inline-\(UUID().uuidString).png")
let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("file-\(UUID().uuidString).txt")
try? pngBytes.write(to: inlineURL)
try? Data("hello".utf8).write(to: fileURL)
let inlineMsg = OutgoingMessage(from: EmailAddress(name: "", email: "z@example.com"), to: [EmailAddress(name: "", email: "a@example.com")],
                                cc: [], bcc: [], subject: "Pic", textBody: "See", htmlBody: "<p>See <img src=\"cid:pic1@macmail\"></p>",
                                inReplyTo: nil, references: nil,
                                attachments: [OutgoingAttachment(url: inlineURL, filename: "Pasted image.png", mimeType: "image/png", contentID: "pic1@macmail"),
                                              OutgoingAttachment(url: fileURL, filename: "notes.txt", mimeType: "text/plain")])
let inlineDoc = (try? MessageBuilder.build(inlineMsg)).flatMap { try? EMLDocument.parse($0) }
try? FileManager.default.removeItem(at: inlineURL)
try? FileManager.default.removeItem(at: fileURL)
let inlinePart = inlineDoc?.structure.part(withContentID: "pic1@macmail")
check("inline image is a cid part", inlinePart?.type == "image" && inlinePart.flatMap { inlineDoc?.data(for: $0) } == pngBytes)
check("inline image isn't an attachment chip", inlineDoc?.structure.attachments().map { $0.filename } == ["notes.txt"])
check("inline html still displays", inlineDoc?.bodies().html?.contains("cid:pic1@macmail") == true && inlineDoc?.bodies().text == "See")
check("related sits inside alternative", inlineDoc?.structure.subtype == "mixed"
      && inlineDoc?.structure.children.first?.subtype == "alternative"
      && inlineDoc?.structure.children.first?.children.last?.subtype == "related")
let (tok, tokCIDs) = InlineImage.tokenizeCIDImages(#"<p>a<img width="10" src="cid:x%40y">b<IMG SRC='cid:z@w'/>c<img src="https://e/i.png"></p>"#)
check("draft cid images tokenized", tokCIDs.map { $0.cid } == ["x@y", "z@w"] && tokCIDs.map { $0.width } == [10, nil] && tok.contains(InlineImage.token(0)) && tok.contains(InlineImage.token(1))
      && tok.contains("https://e/i.png"))
let tiffData = NSBitmapImageRep(data: NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in
    NSColor.red.setFill(); r.fill(); return true }.tiffRepresentation!)!.representation(using: .tiff, properties: [:])!
check("tiff converted for sending", InlineImage.sendableData(tiffData).map { ["public.jpeg", "public.png"].contains($0.1) } == true
      && InlineImage.sendableData(pngBytes)?.0 == pngBytes)

// Store: migrations, FTS/contacts upkeep, upserts, prune, undo snapshots, lookups (B-05/09/14/35/36/38, O-06, F-08).
MainActor.assumeIsolated {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macmail-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    guard let store = try? Store(path: dir.appendingPathComponent("t.sqlite").path) else { check("store opens", false); return }
    check("store at v5", store.db.userVersion == 5)
    store.upsertFolders(account: "acc", [ListedFolder(path: "INBOX", delimiter: "/", attributes: []),
                                        ListedFolder(path: "Drafts", delimiter: "/", attributes: ["\\Drafts"]),
                                        ListedFolder(path: "Old", delimiter: "/", attributes: [])], isGmail: false)
    guard let inbox = store.folder(account: "acc", role: .inbox), let drafts = store.folder(account: "acc", role: .drafts),
          let old = store.folder(account: "acc", path: "Old") else { check("folders", false); return }
    func header(_ uid: UInt32, _ subject: String, from: String, daysAgo: Double, mid: String = "") -> ParsedHeader {
        ParsedHeader(uid: uid, gmailID: 0, threadID: 1, date: Date().addingTimeInterval(-daysAgo * 86400), size: 100, flags: [],
                     subject: subject, from: EmailAddress(name: from, email: from + "@x.com"), toList: "me@x.com",
                     ccList: "boss@x.com", replyTo: "", messageID: mid, inReplyTo: "", references: "", listUnsubscribe: "",
                     structureJSON: nil, hasAttachments: false)
    }
    store.insert(folderID: inbox.id, [header(1, "Budget review", from: "ann", daysAgo: 1), header(2, "Lunch", from: "bob", daysAgo: 2)])
    store.insert(folderID: old.id, [header(1, "Old thing", from: "carl", daysAgo: 3)])
    store.insert(folderID: drafts.id, [header(7, "Same subject", from: "me", daysAgo: 0, mid: "<a@x.com>"),
                                       header(8, "Same subject", from: "me", daysAgo: 0, mid: "<b@x.com>")])
    // B-05: UIDs repeat across folders; the folder decides.
    let inboxUID1 = store.messageID(folderID: inbox.id, uid: 1)
    let oldUID1 = store.messageID(folderID: old.id, uid: 1)
    check("uid lookup per folder", inboxUID1 != nil && oldUID1 != nil && inboxUID1 != oldUID1)
    // B-09: drafts found by Message-ID, not subject.
    let b = store.messageID(folderID: drafts.id, messageIDHeader: "b@x.com")
    check("draft by message-id", b != nil && store.rows(ids: [b!]).first?.uid == 8)
    // B-35: a refetch updates header fields, not just flags.
    var fixed = header(2, "Lunch (moved to Friday)", from: "bob", daysAgo: 2)
    fixed.flags = [.seen]
    store.insert(folderID: inbox.id, [fixed])
    let lunch = store.rows(folderID: inbox.id).first { $0.uid == 2 }
    check("upsert refreshes headers", lunch?.subject == "Lunch (moved to Friday)" && lunch?.flags.contains(.seen) == true)
    check("fts follows header update", !store.search(SearchQuery.parse("friday")).isEmpty)
    // No-op syncs must not redraw: only UIDs whose flags really changed are reported.
    let firstPass = store.updateFlags(folderID: inbox.id, [(1, [.seen]), (2, [.seen])])
    let secondPass = store.updateFlags(folderID: inbox.id, [(1, [.seen]), (2, [.seen])])
    check("flag sync reports only real changes", firstPass == [1] && secondPass.isEmpty)
    store.updateFlags(folderID: inbox.id, [(1, [])])
    // B-13 locally: cc-only match.
    check("local cc search", store.search(SearchQuery.parse("cc:boss")).count == 5 && store.search(SearchQuery.parse("to:boss")).count == 5)
    // Body index + B-38 backfill path.
    if let id = inboxUID1 { store.saveBody(id, html: "<p>quarterly <b>forecast</b></p>", text: nil) }
    check("body search", store.search(SearchQuery.parse("forecast")).count == 1)
    // O-06: aggregate unread counts agree with the per-folder rule.
    let agg = store.unreadCounts()
    check("aggregate unread", agg[inbox.id] == store.unreadCount(folderID: inbox.id) && agg[inbox.id] == 1)
    // F-08: snapshot → delete → restore brings the row, its body and its index entries back.
    if let id = inboxUID1 {
        let snap = store.snapshot(ids: [id])
        store.deleteMessages(ids: [id])
        check("deleted before undo", store.rows(ids: [id]).isEmpty && store.search(SearchQuery.parse("forecast")).isEmpty)
        store.restore(snap)
        check("undo restores row+body+index", store.rows(ids: [id]).count == 1 && store.body(id) != nil
              && store.search(SearchQuery.parse("forecast")).count == 1 && store.search(SearchQuery.parse("budget")).count == 1)
    }
    // B-14: deleting an account leaves no FTS rows or contacts behind.
    store.deleteAccount("acc")
    let ftsLeft = store.db.scalarInt("SELECT COUNT(*) FROM fts") ?? -1
    let bodyLeft = store.db.scalarInt("SELECT COUNT(*) FROM body_fts") ?? -1
    let contactsLeft = store.db.scalarInt("SELECT COUNT(*) FROM contacts") ?? -1
    check("account delete cleans indexes", ftsLeft == 0 && bodyLeft == 0 && contactsLeft == 0)
    // B-36: the prune cutoff is exactly the offline window.
    let now = Date()
    check("prune cutoff exact", abs(Store.pruneCutoff(offlineDays: 30, now: now).timeIntervalSince(now) + 30 * 86400) < 1)
    // B-15/O-09: background prune removes old mail beyond the newest 200 per folder.
    store.upsertFolders(account: "p", [ListedFolder(path: "INBOX", delimiter: "/", attributes: [])], isGmail: false)
    if let pin = store.folder(account: "p", role: .inbox) {
        store.insert(folderID: pin.id, (1...250).map { header(UInt32($0), "m\($0)", from: "z", daysAgo: Double($0)) })
        let removed = Store.prune(path: store.path, offlineDays: 30)
        check("prune keeps newest 200", removed == 50 && store.messageCount(folderID: pin.id) == 200)
    }
}

// Outbox (F-07): messages persist with their MIME and come back after a relaunch.
MainActor.assumeIsolated {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macmail-outbox-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Outbox(directory: dir)
    do {
        try box.add(msg, accountID: "acc", replyToID: 5, draftToDeleteID: nil, safetyDraftID: nil)
        let again = Outbox(directory: dir)
        check("outbox persists", again.items.count == 1 && again.items.first?.recipients == ["z@example.com"]
              && ((try? again.data(again.items[0]))?.count ?? 0) > 100)
        again.remove(again.items[0].id)
        check("outbox removes", Outbox(directory: dir).items.isEmpty)
    } catch {
        check("outbox add", false)
    }
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
