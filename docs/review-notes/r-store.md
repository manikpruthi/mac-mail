# Review notes — r-store (second reviewer; SQLite, Store, Store+ListQueries, Store+Maintenance, Models, Memory, AccountEngine, DemoData)

C-10 | VERIFIED | Sources/Core/SQLite.swift:82 | `runChecked`/`transactionChecked` mark the open transaction and roll back half-applied batches, and `Store.insertChecked`/`updateFlagsChecked`/`updateFolderStateChecked` are used on every path that advances UIDNEXT/MODSEQ (AccountEngine.swift sync/loadOlder/serverSearch/refetchHeaders); a forced FK-failure scratch test throws out of `insertChecked`, leaves the store usable and stops state advance.
C-28 | VERIFIED | Sources/Core/Store.swift:373 | `renameFolder` repoints pending_ops by folder id (plus legacy folder_id=0 rows by path), rewrites queued move destinations and child folder paths in one transaction, and `flushOps` resolves the folder by id first; verified by a scratch test covering ops, move args, children and legacy rows.
W-02 | VERIFIED | Sources/Core/Store.swift:78 | The shape-guarded `upgradeHeaderIndex` adds the Cc column and rebuilds header FTS with from/to/cc/subject routed through it (`addHeaderFilter`, Store.swift:816); verified by scratch tests on a fresh database, a downgraded v4-shaped database (rows survive, cc: and backfilled body search work) and a reopen where the guard makes it a no-op.
Y-r-store-1 | FIXED-NOW | Sources/Core/Store.swift:765 | The now-uncalled `clearBodyCache` (Settings uses `Store.clearBodies(path:)`) still existed with its fire-and-forget utility-queue VACUUM, so the two body-cache clearing paths could overlap two VACUUMs against each other; the dead method is deleted, leaving one consistent path that deletes and VACUUMs on its own connection, never the main one.
Y-r-store-2 | FIXED-NOW | Sources/Core/Store.swift:142 | `backfillBodyIndex` collected the full html/text of every unindexed body in memory before indexing (a spike to the whole body cache on old databases, against the RAM constraint); it now collects ids only and reads each body inside the transaction.

Verification: `MAC_MAIL_SKIP_SELFTEST=1 MAC_MAIL_BUILD_DIR=build MAC_MAIL_ARCHS=arm64 ./build.sh debug` builds clean
(pre-existing warnings only, all outside these files). `tools/selftest.sh` shows the same 10 sandbox-caused failures
as the other reviewers noted (eml ×3, inline-image ×4, store opens, outbox add — NSTemporaryDirectory blocked);
everything else passes. Store-level behaviour was additionally exercised by a scratch harness under
`build/tmp/r-store-scratch` (31 checks, all pass: fresh/upgraded W-02 migration, rename/C-28, clearBodies+VACUUM,
C-10 rollback and no-op flag passes).
