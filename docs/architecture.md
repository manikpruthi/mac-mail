# Architecture

Mac Mail is one AppKit process with no helpers, no login items and no third-party code. This page is the
stable description of how the pieces fit; measurements live in the README's Performance section.

## Layers

| Layer | Folder | Responsibility |
|---|---|---|
| App | `Sources/App` | Launch, menus, file / `mailto:` / `.eml` handling, demo and benchmark hooks |
| Core | `Sources/Core` | SQLite wrapper, `Store` (cache, FTS, action queue, snapshots) with windowed list queries and maintenance, models, Keychain, preferences, diagnostics log |
| Mail | `Sources/Mail` | MIME decoding, BODYSTRUCTURE, `.eml` reader (`EMLDocument`), message builder, search query parser, header safety |
| Net | `Sources/Net` | Byte transports (implicit TLS, STARTTLS), IMAP parser and client, SMTP client |
| Sync | `Sources/Sync` | `AccountEngine` per account, `MailService` hub (plus `MailService+Offline` for unchecked account edits), `Outbox`, demo data |
| UI | `Sources/UI` | Windows and views; `HTMLPrep` sanitiser; `ImageLoader` and `ImageDiskCache` |

`Core`, `Mail`, `Net`, `HTMLPrep` and `Outbox` have no AppKit dependency and are compiled into the offline selftest.

## Connections

Each account has five IMAP connections ("lanes") so a click never waits behind background work:
`sync` (delta sync, queued actions, folder management), `fetch` (bodies, inline images, search), `prefetch`
(background body caching), `idle` (Inbox push) and `download` (attachments, Save As). Each lane has a FIFO
`AsyncGate` so "select folder → act" runs as a unit. A changed account (server, port, login, security) drops
every lane and the cached password (`AccountEngine.resetConnections`).

Transports: `NWTransport` (Network.framework, implicit TLS) and `StartTLSTransport` (Foundation streams on a
private run-loop thread, upgraded in place). `TLSStream` buffers lines and literals on top of either. Before
a STARTTLS handshake both `TLSStream` and `StartTLSTransport` discard any plaintext already buffered (the
transport clears its own buffer on its run-loop thread), so pre-TLS bytes can't be read as if they arrived
over TLS; capabilities are asked for again.

## Data flow

1. **Sync** — UIDNEXT for new mail, CONDSTORE MODSEQ (or a recent-UID FLAGS sweep, full every 10th sync) for
   flags, UID SEARCH for removals. Headers and BODYSTRUCTURE go into `messages`; bodies are fetched on open or
   prefetched in batches, decoded off the main actor, then written.
2. **Actions** — optimistic local change, then a row in `pending_ops` bound to folder id + UIDVALIDITY.
   Moves/deletes first wait out an 8 s Undo window (`MailService.undoables`, restored from `Store.Snapshot`).
   Empty Trash/Spam flags every message and uses `UID EXPUNGE` where the server has UIDPLUS; without it a
   bare `EXPUNGE` runs only when the server's `\Deleted` set is exactly the UIDs just flagged.
3. **Sending** — `MailService.queueSend`: *waiting* (undoable) → *uploading* → done. A safety draft is
   appended while uploading; connection failures move the finished MIME into the `Outbox` folder on disk.
   Each record (`item.json` plus `message.eml`) is written and read back before the queue reports it, and an
   unreadable record is moved to `Outbox Corrupt` off the main thread instead of being dropped.
4. **Composer autosave** — `ComposerAutosave` JSON per open composer in Application Support/…/Autosave,
   removed on send/save/discard, reopened at launch otherwise.

## Storage

SQLite (WAL, 2 MB page cache, owner-only permissions), schema version in `PRAGMA user_version` (now 5).
FTS5 indexes for headers (`fts`, external content) and cached text (`body_fts`); triggers keep them and
`contacts` in step, with `recursive_triggers` on so cascades fire them. Folder, unified and flagged lists are
ordered and windowed in SQL (newest or oldest, with an id tiebreak) in `Store+ListQueries`; search results
are ordered in memory and paged. `Store+Maintenance` reads the Storage figures and clears the text and
search cache on their own connections, off the main thread. Pruning runs on its own connection too.

## Rendering

One reused `WKWebView` per reading pane, scripts off, a content rule list plus CSP blocking the network,
every image routed through `lm://` to `ImageLoader`, which enforces size budgets, SSRF checks and
downsampling. Web views are torn down a minute after the app goes to the background.
