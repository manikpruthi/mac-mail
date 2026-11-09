# Security

## Credentials
- Passwords live only in the login Keychain (`com.manikpruthi.macmail`, one item per account id).
  Writes update in place and report failures; a refused write never deletes the stored password.
- A password is never sent without TLS: STARTTLS servers that don't offer the upgrade are refused, and
  capabilities are re-read after the handshake (pre-TLS bytes are discarded).
- The Keychain is read once per connection set, off the main thread, and the value kept in memory.

## Untrusted input
- **IMAP**: line length, literal size (64 MB), nesting depth and response counts are capped; every command
  has a watchdog. BODYSTRUCTURE parsing is depth-limited.
- **SMTP**: envelope addresses must be strict addr-specs; per-command idle timeouts.
- **HTML display**: active elements stripped, remote loads rewritten to `lm://`, content rule list + CSP,
  tracking pixels removed, http upgraded to https, private-network addresses never contacted.
- **Quoted HTML (replies/forwards)**: stricter — no `<style>`/`<link>`, no `on*` handlers, no
  `javascript:`/`vbscript:`/`data:` links, https images only.
- **.eml files**: parsed with size (64 MB), depth (20) and part-count (500) limits; rendered with remote
  images off until asked for; inline images come from the file.
- **Filenames** from senders are sanitised (`BodyPart.safeFilename`).
- **Headers** written by the builder strip controls and fold; In-Reply-To/References keep well-formed ids only.

## Local data
- Cache, autosaves and outbox are owner-only files in the user's Library; they aren't encrypted.
- The diagnostics log records error text only (no content, no passwords) and is capped at 512 KB.

## Code signing
- Hardened runtime, no entitlement exceptions (`Resources/MacMail.entitlements`), not sandboxed (ADR 0002).
- Ad-hoc builds keep the default designated requirement (the code hash), so a Keychain grant applies to
  exactly one binary. Release builds can be signed with Developer ID and notarised (`MAC_MAIL_SIGN_IDENTITY`,
  `MAC_MAIL_NOTARY_PROFILE`).
