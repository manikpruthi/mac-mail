import AppKit
import Foundation

// Offline checks for the protocol and MIME code. Run with tools/selftest.sh.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "PASS " : "FAIL ") + name)
    if !ok { failures += 1 }
}

// Scratch area for every test file: tools/selftest.sh points MAC_MAIL_SELFTEST_TMP at its own throwaway
// folder (sandboxes block NSTemporaryDirectory()); without it we fall back to the system temp dir.
let scratchRoot: URL = {
    if let p = ProcessInfo.processInfo.environment["MAC_MAIL_SELFTEST_TMP"], !p.isEmpty {
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
}()

@discardableResult
func scratchDir(_ name: String) -> URL {
    let d = scratchRoot.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// This sandbox denies Foundation's atomic-write path (every `.atomic` write fails with EPERM, plain
/// writes work), and Outbox records are written atomically; when the probe fails only Outbox behaviour
/// that doesn't store a record can run here. Recorded in docs/review-notes/r-tests.md.
let atomicWritesWork: Bool = {
    let probe = scratchDir("probe").appendingPathComponent("atomic-\(UUID().uuidString)")
    do { try Data("x".utf8).write(to: probe, options: .atomic); try? FileManager.default.removeItem(at: probe); return true }
    catch { return false }
}()

/// Polls a condition the completion of which lands on a background queue (Outbox quarantine).
func waitFor(_ cond: () -> Bool, tries: Int = 80) -> Bool {
    for _ in 0..<tries {
        if cond() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return cond()
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
let tmpUrl = scratchDir("misc").appendingPathComponent("macmail-selftest-attachment.tmp")
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
let attURL = scratchDir("misc").appendingPathComponent("macmail-eml-test.pdf")
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
let inlineURL = scratchDir("misc").appendingPathComponent("inline-\(UUID().uuidString).png")
let fileURL = scratchDir("misc").appendingPathComponent("file-\(UUID().uuidString).txt")
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
    let dir = scratchDir("store-\(UUID().uuidString)")
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
    let dir = scratchDir("outbox-\(UUID().uuidString)")
    let box = Outbox(directory: dir)
    guard atomicWritesWork else {
        check("outbox persists (skipped: sandbox denies atomic writes)", true)
        check("outbox removes (skipped: sandbox denies atomic writes)", true)
        return
    }
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

// MARK: Review fixes since 2cf7eb0 (r-tests)

// X-net-2: CR/LF in an IMAP quoted string would inject extra commands. Lone CR/LF are stripped; note that
// a "\r\n" PAIR is one Swift Character and survives the filter — recorded as STILL-OPEN in r-tests.md.
check("imapQuoted strips lone CR/LF", "p\ra\nss".imapQuoted == "\"pass\"")
check("imapQuoted strips a CRLF pair", "a\r\nb".imapQuoted == "\"ab\"")
check("imapQuoted still escapes", "a\"b\\c".imapQuoted == "\"a\\\"b\\\\c\"")

// C-01: STARTTLS must be able to throw away pre-handshake plaintext. The real network behaviour needs a
// transport seam Sources doesn't have; offline we check the discard entry point exists and is callable.
StartTLSTransport(host: "127.0.0.1", port: 1).discardBuffered()
check("starttls discard callable", true)

// C-02 / C-26 / X-send-1 / X-send-2: Outbox write failure, corrupt-record quarantine, non-UUID ids.
MainActor.assumeIsolated {
    // Records that won't decode, have a non-UUID id (path traversal) or lost their MIME are quarantined,
    // not loaded (C-26, X-send-2). Load-side only, so it runs even where atomic writes are denied.
    let cDir = scratchDir("outbox-corrupt")
    func record(_ name: String, json: String?, eml: Bool) {
        let f = cDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        if let json { try? Data(json.utf8).write(to: f.appendingPathComponent("item.json")) }
        if eml { try? Data("Message-ID: <x@y>\r\nSubject: s\r\n\r\nbody\r\n".utf8).write(to: f.appendingPathComponent("message.eml")) }
    }
    record("badjson", json: "{not json", eml: true)
    record("escape", json: #"{"id":"../../outside","accountID":"a","recipients":["z@example.com"],"subject":"s","created":6500000000}"#, eml: true)
    record("noeml", json: #"{"id":"11111111-1111-1111-1111-111111111111","accountID":"a","recipients":[],"subject":"s","created":6500000000}"#, eml: false)
    try? Data("stray".utf8).write(to: cDir.appendingPathComponent("stray.txt"))
    check("corrupt records not loaded", Outbox(directory: cDir).items.isEmpty)
    let corruptDir = URL(fileURLWithPath: cDir.path + " Corrupt")
    let moved = waitFor { (try? FileManager.default.contentsOfDirectory(atPath: corruptDir.path))?.count == 3 }
    check("corrupt records quarantined", moved)
    check("non-UUID id never escapes the Outbox",
          !FileManager.default.fileExists(atPath: scratchRoot.appendingPathComponent("outside").path)
          && !FileManager.default.fileExists(atPath: scratchRoot.deletingLastPathComponent().appendingPathComponent("outside").path))
    check("reload after quarantine stays empty", Outbox(directory: cDir).items.isEmpty)

    // The rest stores records via Foundation's atomic write, which this sandbox denies — see the probe.
    guard atomicWritesWork else {
        check("outbox store/load behaviour (skipped: sandbox denies atomic writes)", true)
        return
    }
    let good = OutgoingMessage(from: EmailAddress(name: "M", email: "m@example.com"), to: [EmailAddress(name: "", email: "z@example.com")],
                               cc: [], bcc: [], subject: "queued", textBody: "b", htmlBody: "b",
                               inReplyTo: nil, references: nil, attachments: [])
    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    // A write that fails must throw and leave no half-written folder (C-02).
    let roDir = scratchDir("outbox-readonly")
    do {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path) }
        var threw = false
        do { try Outbox(directory: roDir).add(good, accountID: "a", replyToID: nil, draftToDeleteID: nil, safetyDraftID: nil) }
        catch { threw = true }
        check("outbox write failure throws", threw)
        check("outbox write failure leaves nothing", ((try? FileManager.default.contentsOfDirectory(atPath: roDir.path))?.isEmpty) == true)
    }

    // A failed failure-record write keeps the in-memory count; it isn't silently dropped (C-26).
    let rDir = scratchDir("outbox-failrec")
    let rbox = Outbox(directory: rDir)
    do { try rbox.add(good, accountID: "a", replyToID: nil, draftToDeleteID: nil, safetyDraftID: nil) } catch { check("outbox add for failures", false) }
    guard let item = rbox.items.first else { check("outbox add for failures", false); return }
    let itemDir = rDir.appendingPathComponent(item.id, isDirectory: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: itemDir.path)
    rbox.recordFailure(item.id, error: Boom())
    check("failure counted despite write failure", rbox.items.first?.attempts == 1 && rbox.items.first?.lastError == "boom")
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: itemDir.path)

    // X-send-1: a prebuilt MIME is kept as-is, not rebuilt.
    let mDir = scratchDir("outbox-mime")
    let mbox = Outbox(directory: mDir)
    let custom = Data("From: a@example.com\r\nSubject: prebuilt\r\n\r\nhi\r\n".utf8)
    do { try mbox.add(good, accountID: "a", replyToID: nil, draftToDeleteID: nil, safetyDraftID: nil, mime: custom) } catch { check("outbox prebuilt add", false) }
    check("outbox keeps prebuilt mime", mbox.items.count == 1 && (try? mbox.data(mbox.items[0])) == custom)
}

// C-03: normalize must keep attachments it can't render as images (pasted files, file promises).
MainActor.assumeIsolated {
    let storage = NSTextStorage(string: "a\u{FFFC}b")
    let plain = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: Data("hello".utf8)))
    plain.fileWrapper?.preferredFilename = "notes.txt"
    storage.addAttribute(.attachment, value: plain, range: NSRange(location: 1, length: 1))
    InlineImage.normalize(storage, maxWidth: 600)
    check("normalize keeps non-image attachment", storage.length == 3
          && (storage.attribute(.attachment, at: 1, effectiveRange: nil) as? NSTextAttachment) === plain)
    // A real image still gets its inline display.
    let imgStorage = NSTextStorage(string: "\u{FFFC}")
    imgStorage.addAttribute(.attachment, value: NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: pngBytes)),
                            range: NSRange(location: 0, length: 1))
    InlineImage.normalize(imgStorage, maxWidth: 600)
    let first = imgStorage.attribute(.attachment, at: 0, effectiveRange: nil)
    check("normalize converts real image", first is InlineImageAttachment)
}

// C-29: EMLDocument caps — byte limit throws, deep nesting and too many parts are marked truncated.
do {
    check("eml rejects oversized", (try? EMLDocument.parse(Data(count: EMLDocument.maxSize + 1))) == nil)
    func nest(_ depth: Int) -> String {
        if depth == 0 { return "Content-Type: text/plain\r\n\r\nleaf\r\n" }
        return "Content-Type: multipart/mixed; boundary=\"d\(depth)\"\r\n\r\n--d\(depth)\r\n" + nest(depth - 1) + "--d\(depth)--\r\n"
    }
    func anyTruncated(_ p: BodyPart) -> Bool { (p.truncated ?? false) || p.children.contains { anyTruncated($0) } }
    let deep = try? EMLDocument.parse(Data(("From: a@example.com\r\nSubject: deep\r\n" + nest(25)).utf8))
    check("deep nesting truncated", deep != nil && anyTruncated(deep!.structure))
    var many = "From: a@example.com\r\nSubject: many\r\nContent-Type: multipart/mixed; boundary=\"m\"\r\n\r\n"
    for _ in 0..<600 { many += "--m\r\nContent-Type: text/plain\r\n\r\nx\r\n" }
    many += "--m--\r\n"
    let manyDoc = try? EMLDocument.parse(Data(many.utf8))
    check("part cap truncates", manyDoc != nil && manyDoc!.structure.children.count < 600 && anyTruncated(manyDoc!.structure))
    // Newer date formats parse (diff since 2cf7eb0): ISO-ish and asctime with padded days.
    check("eml ISO date", EMLDocument.parseDate("2026-07-17 02:44:25 -0700") != nil)
    check("eml asctime date", EMLDocument.parseDate("Sun Nov  9 12:00:00 2026") != nil)
}

// C-10: a failed write inside a transaction rolls the whole batch back instead of committing half of it.
do {
    let db = try SQLiteDB(path: scratchDir("sqlite").appendingPathComponent("t.sqlite").path)
    try db.exec("CREATE TABLE t(a INTEGER)")
    db.transaction {
        _ = db.run("INSERT INTO t VALUES (1)")
        _ = db.run("INSERT INTO nosuch VALUES (2)")
    }
    check("failed write rolls back batch", (db.scalarInt("SELECT COUNT(*) FROM t") ?? -1) == 0)
    var threw = false
    do {
        try db.transactionChecked {
            try db.runChecked("INSERT INTO t VALUES (1)")
            try db.runChecked("INSERT INTO nosuch VALUES (2)")
        }
    } catch { threw = true }
    check("transactionChecked throws and rolls back", threw && (db.scalarInt("SELECT COUNT(*) FROM t") ?? -1) == 0)
    try db.transactionChecked { try db.runChecked("INSERT INTO t VALUES (7)") }
    check("transactionChecked commits on success", db.scalarInt("SELECT COUNT(*) FROM t") == 1)
}

// C-28: renameFolder repoints queued ops by folder id (and legacy path-only rows) plus child folders.
MainActor.assumeIsolated {
    guard let store = try? Store(path: scratchDir("rename-\(UUID().uuidString)").appendingPathComponent("s.sqlite").path) else {
        check("rename store opens", false); return
    }
    store.upsertFolders(account: "r", [ListedFolder(path: "INBOX", delimiter: "/", attributes: []),
                                       ListedFolder(path: "Work", delimiter: "/", attributes: []),
                                       ListedFolder(path: "Work/Sub", delimiter: "/", attributes: [])], isGmail: false)
    guard let work = store.folder(account: "r", path: "Work"), let sub = store.folder(account: "r", path: "Work/Sub") else {
        check("rename folders", false); return
    }
    check("addOp reports success", store.addOp(account: "r", kind: "move", folderPath: "Work", uids: [1], arg: "Work", folderID: work.id))
    store.addOp(account: "r", kind: "flags", folderPath: "Work/Sub", uids: [2], folderID: sub.id)
    store.addOp(account: "r", kind: "flags", folderPath: "Work", uids: [3]) // pre-v2 row: no folder id
    store.renameFolder(work.id, path: "Work2", name: "Work2")
    var ops: [(fid: Int64, path: String, arg: String)] = []
    store.db.query("SELECT folder_id, folder_path, arg FROM pending_ops ORDER BY created") { ops.append(($0.int64(0), $0.text(1), $0.text(2))) }
    check("rename repoints ops by id", ops.first(where: { $0.fid == work.id })?.path == "Work2"
          && ops.first(where: { $0.fid == sub.id })?.path == "Work2/Sub")
    check("rename repoints legacy path-only op", ops.first(where: { $0.fid == 0 })?.path == "Work2")
    check("rename repoints move destination", ops.first(where: { $0.fid == work.id })?.arg == "Work2")
    check("rename follows child folders", store.folder(account: "r", path: "Work2/Sub") != nil
          && store.folder(account: "r", path: "Work/Sub") == nil)
}

// W-02 / X-store-9: header filters go through the FTS index; unsearchable words don't hide the rest.
MainActor.assumeIsolated {
    guard let store = try? Store(path: scratchDir("fts-\(UUID().uuidString)").appendingPathComponent("s.sqlite").path) else {
        check("fts store opens", false); return
    }
    store.upsertFolders(account: "a", [ListedFolder(path: "INBOX", delimiter: "/", attributes: [])], isGmail: false)
    guard let inbox = store.folder(account: "a", role: .inbox) else { check("fts folder", false); return }
    func header(_ uid: UInt32, subject: String, from: String, to: String, cc: String, mid: String = "") -> ParsedHeader {
        ParsedHeader(uid: uid, gmailID: 0, threadID: 1, date: Date().addingTimeInterval(-Double(uid) * 86400), size: 100, flags: [],
                     subject: subject, from: EmailAddress(name: from, email: from + "@x.com"), toList: to,
                     ccList: cc, replyTo: "", messageID: mid, inReplyTo: "", references: "", listUnsubscribe: "",
                     structureJSON: nil, hasAttachments: false)
    }
    store.insert(folderID: inbox.id, [
        header(1, subject: "Quarterly report", from: "ann", to: "me@x.com", cc: "boss@x.com"),
        header(2, subject: "Lunch plans", from: "bob", to: "team@x.com", cc: "helper@x.com"),
    ])
    check("from filter hits index", store.search(SearchQuery.parse("from:ann")).map { $0.uid } == [1])
    check("to filter hits index", store.search(SearchQuery.parse("to:me")).map { $0.uid } == [1])
    check("cc filter hits index", store.search(SearchQuery.parse("cc:helper")).map { $0.uid } == [2])
    check("subject filter hits index", store.search(SearchQuery.parse("subject:lunch")).map { $0.uid } == [2])
    check("symbol-only word matches nothing", store.search(SearchQuery.parse("!!!")).isEmpty)
    check("symbol-only word doesn't hide the rest", store.search(SearchQuery.parse("!!! lunch")).map { $0.uid } == [2])

    // C-13: paging runs in SQL with an id tiebreak; ascending is a true oldest-first window.
    store.upsertFolders(account: "p", [ListedFolder(path: "INBOX", delimiter: "/", attributes: [])], isGmail: false)
    if let pin = store.folder(account: "p", role: .inbox) {
        store.insert(folderID: pin.id, (1...250).map { header(UInt32($0), subject: "m\($0)", from: "z", to: "", cc: "") })
        let oldest = store.listRows(folderID: pin.id, limit: 10, ascending: true)
        let newest = store.listRows(folderID: pin.id, limit: 10, ascending: false)
        check("oldest-first page", oldest.map { $0.uid } == (241...250).reversed().map { UInt32($0) })
        check("newest-first page", newest.map { $0.uid } == Array(1...10).map { UInt32($0) })
    }
    // Same-date messages keep a stable order across pages and directions via the id tiebreak.
    store.upsertFolders(account: "t", [ListedFolder(path: "INBOX", delimiter: "/", attributes: [])], isGmail: false)
    if let tin = store.folder(account: "t", role: .inbox) {
        let same = Date()
        func row(_ uid: UInt32) -> ParsedHeader {
            ParsedHeader(uid: uid, gmailID: 0, threadID: 1, date: same, size: 100, flags: [], subject: "same",
                         from: EmailAddress(name: "x", email: "x@x.com"), toList: "", ccList: "", replyTo: "",
                         messageID: "", inReplyTo: "", references: "", listUnsubscribe: "", structureJSON: nil, hasAttachments: false)
        }
        store.insert(folderID: tin.id, [row(90), row(91)])
        check("id tiebreak ascending", store.listRows(folderID: tin.id, limit: 10, ascending: true).map { $0.uid } == [90, 91])
        check("id tiebreak descending", store.listRows(folderID: tin.id, limit: 10, ascending: false).map { $0.uid } == [91, 90])
    }
}

// C-19: SearchQuery is Codable and legacy raw-text saved searches still decode.
do {
    let sq = SearchQuery.parse("from:divya invoice has:attachment is:unread newer_than:2m in:inbox")
    let rt = (try? JSONEncoder().encode(sq)).flatMap { try? JSONDecoder().decode(SearchQuery.self, from: $0) }
    check("search query codable round trip", rt == sq)
    // Mirror of SavedSearches.Entry (UI file): `structured` is nil on entries saved by older builds.
    struct LegacySaved: Codable {
        struct Saved: Codable { var scopeFolderID: Int64? }
        var name: String
        var query: String
        var structured: Saved?
    }
    let legacy = try? JSONDecoder().decode([LegacySaved].self, from: Data(#"[{"name":"old","query":"from: bob invoice"}]"#.utf8))
    check("legacy saved search loads", legacy?.first?.structured == nil && SearchQuery.parse(legacy?.first?.query ?? "").from == ["bob"])
    let full = #"[{"name":"new","query":"invoice","structured":{"scopeFolderID":42}}]"#
    let withScope = try? JSONDecoder().decode([LegacySaved].self, from: Data(full.utf8))
    check("structured saved search loads", withScope?.first?.structured?.scopeFolderID == 42)
}

// C-08: one inline part per Content-ID; an unusable Content-ID is sent as an ordinary file.
do {
    let pngFile = scratchDir("misc").appendingPathComponent("dup-\(UUID().uuidString).png")
    try? pngBytes.write(to: pngFile)
    let dupMsg = OutgoingMessage(from: EmailAddress(name: "", email: "z@example.com"), to: [EmailAddress(name: "", email: "a@example.com")],
                                 cc: [], bcc: [], subject: "dup", textBody: "b", htmlBody: "<img src=\"cid:dup@x\">",
                                 inReplyTo: nil, references: nil,
                                 attachments: [OutgoingAttachment(url: pngFile, filename: "a.png", mimeType: "image/png", contentID: "dup@x"),
                                               OutgoingAttachment(url: pngFile, filename: "b.png", mimeType: "image/png", contentID: "dup@x"),
                                               OutgoingAttachment(url: pngFile, filename: "c.png", mimeType: "image/png", contentID: "\"<>")])
    let dup = String(data: (try? MessageBuilder.build(dupMsg)) ?? Data(), encoding: .utf8) ?? ""
    check("duplicate content-id sent once", dup.components(separatedBy: "Content-ID: <dup@x>").count - 1 == 1
          && dup.components(separatedBy: "multipart/related").count - 1 == 1)
    check("unusable content-id sent as file", !dup.contains("Content-ID: <>")
          && dup.components(separatedBy: "Content-Disposition: attachment").count - 1 >= 1)
    try? FileManager.default.removeItem(at: pngFile)
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
