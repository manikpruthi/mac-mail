# Architecture

Mac Mail is one AppKit process with no helpers, no login items and no third-party code. This page is the
stable description of how the pieces fit; measurements live in the README's Performance section.

## Layers

| Layer | Folder | Responsibility |
|---|---|---|
| App | `Sources/App` | Launch, menus, file / `mailto:` / `.eml` handling, demo and benchmark hooks |
| Core | `Sources/Core` | SQLite wrapper, `Store` (cache, FTS, action queue, snapshots), models, Keychain, preferences, diagnostics log |
| Mail | `Sources/Mail` | MIME decoding, BODYSTRUCTURE, `.eml` reader (`EMLDocument`), message builder, search query parser, header safety |
| Net | `Sources/Net` | Byte transports (implicit TLS, STARTTLS), IMAP parser and client, SMTP client |
| Sync | `Sources/Sync` | `AccountEngine` per account, `MailService` hub, `Outbox`, demo data |
| UI | `Sources/UI` | Windows and views; `HTMLPrep` sanitiser; `ImageLoader` and `ImageDiskCache` |

`Core`, `Mail`, `Net`, `HTMLPrep` and `Outbox` have no AppKit dependency and are compiled into the offline selftest.

## Connections

Each account has five IMAP connections ("lanes") so a click never waits behind background work:
`sync` (delta sync, queued actions, folder management), `fetch` (bodies, inline images, search), `prefetch`
(background body caching), `idle` (Inbox push) and `download` (attachments, Save As). Each lane has a FIFO
`AsyncGate` so "select folder → act" runs as a unit. A changed account (server, port, login, security) drops
every lane and the cached password (`AccountEngine.resetConnections`).

Transports: `NWTransport` (Network.framework, implicit TLS) and `StartTLSTransport` (Foundation streams on a
private run-loop thread, upgraded in place). `TLSStream` buffers lines and literals on top of either.

## Data flow

1. **Sync** — UIDNEXT for new mail, CONDSTORE MODSEQ (or a recent-UID FLAGS sweep, full every 10th sync) for
   flags, UID SEARCH for removals. Headers and BODYSTRUCTURE go into `messages`; bodies are fetched on open or
   prefetched in batches, decoded off the main actor, then written.
2. **Actions** — optimistic local change, then a row in `pending_ops` bound to folder id + UIDVALIDITY.
   Moves/deletes first wait out an 8 s Undo window (`MailService.undoables`, restored from `Store.Snapshot`).
3. **Sending** — `MailService.queueSend`: *waiting* (undoable) → *uploading* → done. A safety draft is
   appended while uploading; connection failures move the finished MIME into the `Outbox` folder on disk.
4. **Composer autosave** — `ComposerAutosave` JSON per open composer in Application Support/…/Autosave,
   removed on send/save/discard, reopened at launch otherwise.

## Storage

SQLite (WAL, 2 MB page cache, owner-only permissions), schema version in `PRAGMA user_version` (now 5).
FTS5 indexes for headers (`fts`, external content) and cached text (`body_fts`); triggers keep them and
`contacts` in step, with `recursive_triggers` on so cascades fire them. Pruning runs on its own connection.

## Rendering

One reused `WKWebView` per reading pane, scripts off, a content rule list plus CSP blocking the network,
every image routed through `lm://` to `ImageLoader`, which enforces size budgets, SSRF checks and
downsampling. Web views are torn down a minute after the app goes to the background.
