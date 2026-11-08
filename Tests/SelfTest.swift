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
check("plain from html", MIME.plainText(fromHTML: "<style>p{}</style><p>Hello&nbsp;<b>world</b> &amp; co</p>") == "Hello world & co")
check("literal length", IMAPParser.literalLength(Array("BODY[] {42}".utf8)) == 42 && IMAPParser.literalLength(Array("x {7+}".utf8)) == 7)

// Builder
let msg = OutgoingMessage(from: EmailAddress(name: "Manik", email: "m@example.com"), to: [EmailAddress(name: "Zoë", email: "z@example.com")],
                          cc: [], bcc: [], subject: "Hello ✓", textBody: "hi\n.dot", htmlBody: "<p>hi</p>", inReplyTo: nil, references: nil, attachments: [])
let built = String(data: (try? MessageBuilder.build(msg)) ?? Data(), encoding: .utf8) ?? ""
check("builder headers", built.contains("Subject: =?UTF-8?B?") && built.contains("To: =?UTF-8?B?") && built.contains("multipart/alternative"))
check("dot stuffing", String(data: SMTPClient.dotStuffed(Data("a\r\n.b\r\n".utf8)), encoding: .utf8) == "a\r\n..b\r\n")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
