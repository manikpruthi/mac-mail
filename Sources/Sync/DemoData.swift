import Foundation

/// Sample mailbox for screenshots and offline UI checks (MAC_MAIL_DEMO=1). Uses its own data folder.
@MainActor
enum DemoData {
    static let account = Account(id: "demo", email: "manik@example.com", displayName: "Manik Pruthi", provider: .demo,
                                 username: "manik@example.com", imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465,
                                 signature: "— Manik")

    static func seed(store: Store) {
        guard store.folder(account: account.id, role: .inbox) == nil else { return }
        let listed: [ListedFolder] = [
            ListedFolder(path: "INBOX", delimiter: "/", attributes: []),
            ListedFolder(path: "[Gmail]/Starred", delimiter: "/", attributes: ["\\Flagged"]),
            ListedFolder(path: "[Gmail]/Sent Mail", delimiter: "/", attributes: ["\\Sent"]),
            ListedFolder(path: "[Gmail]/Drafts", delimiter: "/", attributes: ["\\Drafts"]),
            ListedFolder(path: "[Gmail]/All Mail", delimiter: "/", attributes: ["\\All"]),
            ListedFolder(path: "[Gmail]/Spam", delimiter: "/", attributes: ["\\Junk"]),
            ListedFolder(path: "[Gmail]/Trash", delimiter: "/", attributes: ["\\Trash"]),
            ListedFolder(path: "Receipts", delimiter: "/", attributes: []),
            ListedFolder(path: "Travel", delimiter: "/", attributes: []),
        ]
        store.upsertFolders(account: account.id, listed, isGmail: true)
        guard let inbox = store.folder(account: account.id, role: .inbox) else { return }

        let now = Date()
        let attachments = BodyPart(partID: "TEXT", type: "multipart", subtype: "mixed", children: [
            BodyPart(partID: "1", type: "text", subtype: "html"),
            BodyPart(partID: "2", type: "application", subtype: "pdf", encoding: "base64", size: 412_000,
                     disposition: "attachment", dispositionParams: ["filename": "Q4 Budget.pdf"]),
            BodyPart(partID: "3", type: "application", subtype: "vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                     encoding: "base64", size: 96_000, disposition: "attachment", dispositionParams: ["filename": "Forecast.xlsx"]),
            BodyPart(partID: "4", type: "image", subtype: "jpeg", encoding: "base64", size: 1_800_000,
                     disposition: "attachment", dispositionParams: ["filename": "Offsite venue.jpg"]),
        ])
        let simple = BodyPart(partID: "1", type: "text", subtype: "html")

        struct Seed { var uid: UInt32; var thread: Int64; var minutesAgo: Double; var name: String; var email: String
                      var subject: String; var flags: MessageFlags; var att: Bool; var html: String }
        let seeds: [Seed] = [
            Seed(uid: 20, thread: 1, minutesAgo: 6, name: "Priya Nair", email: "priya@studio.example", subject: "Re: Q4 budget review",
                 flags: [], att: true, html: budgetHTML),
            Seed(uid: 19, thread: 2, minutesAgo: 34, name: "Northwind Weekly", email: "news@northwind.example",
                 subject: "This week: the alpine issue 🏔", flags: [], att: false, html: newsletterHTML),
            Seed(uid: 18, thread: 1, minutesAgo: 52, name: "Manik Pruthi", email: "manik@example.com", subject: "Re: Q4 budget review",
                 flags: [.seen], att: false, html: "<p>Looks good — can you add the offsite costs?</p><p>— Manik</p>"),
            Seed(uid: 17, thread: 3, minutesAgo: 95, name: "Alex Kim", email: "alex@acme.example", subject: "Design sync moved to Thursday",
                 flags: [.seen, .flagged], att: false, html: "<p>Hi all,</p><p>The design sync moves to <b>Thursday 3 pm</b>. Same room.</p><p>Alex</p>"),
            Seed(uid: 16, thread: 1, minutesAgo: 180, name: "Priya Nair", email: "priya@studio.example", subject: "Q4 budget review",
                 flags: [.seen], att: false, html: "<p>Hi Manik,</p><p>First pass at the Q4 budget is ready for review.</p>"),
            Seed(uid: 15, thread: 4, minutesAgo: 60 * 26, name: "Lisbon Air", email: "trips@lisbonair.example",
                 subject: "Your boarding pass · LIS → BER", flags: [.seen], att: false,
                 html: "<div style='font-family:-apple-system;padding:20px;background:#0b3d91;color:white;border-radius:12px'><h2>Boarding pass</h2><p>TP 538 · Seat 14A · Gate 22</p></div>"),
            Seed(uid: 14, thread: 5, minutesAgo: 60 * 30, name: "GitHub", email: "noreply@github.example",
                 subject: "[mac-explorer] Release v2.3 published", flags: [.seen], att: false, html: "<p>Release v2.3 is out.</p>"),
            Seed(uid: 13, thread: 6, minutesAgo: 60 * 50, name: "Sam Ortega", email: "sam@family.example", subject: "Photos from the weekend",
                 flags: [], att: false, html: "<p>Here are the photos! Call me later.</p>"),
            Seed(uid: 12, thread: 7, minutesAgo: 60 * 75, name: "Bank of Example", email: "alerts@bank.example",
                 subject: "Your statement is ready", flags: [.seen], att: false, html: "<p>Your monthly statement is available.</p>"),
        ]
        var headers: [ParsedHeader] = []
        for s in seeds {
            let structure = s.att ? attachments : simple
            headers.append(ParsedHeader(
                uid: s.uid, gmailID: Int64(s.uid), threadID: s.thread, date: now.addingTimeInterval(-s.minutesAgo * 60),
                size: s.att ? 2_400_000 : 20_000, flags: s.flags, subject: s.subject, from: EmailAddress(name: s.name, email: s.email),
                toList: "Manik Pruthi <manik@example.com>", ccList: "", replyTo: "", messageID: "<demo-\(s.uid)@example.com>",
                inReplyTo: "", references: "", listUnsubscribe: s.uid == 19 ? "<https://northwind.example/unsubscribe>" : "",
                structureJSON: structure.json(), hasAttachments: s.att))
        }
        store.insert(folderID: inbox.id, headers)
        for s in seeds {
            if let id = store.ids(folderID: inbox.id, uids: [s.uid]).first { store.saveBody(id, html: s.html, text: nil) }
        }
        store.updateFolderState(inbox.id, uidValidity: 1, uidNext: 21, modseq: 1)
    }

    static let budgetHTML = """
    <p>Hi Manik,</p>
    <p>Updated the budget with the offsite costs — the venue photo and the forecast sheet are attached.
    Headline: we're <b>4% under plan</b> for the quarter.</p>
    <table style="border-collapse:collapse;font-size:13px">
    <tr><td style="padding:4px 12px;border-bottom:1px solid #ddd">Team offsite</td><td style="padding:4px 12px;border-bottom:1px solid #ddd">€18,400</td></tr>
    <tr><td style="padding:4px 12px;border-bottom:1px solid #ddd">Contractors</td><td style="padding:4px 12px;border-bottom:1px solid #ddd">€42,000</td></tr>
    <tr><td style="padding:4px 12px"><b>Total</b></td><td style="padding:4px 12px"><b>€60,400</b></td></tr>
    </table>
    <p>Thanks,<br>Priya</p>
    """

    static let newsletterHTML = """
    <table width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f9"><tr><td align="center" style="padding:24px 12px">
    <table width="600" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;font-family:-apple-system,Helvetica,sans-serif">
    <tr><td style="background:linear-gradient(135deg,#1e3c72,#2a5298);padding:28px 32px;color:#fff">
          <div style="font-size:12px;letter-spacing:2px;opacity:.8">NORTHWIND WEEKLY · ISSUE 112</div>
          <div style="font-size:28px;font-weight:700;margin-top:6px">The alpine issue</div>
        </td></tr>
    <tr><td style="height:220px;background:linear-gradient(160deg,#3d6cb4,#79a7d9 60%,#c8d9ec)" align="center">
          <div style="font-size:64px;padding-top:70px">🏔</div></td></tr>
    <tr><td style="padding:24px 32px;color:#2b2f36;font-size:15px;line-height:1.55">
      <h3 style="margin:0 0 8px">Five trails worth the early start</h3>
      <p style="margin:0 0 16px">From high ridges to quiet lakes below, this week's picks reward an alarm clock.</p>
      <a href="https://example.com" style="display:inline-block;background:#2a5298;color:#fff;padding:10px 18px;border-radius:8px;text-decoration:none">Read the guide</a>
    </td></tr>
    <tr><td style="padding:0 32px 24px"><div style="height:160px;background:linear-gradient(180deg,#0b3d91,#3d6cb4);border-radius:10px" align="center"><div style="font-size:40px;padding-top:52px">⛰️</div></div></td></tr>
    <tr><td style="padding:16px 32px;background:#f7f8fb;color:#8a8f98;font-size:12px">You're receiving this because you subscribed. <img src="https://northwind.example/open.gif" width="1" height="1"></td></tr>
    </table></td></tr></table>
    """
}
