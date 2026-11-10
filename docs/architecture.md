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
   The window's folder ids and UIDs are journalled in the `prefs` table (`undo.<id>`); an entry left by a
   crash is replayed at launch by re-fetching those headers. A final refusal (or a failed queue write) marks
   the source folder in `AccountEngine.unsettledSources`, which `settleOps` checks before a folder is
   deleted, renamed or emptied.
   An undoable holds one part per account (rows, destination folder, commit). Empty Trash/Spam, Delete
   Folder and Rename Folder take out and commit only the parts that touch that folder (`takeParts`),
   trimming the snapshot (`Snapshot.removing`) so Undo restores just what is still waiting; removing an
   account drops its parts unsent. Delete/Rename Folder then settle the folder's queued ops like Empty does.
   Empty Trash/Spam (`IMAPClient.expungeAll`) first sends the queued actions for the folder, selects it
   fresh, snapshots its UIDs and flags only snapshot messages that are not already `\Deleted`. With
   CONDSTORE each chunk is read with `UID FETCH (FLAGS MODSEQ)` and stored with `UNCHANGEDSINCE`, so a
   message another client changed in between comes back in `[MODIFIED]` and is never counted as ours;
   without it the `\Deleted` set is read immediately before each `STORE` (best effort). UIDPLUS expunges
   the snapshot with `UID EXPUNGE <set>`; otherwise a bare `EXPUNGE` runs only when the server's `\Deleted`
   set is exactly the snapshot. Any failure takes back exactly the flags the command added.
   Rows removed locally but still on the server (Undo window or queued) are skipped by header fetches
   (`AccountEngine.locallyRemovedUIDs`), so a sync or search in between can't bring them back.
3. **Sending** — `MailService.queueSend`: *waiting* (undoable) → *uploading* → done. A safety draft is
   appended while uploading; connection failures move the finished MIME into the `Outbox` folder on disk.
   Any other failure reports `.failed(error, safetyDraft:)`: the draft the message was opened from is
   discarded (the safety copy is newer and confirmed on the server) and the composer adopts the safety
   copy as its `draftRow`, so the next send or save replaces it instead of leaving two drafts.
   Each record (`item.json` plus `message.eml`) is written into a `.tmp` staging folder, renamed into place
   and read back before the queue reports it; an unreadable record is moved to `Outbox Corrupt` off the main
   thread instead of being dropped. A decision the item's own folder can't store (it refused a delete) is
   kept in `<id>.decision` beside it.
   The composer hands the autosave queue a private copy of the body; the live text storage is only read
   on the main thread.
4. **Composer autosave** — `ComposerAutosave` JSON per open composer in Application Support/…/Autosave,
   removed on send/save/discard, reopened at launch otherwise.

## Storage

SQLite (WAL, 2 MB page cache, owner-only permissions), schema version in `PRAGMA user_version` (now 5).
FTS5 indexes for headers (`fts`, external content) and cached text (`body_fts`); triggers keep them and
`contacts` in step, with `recursive_triggers` on so cascades fire them. Folder, unified and flagged lists are
ordered and windowed in SQL (newest or oldest, with an id tiebreak) in `Store+ListQueries`; search results
are ordered in memory and paged. `Store+Maintenance` reads the Storage figures and clears the text and
search cache on their own connections, off the main thread. Pruning runs on its own connection too.
`SQLiteDB.transaction` reports whether the batch committed; folder-list saves, renames, flag changes and
local deletes stop (and say so) instead of carrying on as if a skipped write had landed. A cached folder is
pruned only after two consecutive LIST replies omit it, and a miss is recorded only after the folder-list save
committed. `AccountEngine.client` checks a connection epoch after every suspension, so a reset or shutdown
never hands out a connection opened with the old settings.

## Rendering

One reused `WKWebView` per reading pane, scripts off, a content rule list plus CSP blocking the network (the CSP sits in a head of its own at the start of the
document, after a leading doctype only, never after the email's own `<head>` text),
every image routed through `lm://` to `ImageLoader`, which enforces size budgets, SSRF checks and
downsampling. Web views are torn down a minute after the app goes to the background.
