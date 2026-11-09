# ADR 0002: Hardened runtime without App Sandbox

**Status:** accepted

Sandboxing would move the cache and Keychain items into a container, breaking existing installs, and would
need entitlements for every file the user attaches or drops. The app runs with the hardened runtime and no
entitlement exceptions instead; see docs/security.md.
