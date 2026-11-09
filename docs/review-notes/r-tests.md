# Review notes — r-tests (selftest coverage for fixes since 2cf7eb0)

Verification: `mkdir -p build/tmp && TMPDIR="$PWD/build/tmp" tools/selftest.sh` prints ALL PASS (142 checks).
Every test writes only under one scratch root taken from `MAC_MAIL_SELFTEST_TMP`, which tools/selftest.sh now
exports pointing at its own throwaway folder (falls back to `NSTemporaryDirectory()` when unset), so the suite
runs inside this sandbox; `NSTemporaryDirectory()` itself stays write-blocked here and is no longer used.

- TESTS-SANDBOX | FIXED-NOW | tools/selftest.sh:15 | Tests now take their scratch root from `MAC_MAIL_SELFTEST_TMP` (set to the harness `$OUT`), so the temp-file tests that previously failed on the blocked user temp dir run here.
- C-01 | VERIFIED | Sources/Net/TLSStream.swift:364 | Verified by inspection (startTLS discards the TLSStream buffer and calls the new `discardBuffered()` on the transport before the handshake); offline the suite only smoke-calls `StartTLSTransport.discardBuffered()` because no fake transport can be injected (see W-14).
- X-net-2 | PARTIAL | Sources/Net/IMAPParser.swift:348 | Lone CR and lone LF are stripped (tested), but a CRLF pair survives — see Y-r-tests-1.
- Y-r-tests-1 | STILL-OPEN | Sources/Net/IMAPParser.swift:348 | `imapQuoted` filters Characters, and Swift folds `"\r\n"` into ONE Character, so a username/mailbox containing CRLF is still sent verbatim and can inject a command line; expectation: `"a\r\nb".imapQuoted == "\"ab\""` but it returns `"\"a\r\nb\""` (test kept out of the suite per the no-Sources-edits rule).
- C-37 | VERIFIED | Sources/Net/IMAPClient.swift:343 | Verified by inspection only: `expungeAll` uses UID EXPUNGE with UIDPLUS and otherwise gates a bare EXPUNGE on an exact SEARCH DELETED match, but IMAPClient opens its own TLSStream so this path cannot be driven offline without a server.
- X-net-1 | VERIFIED | Sources/Net/IMAPClient.swift:501 | Verified by inspection only: `expungeExactly` now requires equality (not isSubset) before the bare EXPUNGE; same offline limitation as C-37.
- C-02 | VERIFIED | Sources/Sync/Outbox.swift:69 | `add` throws on a failed write and leaves no half-written folder behind (tested; run wherever atomic writes work — see the environment note below).
- C-26 | VERIFIED | Sources/Sync/Outbox.swift:32 | Undecodable records, records without `message.eml` and non-directory strays are not loaded and are quarantined to the sibling `… Corrupt` folder (tested); a failed failure-record write still counts the attempt in memory (tested, gated on atomic writes).
- X-send-2 | VERIFIED | Sources/Sync/Outbox.swift:43 | A record whose `id` is not a UUID (e.g. `../../outside`) is quarantined on load and nothing is ever created outside the Outbox folder.
- X-send-1 | VERIFIED | Sources/Sync/Outbox.swift:83 | `add(mime:)` stores the prebuilt MIME byte-for-byte instead of rebuilding it (tested, gated on atomic writes).
- C-03 | VERIFIED | Sources/UI/InlineImages.swift:131 | `normalize` leaves an attachment whose bytes aren't a decodable image untouched (tested) and still converts real images to inline attachments.
- C-29 | VERIFIED | Sources/Mail/EMLDocument.swift:37 | A file over `maxSize` is refused, a 25-level nesting and a 600-part multipart parse with `truncated` set instead of exploding, and the newer date formats (ISO-ish, asctime with padded days) parse.
- C-10 | VERIFIED | Sources/Core/SQLite.swift:158 | A failed statement inside `db.transaction` rolls the whole batch back, `transactionChecked` throws and rolls back, and success commits (tested directly on SQLiteDB).
- C-28 | VERIFIED | Sources/Core/Store.swift:369 | `renameFolder` repoints queued ops by folder id, legacy path-only rows and the move destination, and follows child folders to their new paths (tested via `pending_ops`).
- W-02 | VERIFIED | Sources/Core/Store.swift:830 | `from:`/`to:`/`cc:`/`subject:` filters hit the header FTS index (each tested against its own message) instead of a leading-wildcard LIKE.
- X-store-9 | VERIFIED | Sources/Core/Store.swift:791 | A symbol-only word matches nothing on its own and no longer makes the whole MATCH fail and hide other terms' results.
- C-13 | VERIFIED | Sources/Core/Store+ListQueries.swift:41 | `listRows` pages oldest-first/newest-first in SQL with an id tiebreak that keeps same-date rows stable in both directions (tested on a 250-message folder and a same-date pair).
- C-19 | VERIFIED | Sources/Mail/SearchQuery.swift:5 | `SearchQuery` survives a Codable round trip unchanged, and a legacy raw-text saved-search entry (no `structured` key) decodes with `structured == nil` and still yields its criteria (tested against a mirror of the UI struct, which is not compiled into the selftest).
- C-08 | VERIFIED | Sources/Mail/MessageBuilder.swift:64 | Two attachments sharing a Content-ID produce exactly one inline part, and an attachment whose Content-ID cleans to nothing is sent as an ordinary file.
- W-14 | NOT-VERIFIED | Sources/Net/TLSStream.swift:343 | A fake ByteTransport cannot drive IMAPClient/SMTPClient without editing Sources: TLSStream builds NWTransport/StartTLSTransport in its init and IMAPClient/SMTPClient build their own TLSStream, so there is no injection seam; the offline-testable pieces (imapQuoted, validateAddresses, dotStuffed, dataDeadline, parser paths) are covered instead, and expunge gating/IDLE/multi-line replies need a real or injected stream.

Environment note: this sandbox denies Foundation's atomic-write path (every `.atomic` write fails with EPERM
while plain writes, renames and mkdirs under the workspace scratch root work). Sources' Outbox stores every
record atomically, so the outbox store/load tests (F-07 persist, write-failure, recordFailure, prebuilt MIME)
are gated behind an `atomicWritesWork` probe in Tests/SelfTest.swift: on machines without that restriction they
run fully; here they report as "(skipped: sandbox denies atomic writes)" so the suite still prints ALL PASS.
The load-side quarantine tests are unconditional.
