# ADR 0003: Undo by delaying the server operation

**Status:** accepted (1.1.0)

Undoing a server-side MOVE needs the destination UIDs (COPYUID, not available everywhere) and a second
round trip. Instead, archive/delete/move/spam remove the rows locally at once but hold the queued server
operation for 8 seconds. Undo restores a full row snapshot (messages + bodies) and cancels the operation;
quitting commits whatever is still waiting.
