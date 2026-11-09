# Mac Mail

A small, fast, native macOS mail client for Gmail. It opens in under half a second from an offline cache and syncs only what changed. Measured with a real Gmail account (2,800 Inbox messages):
- **The app itself:** about 55 MB.
- **WebKit, while you read:** about 50 MB more (email renderer plus graphics helper).
- **When you switch away for a minute (or minimise):** WebKit is shut down, so it drops back to the app alone.

![Mac Mail main window](docs/screenshots/main-window.png)

Graphic emails look the way the sender designed them. Small images load automatically, and anything over the size limit shows a "Load image" box instead of using up memory. In dark mode, emails are recoloured to match the app, like Outlook; the ☀︎ button shows a message on its original light background.

![Image loading with the size limit](docs/screenshots/images-dark.png)

## Features

- **Fast start.** The Inbox shows straight from the local cache. Then a delta sync (new mail since the last UIDNEXT, flag changes since the last MODSEQ) brings it up to date, usually in a second or less.
- **Push for new mail.** IMAP IDLE delivers new mail to the Inbox the moment it arrives, but only while the app is open.
- **Nothing in the background.** No helper processes or login items. Closing the main window quits the app (unsaved messages are offered Save / Discard first).
- **Light on memory while you're elsewhere.** A minute after you switch to another app (or right away when you minimise or hide it), the reading pane's WebKit processes are shut down and freed memory is returned to macOS. Coming back re-renders the open message in about 0.1 s.
- **Offline window.** Headers for the last 30 days (adjustable from 7 to 90) plus at least the newest 200 messages per folder are kept offline. Message text for the newest messages is prefetched so they open instantly. "Load older messages" fetches older mail on demand.
- **Search:**
  - Local results as you type (SQLite FTS5 over headers, plus the text of every message whose body is cached).
  - Gmail's own server search runs as soon as you pause, and its results merge in. If it fails, the list header says why. On other IMAP servers, queries IMAP can't express (`has:attachment`, non-ASCII text) stay local-only.
  - Text like `Re: budget` is searched as words; only known operators are treated as operators.
  - **Search syntax** works locally too: `from:`, `to:`, `subject:`, `has:attachment`, `is:unread`, `is:starred`, `newer_than:7d`, quoted values (`from:"divya k"`), and a space after the colon (`from: divya`). Other Gmail operators (`in:`, `label:`, `older_than:`…) are passed to Gmail.
  - **Filter bar** (shown while searching), like Outlook:
    - Scope: All folders, or the folder you were in.
    - Date: past week, month, 6 months or year.
    - Toggles: Unread, Flagged, Attachments.
    - **More**: From, To and Subject fields.
- **Conversations on or off per folder.** Like Outlook, each folder can either group messages by conversation (threads expand in place) or show every message separately (⌥⌘C).
- **Preview pane**, with a three-pane layout: folders, list and message.
- **Open in a separate window**, like Outlook:
  - Double-click a message (or press Return) to open it in its own window.
  - The window has Reply, Reply All, Forward, Archive, Delete, Spam, Read/Unread and Flag, and the usual shortcuts work there.
  - The window closes when you archive or delete the message. Drafts open in the editor instead.
- **Theme.** The app follows macOS light/dark by default, switching live. You can also pin Light or Dark in Settings → General or View → Appearance.
- **Dark reading pane:**
  - The reading pane uses the app's background.
  - In dark mode, each email gets an Outlook-style pass: light backgrounds are darkened (keeping their hue) and dark text on dark backgrounds is lightened. Images, gradients and brand colours aren't touched.
  - **View → Show Message with Light Background** (⌥⌘L, or the ☀︎ button in the header) shows a message exactly as designed.
- **Unread mail is highlighted, Outlook-style:** a tinted row, an accent bar on the left edge, a bold sender, and an accent-coloured subject and time.
- **Right-click acts in place:**
  - Right-clicking a message runs the command on that message without selecting or opening it. So "Mark as Unread" stays unread instead of being marked read by the preview.
  - Right-clicking inside a multi-selection acts on the whole selection.
- **Smart image loading:**
  - Images up to 2 MB each (10 MB and 60 requests per message) load automatically. `http://` images are fetched over https instead, redirects are followed only to https on public hosts, and addresses on your local network are never contacted. Images are shrunk to at most 2400 px, so a 6000 px photo uses about 10 MB of memory instead of about 140 MB.
  - Bigger images show a "Load image · 4.3 MB" box. Click it to load just that one, or use "Load all images" / "Always load from this sender".
  - Tracking pixels (including CSS-sized ones) are removed. A strict Content-Security-Policy blocks anything the sanitiser misses.
  - Images in Spam never load on their own.
  - Shrunk images are cached on disk (200 MB cap).
- **Attachments:**
  - Click a chip (or right-click → Save As…) to save one attachment.
  - **Save All…** zips every attachment into one `.zip`.
  - Downloads stream in 2 MB chunks, so a 25 MB file never sits in RAM, and are checked against the size the server announced.
  - Attachments aren't opened inside the app.
- **Writing mail:**
  - New message, Reply, Reply All and Forward. Forward includes the original attachments; Send waits until they're downloaded. If the original's text isn't cached yet, it's fetched before the composer opens.
  - Replies and forwards show the original email under what you type, rendered the way it looked; drag the divider to resize it. That's what's quoted when you send. Untick "Include original message" to leave it out.
  - Drag an address between To, Cc and Bcc to move it. Copy and paste still copies.
  - Replies clean up addresses that some senders write as links (`<mailto:help@bank.in.>`), which Gmail would otherwise reject with "553-5.1.3 not a valid RFC 5321 address".
  - Rich text with bold, italic, underline, colours and links.
  - Per-account signatures.
  - Address autocomplete from your mail.
  - Drafts saved to the server, with Bcc, attachments and reply threading restored when you reopen one.
  - Quitting with an unsaved message asks Save / Discard / Cancel. A message in its Undo Send countdown is kept as a draft until Gmail accepts it, so a failed send or quit never loses it.
  - Paste a screenshot into the body to attach it. The window title follows the subject.
  - Changing the From account swaps in that account's signature.
  - Undo Send (10 s by default): click Undo, or press ⌘Z or Esc. With the delay set to 0 no Undo is offered.
  - Addresses are checked before sending; anything with control characters, extra angle brackets or quotes is refused, so a crafted name or `mailto:` link can't add hidden recipients or headers.
- **Mail actions:** read/unread, flag, archive, delete, report spam / not spam, and move to any label or folder. Actions apply instantly and are queued for the server, so they also work offline. Queued actions are sent after every sync, reconnect and when the app becomes active; temporary server refusals are retried, and a message whose move is refused reappears. The sidebar shows "N actions waiting" while anything is queued.
- **Multiple accounts:**
  - Add several Gmail accounts. Each appears in the sidebar with its folders; right-click an account for Sync Now, Sign in again and Remove. A sign-in problem shows a warning on the account row.
  - All Inboxes appears when there's more than one account.
  - Choose a default account for new mail.
- **Sharing files into a message:**
  - Mac Explorer's Share menu has **Email with Mac Mail**. Finder's *Open With*, dropping files on the Dock icon, and `mailto:` links all work too.
  - Each starts a new message with the files attached; folders are zipped first.
- **Spam:** Gmail filters spam on its own servers before mail reaches any app. Mac Mail shows the Spam folder, and its Spam / Not Spam buttons apply Gmail's real spam label, which trains Google's filter.
- **Other:**
  - Unread counts in the sidebar and Dock badge come from the server (IMAP `STATUS`), so they include mail older than the offline window; reading or moving mail updates them instantly. The badge can be turned off in Settings.
  - Notifications for new mail while the app is open; clicking one opens the message.
  - Unsubscribe when the sender supports it, after a confirmation that shows where it goes.
  - Replied messages show an arrow in the list. Swipe a row for Archive or Read/Flag.
  - Reading-pane zoom (⌘+ / ⌘- / ⌘0) and the light-background choice are remembered (zoom globally, light background per sender).
  - VoiceOver reads each message row as one line (unread, flagged, sender, subject, time) and announces toasts.
  - Can be set as the default email app.
- **Native and small.** AppKit only, no third-party libraries, a 3 MB universal binary (Apple silicon + Intel).

![New message started from a shared file](docs/screenshots/compose.png)

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel).
- A Gmail account with **2-Step Verification** turned on and an **App Password** (see Permissions).
- To build from source: Xcode Command Line Tools with Swift 6 (`xcode-select --install`).

## Install

### Option 1: DMG

1. Run `./package.sh` (or download a release), then open `release/MacMail-<version>.dmg`. DMGs aren't committed to git.
2. Drag **Mac Mail.app** into `Applications`.
3. Open it from Applications. The build is ad-hoc signed, so the first time, right-click → **Open**.
4. Click **Add Account…**, then enter your Gmail address and App Password.

### Option 2: Build from source

```bash
./build.sh            # debug build → ~/Library/Caches/MacMailBuild/Mac Mail.app
./build.sh release    # optimized universal build
./package.sh          # release build + release/MacMail-<version>.dmg
```

`MAC_MAIL_ARCHS=arm64 ./build.sh` builds a single architecture for faster local iteration (release builds stay universal unless you set it). `build.sh` runs the offline selftest first; `MAC_MAIL_SKIP_SELFTEST=1` skips it. `package.sh` uses `hdiutil`, so it works on macOS 14. CI runs the selftest on every push (`.github/workflows/selftest.yml`). To run the offline protocol and MIME checks by hand:

```bash
tools/selftest.sh
```

## Permissions

- **Gmail App Password.** Gmail no longer accepts your normal password from mail apps. Create an App Password once:
  1. Turn on 2-Step Verification for your Google account.
  2. Open <https://myaccount.google.com/apppasswords> and create one (any name, for example "Mac Mail").
  3. Paste the 16-character password into Mac Mail. Spaces are fine.

  The password is stored only in the macOS Keychain. Revoke it at the same page at any time. No Google Cloud project or API key is needed.
- **Notifications** (optional). macOS asks when you turn on "Notify about new mail" in Settings or add your first account.

## Usage

- **⌘N:** new message.
- **⌘R / ⇧⌘R / ⌘J:** reply, reply all, forward.
- **⌘↩:** send. A toast offers **Undo** for 10 seconds.
- **⇧⌘A:** attach files. Dropping files on the message or the Dock icon also attaches them.
- **⇧⌘S:** save attachments (one opens a Save dialog, several save as a `.zip`).
- **⌫ / E / ⌃⌘A:** delete, archive.
- **⇧⌘J:** report spam / not spam.
- **⇧⌘U / ⇧⌘L:** mark read/unread, flag.
- **J / K:** next / previous message (also in a message window, with E and ⌫).
- Messages are marked read only when you open them (click, J/K, Return), not when the list auto-selects one at launch, after a folder switch, while typing a search or after archive/delete.
- **⌥⌘C:** turn conversation grouping on or off for this folder.
- **Double-click / Return:** open the message in its own window.
- **⌥⌘L:** show the open message with a light background (dark mode only).
- **Right-click a message:** Reply, Mark as Read/Unread, Flag, Archive, Delete, Spam or Move, on that message only. The selection doesn't change.
- **⌘1…⌘9:** go to the first nine folders. **⌃Tab:** move focus between sidebar, list and message.
- **Message → Move to…:** pick a folder with the keyboard.
- **⌘+ / ⌘- / ⌘0:** reading-pane zoom (works wherever focus is in the window).
- **⌥⌘F:** search all mail.
- **⌥⌘R:** sync now.
- **⌘,:** Settings (accounts, signatures, appearance, offline window, image limits, Undo Send delay, default email app).
- **Double-click a draft:** continue editing it.

## How it works

- **Protocol.** The app talks to Gmail directly over IMAP (TLS, port 993) and SMTP (TLS, port 465) through `Network.framework`. It uses Gmail's IMAP extensions: `X-GM-THRID` for conversations, `X-GM-MSGID` to de-duplicate, and `X-GM-RAW` for real Gmail search. It also uses CONDSTORE for flag deltas, MOVE, and IDLE.
- **Five connections per account**, each with its own job, so what you click never waits behind background work (Gmail allows 15):
  - *sync*: delta syncs and the queued actions.
  - *fetch*: what you click, such as message text, inline images and search. It's opened and pointed at the Inbox right at launch.
  - *prefetch*: background caching of message text, 10 messages per request.
  - *idle*: Inbox push.
  - *download*: attachment saves.

  A per-connection async gate keeps each "select folder → act" step together. Sign-in is TLS plus a single LOGIN (capabilities come back in the LOGIN reply).
- **Prefetch.** After each sync the newest messages' text is cached in batches. When you open a message, the next three (and the one above) are fetched too, so arrowing down the list is instant.
- **Never caches an empty message.** If Gmail sends no text for a message, it isn't saved, so opening it fetches again. Empty bodies left by older versions are cleared on launch.
- **Small updates.** Read/flag changes patch only the affected rows, with no full list reload. The App Password is read from the Keychain once, off the main thread, and kept in memory.
- **Structure first.** Each message's MIME tree (`BODYSTRUCTURE`) is cached, so reading a message downloads only its text part. Inline images and attachments are fetched only when you look at them or save them.
- **Storage.** Mail is kept in SQLite (system `libsqlite3`, WAL, 2 MB page cache, owner-only file permissions) with FTS5 indexes for headers and cached message text. The schema is versioned (`PRAGMA user_version`) and migrates older caches in place. Queued actions remember the folder's UIDVALIDITY, so they're dropped instead of hitting the wrong message if Gmail renumbers a folder; every fetch checks UIDVALIDITY too. An empty or broken folder list never prunes the cache. The body cache is capped by size, not row count. The message list loads small row objects and creates only the visible cells. The cache prunes itself to the offline window.
- **Reading pane.** One reused `WKWebView` with email scripts disabled. Dark mode recolouring runs as an app-injected script in WebKit's separate client script world (`DarkReader` in `HTMLPrep.swift`), so it works even though the email's own scripts are off. Every remote image URL is rewritten to `lm://img/<render>/<n>`, served by the app's own loader. The render number makes the URLs unique to each message: WebKit caches by URL, and without it one email could show another email's pictures. The loader enforces the size limits and shrinks images with ImageIO. A content-blocking rule (installed before the first message renders) and a Content-Security-Policy stop WebKit from loading anything else over the network. HTML is sanitised off the main thread. Links open in your default browser.
- **Unread counts.** After each folder sync (and for every folder when the folder list refreshes) one `STATUS (UNSEEN)` command runs on the sync connection. The cache stores the server count with the local count at that moment, and shows `server + local changes since`.
- **Window size.** The reading pane keeps a stretchable spacer while WebKit is shut down, so the window never collapses to the header's height; a collapsed frame saved by an older build is discarded on launch.
- **Sending.** MIME is built by hand (multipart/alternative plus base64 attachments, headers folded per RFC 5322, control characters stripped) and sent via SMTP AUTH PLAIN. Quoted replies go through the same HTML sanitiser as the reading pane.
- **Hardening.** The IMAP parser caps line length, literal size (64 MB), nesting depth and response counts, and every connection has read timeouts, so a hostile or stuck server can't crash or hang the app. Only one copy of the app can run at a time. Gmail files the copy in Sent itself.

### Performance (measured, Apple silicon, real Gmail account)

- **Launch → window with the Inbox:** about 0.37 s.
- **Opening a cached message (text on screen):** 10–30 ms.
- **Opening an uncached message:** about 0.4–0.7 s, one round trip to Gmail.
- **Read/flag change:** only the changed rows redraw. A full list of about 2,800 rows reloads in about 4 ms when needed.
- **Memory** (real account, ~2,800-message Inbox, measured with `footprint`, WebKit helpers counted):
  - The app: about 60–65 MB once launch sync and text prefetch finish, and about 65 MB after opening the 10 newest messages.
  - WebKit while reading: about 45 MB for a plain message, and up to 130–180 MB (page plus graphics process) for image-heavy newsletters. Images are shrunk to at most 2400 px first, and older messages' images are dropped from WebKit's memory cache on each open.
  - WebKit's processes exit a minute after you switch away (or at once when minimised), leaving just the app.
  - Background text caching returns its temporary memory as it goes, and freed pages go back to macOS after each sync and prefetch.
- **Each new build or update** asks once for your login password so it can read the App Password from the Keychain (ad-hoc signed apps get a new signature each build). Choose **Always Allow**.

Timings can be reproduced with `MAC_MAIL_DEBUG=1 MAC_MAIL_BENCH=1`, which opens the 10 newest messages read-only and logs timings and memory (`MAC_MAIL_BENCH_OFFSET=N` starts further down the list).

### Limits

- No new-mail alerts while the app is closed. That's the price of never running in the background.
- Gmail's Snooze, Scheduled Send, Nudges and Confidential mode aren't available over IMAP.
- "Other" IMAP accounts need servers that use TLS on connect (IMAP 993, SMTP 465). STARTTLS-only SMTP (port 587, for example iCloud) isn't supported yet, and Outlook.com accounts need OAuth, which isn't supported yet.
- Unlike Gmail on the web, loaded images come straight from the sender's server, so the sender can tell the message was opened. Use "Ask before loading any remote images" in Settings if that matters.
- Encrypted mail (S/MIME, PGP) and calendar aren't included.
- An image whose server offers no https version can't be shown (plain http is never used).
- The app is ad-hoc signed with the hardened runtime, but it isn't sandboxed or notarized, and the local cache isn't encrypted (it's readable only by your user account).

## Project layout

```text
mac-mail/
├── .github/workflows/       selftest CI
├── build.sh                 selftest + universal swiftc build, ad-hoc signed (hardened runtime)
├── package.sh               release build + DMG in release/
├── Resources/
│   ├── Info.plist           bundle id, mailto: handler, document types for "Open With"
│   └── AppIcon.icns
├── Sources/
│   ├── App/                 main.swift, AppDelegate (menus, file/mailto handling), Snapshot (demo captures)
│   ├── Core/                SQLite wrapper, Store (cache + FTS + action queue), models, Keychain, Prefs
│   ├── Net/                 TLSStream, IMAP parser and client, SMTP client
│   ├── Mail/                MIME decoding, BODYSTRUCTURE, outgoing message builder, address/header safety, search query parser
│   ├── Sync/                AccountEngine (sync, IDLE, actions), MailService, demo data
│   └── UI/                  main window, sidebar, message list, search filter bar, preview, message window, shared message actions, image loader, attachments,
│                            compose, settings
├── Tests/SelfTest.swift     offline protocol / MIME checks (tools/selftest.sh)
├── tools/
│   ├── selftest.sh
│   └── make_icon.swift      renders Resources/AppIcon.icns
└── docs/screenshots/
```

UI behaviour has an in-app check too. It runs ⌘1–9, pane focus, reading-pane zoom, the message window size, To → Cc drag, the compose title and the quit-with-unsaved-message prompt through their real code paths in the demo mailbox and prints PASS/FAIL lines:

```bash
MAC_MAIL_DEMO=1 MAC_MAIL_DEMO_SELFTEST=1 "$HOME/Library/Caches/MacMailBuild/Mac Mail.app/Contents/MacOS/MacMail" 2>&1 | grep selftest:
```

Screenshots come from the built-in demo mailbox. It never touches the network for mail and keeps its data and settings apart from the real app (`~/Library/Application Support/MacMailDemo`, defaults domain `com.manikpruthi.macmail.demo`):

```bash
MAC_MAIL_DEMO=1 MAC_MAIL_DEMO_SELECT=1 MAC_MAIL_SNAPSHOT=/tmp/shot.png \
  "$HOME/Library/Caches/MacMailBuild/Mac Mail.app/Contents/MacOS/MacMail"
```

## License

MIT. See [LICENSE](LICENSE).
