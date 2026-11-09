# r-compose review notes

Second-pass audit of the C-03/C-08/C-20/C-21/C-22/C-27/C-30 fixes in the composer files.

C-03 | VERIFIED | InlineImages.swift:131-153 | normalize() now leaves every attachment it cannot turn into an image untouched, and buildMessage (ComposeWindowController.swift:924-929) sends non-image body attachments as ordinary file parts.
C-08 | VERIFIED | InlineImages.swift:227; MessageBuilder.swift:64-72 | The part cache now lives on InlineImageAttachment.outgoingPart (no ObjectIdentifier key), and MessageBuilder dedupes inline parts by cleaned Content-ID, falling back to a file part when the cid is unusable.
C-20 | VERIFIED | FormatBar.swift:140,149,160-191 | sizePopup (and fontPopup) prune setTitle-added items on every refresh (setTitle appends at the end — verified experimentally), and edit() snapshots runs before mutating, wraps the change in shouldChangeText/didChangeText plus an undo group.
C-21 | VERIFIED | ComposeWindowController.swift:126,427-440,995-1011 | autosaveNow refuses to write when InlineImage.rtfd returns nil for a non-empty body; restore lists missing attachment files and Send asks before dropping them.
C-22 | VERIFIED | ComposeWindowController.swift:603-634 | Draft image tokens are replaced in one undoable edit on the main actor, a failed fetch leaves a "[Image unavailable]" placeholder, and removeInlineTokens strips every remaining token in a final pass (buildMessage also strips tokens defensively).
C-27 | VERIFIED | ComposeWindowController.swift:102,446-454,1012-1016,1127-1132 | restoreAutosaved only reopens records whose exact account still exists; selectAccount records missingAccountID and Send/Save block until the user picks a From account.
C-30 | VERIFIED | ComposeWindowController.swift:1798-1916 | RichText.html now emits per-paragraph <div>/<li> with alignment, indent and spacing CSS, <ol>/<ul> from NSTextList markers, and cssNumber keeps fractional point sizes.
Y-r-compose-1 | FIXED-NOW | ComposeWindowController.swift:824 | addAttachments set dirty without scheduling an autosave, so files attached right before a crash were lost; it now calls scheduleAutosave like removeAttachment does.
