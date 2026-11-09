# ADR 0001: STARTTLS through Foundation streams

**Status:** accepted (1.1.0)

Network.framework (`NWConnection`) can't add TLS to an established plain connection, but IMAP 143 and SMTP 587
require exactly that. Options: a custom TLS implementation (no), SwiftNIO (third-party dependency), or
Foundation `InputStream`/`OutputStream`, which switch to TLS when `.socketSecurityLevelKey` is set on an open
stream. We use Foundation streams for STARTTLS only, on a private run-loop thread behind the same
`ByteTransport` protocol; implicit TLS stays on Network.framework.
