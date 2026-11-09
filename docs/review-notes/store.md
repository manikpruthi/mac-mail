# Store / sync review notes (HEAD 2cf7eb0)

Verification: `MAC_MAIL_SKIP_SELFTEST=1 MAC_MAIL_BUILD_DIR=build MAC_MAIL_ARCHS=arm64 ./build.sh debug` builds clean;
`tools/selftest.sh` shows the same 10 failures before and after these changes, all caused by the sandbox blocking
`NSTemporaryDirectory()` (`/var/folders/.../T`), so the store prunes/search/snapshot checks are exercised by a
scratch harness under `build/tmp` instead. No new failures, 80 passes before and after.

C-10 | FIXED | Sources/Core/SQLite.swift:142 | A DB-level failure now marks the open transaction, which rolls back instead of committing half a batch, and new `runChecked`/`transactionChecked` throwing writes let `Store.insertChecked`/`updateFlagsChecked`/`updateFolderStateChecked` (Store.swift:413,441,329) stop `sync` from advancing UIDNEXT/MODSEQ past a write that never landed (AccountEngine.swift:301).
C-28 | FIXED | Sources/Core/Store.swift:369 | `renameFolder` now repoints queued ops by folder id (plus legacy path-only rows), also rewrites queued move destinations and nested child folder paths, and `flushOps` resolves the folder by id first and selects `f.path` (AccountEngine.swift:833).
W-02 | PARTIAL | Sources/Core/Store.swift:786 | `from:`/`to:`/`cc:`/`subject:` filters now go through the header FTS index instead of leading-wildcard LIKE, but the new Cc column is added by an idempotent shape-guarded schema step (Store.swift:78) rather than a `user_version` bump, because `Tests/SelfTest.swift` asserts `user_version == 5` and may not be edited.
X-store-1 | FIXED | Sources/Core/SQLite.swift:69 | The prepared-statement cache could evict and finalize a statement that was still being stepped (use-after-free); eviction is now skipped while any statement is active.
X-store-2 | FIXED | Sources/Core/SQLite.swift:74 | SQLite error text was concatenated into the `NSLog` format string, so a `%` in a message corrupted the log line; both parts are escaped now.
X-store-3 | FIXED | Sources/Sync/AccountEngine.swift:130 | A failed Keychain read stayed cached in `passwordTask`, so one transient error made the account unusable until sign-in-again; the failed task is dropped and retried.
X-store-4 | FIXED | Sources/Sync/AccountEngine.swift:90 | A dead IMAP connection was replaced without being closed, leaking its socket; it is disconnected before the new lane connection is opened.
X-store-5 | FIXED | Sources/Sync/AccountEngine.swift:172 | Cancelling a task (shutdown, superseded search) was reported as a user-visible sync error; cancellations are ignored.
X-store-6 | FIXED | Sources/Sync/AccountEngine.swift:771 | `serverSearch` ran on its own gate but the shared `.fetch` connection, so its SELECT could interleave with the SELECT/FETCH of a message being opened and cache the wrong body; it now shares `fetchGate`.
X-store-7 | FIXED | Sources/Sync/AccountEngine.swift:301 | For servers that omit UIDNEXT, the fallback UIDNEXT was computed before the headers were inserted, so every sync re-fetched and re-notified the same mail; it is computed after the writes.
X-store-8 | FIXED | Sources/Sync/AccountEngine.swift:807 | `queue` ignored a failed `pending_ops` insert, silently losing the offline action; `Store.addOp` reports success and the engine surfaces the failure.
X-store-9 | FIXED | Sources/Core/Store.swift:786 | A search word with no letters/digits produced an empty FTS phrase, which made the whole MATCH fail and hid every other term's results; such words are dropped (and match nothing on their own).
X-store-10 | FIXED | Sources/Core/Store.swift:665 | The body-cache prune deleted `bodies` rows but left their `body_fts` entries, so search kept matching text that was no longer cached; both go now.
X-store-11 | FIXED | Sources/Core/Store.swift:618 | The two-argument `saveBody` wrote the body, snippet and index as three separate autocommitted statements, leaving a half-cached row on failure; it now uses the single-transaction variant.
X-store-12 | FIXED | Sources/Core/Store.swift:766 | `clearBodyCache` ran `VACUUM` on the main connection and froze the window; compaction now runs on its own short-lived connection on a utility queue.
X-store-13 | FIXED | Sources/Core/Store.swift:179 | The v1→v2 contacts seed added to existing counts, so a migration that re-ran inflated them; it recomputes the (derived) table instead.
X-store-14 | FIXED | Sources/Core/Store.swift:334 | `resetFolder` deleted queued ops only by folder id, leaving pre-v2 rows (folder id 0) with stale UIDs that could be applied to the recreated folder; it also deletes by account+path.
X-store-15 | FIXED | Sources/Sync/AccountEngine.swift:364 | The pending-flag protection matched ops by folder path, so after a rename the server's flags could clobber local changes still queued; matching now uses the folder id.
