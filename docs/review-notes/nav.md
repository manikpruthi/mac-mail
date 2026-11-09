# nav review notes (HEAD 2cf7eb0)

C-04 | FIXED | MainWindowController.swift:635 | From a unified source emptyRole now confirms once and empties the role in every account, with the aggregate cached-message count in the sheet.
C-07 | FIXED | SidebarViewController.swift:190 | reload() detects that select(kind:) fell back to selectDefault() and fires onSelect with the fallback source after suppressSelection is cleared, so list.source follows the highlight.
C-12 | FIXED | MainWindowController.swift:567 | move() no longer sets skipNextFullReload while the list is searching — the list's .search branch consumes the .all change itself, so the flag can't swallow the next genuine notification.
C-14 | FIXED | MainWindowController.swift:344 | Typing, submitting a search and changing filter-bar choices all clear the preview (filter changes via the new .mailSearchFiltersChanged notification); the next explicit selection repopulates it.
C-15 | FIXED | MainWindowController.swift:113 | Every source change now routes through showSource → sidebar.select(source:), so ⌘1…9 and clearing the search restore the sidebar highlight; the sidebar gained a non-reentrant select(source:).
C-19 | FIXED | MainWindowController.swift:286 | Save Search persists the filter-bar filters and the "This folder" scope folder id alongside the text (SearchQuery and SearchFilters are now Codable); selecting the saved search restores filters, scope and results, and old raw-text entries still load.
C-35 | PARTIAL | SidebarViewController.swift:179 | Expansion state is preserved across reloads and unified role rows show summed unread counts; the Flagged badge stays empty because Store exposes no cheap flagged-unread query and Store.swift is outside this task's file list.
X-nav-1 | FIXED | MainWindowController.swift:113 | showSource falls back to .unified when the folder a search was started from was deleted meanwhile, instead of restoring a dead source (empty list titled "Folder").
