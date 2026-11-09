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
check("recipients written safely", built2.contains("To:"))
check("in-reply-to sanitized", built2.contains("In-Reply-To: <a@x>"))
check("references sanitized", built2.contains("References: <ok@x>"))

// Comma-laden display names round-trip to ONE address (V2-02)
let rt = EmailAddress(name: "Doe, Jane", email: "jane@x.com")
let parsed = MIME.parseAddresses(rt.full)
check("full round-trips one address", parsed.count == 1 && parsed.first?.email == "jane@x.com" && parsed.first?.name == "Doe, Jane")

// Attachment filename cannot inject headers (SEC-03)
let tmpUrl = URL(fileURLWithPath: ".selftest-attachment.tmp") // TMPDIR writes are restricted here
try? Data("x".utf8).write(to: tmpUrl)
defer { try? FileManager.default.removeItem(at: tmpUrl) }
let evilAtt = OutgoingAttachment(url: tmpUrl, filename: "a\"\r\nBcc: hack@x.com;d.txt", mimeType: "text/plain")
let attMsg = OutgoingMessage(from: EmailAddress(name: "M", email: "m@example.com"), to: [EmailAddress(name: "", email: "z@example.com")],
                             cc: [], bcc: [], subject: "s", textBody: "b", htmlBody: "b",
                             inReplyTo: nil, references: nil, attachments: [evilAtt])
let built3 = String(data: (try? MessageBuilder.build(attMsg)) ?? Data(), encoding: .utf8) ?? ""
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
check("deep bodystructure survives", deepParsed == nil || deepParsed != nil) // must not SIGSEGV

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

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
