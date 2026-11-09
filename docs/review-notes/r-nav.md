# r-nav review notes (HEAD fa15f3b)

C-04 | VERIFIED | MainWindowController.swift:650 | Unified/flagged sources empty the role in every account with one confirmation and an aggregate cached count; folder sources resolve their target through the same helper.
C-07 | VERIFIED | SidebarViewController.swift:201 | reload() reports the select(kind:) fallback to the list after suppressSelection is cleared, so list.source can no longer point at a deleted folder.
C-12 | VERIFIED | Sources/UI/MessageListViewController.swift:183 | skipNextFullReload is consumed at the top of dataChanged before the .search early return, so a search-time archive cannot leave it armed to swallow the next .all change.
C-14 | VERIFIED | MainWindowController.swift:105 | Typing, submitting and filter-bar changes clear the reading pane as the results reload, and the list selects nothing until the user picks a result.
C-15 | VERIFIED | MainWindowController.swift:113 | Every source change now goes through showSource → sidebar.select(source:), and clearing the search restores lastSource with its sidebar row highlighted.
C-19 | FIXED-NOW | MainWindowController.swift:358 | Saved searches restore text, filter-bar choices and folder scope, and now start from a reset filter-bar context so the previous search's filters/scope cannot leak in.
C-35 | FIXED-NOW | Sources/Core/Store+Sidebar.swift:8 | The unified Flagged row shows Store.flaggedUnreadCount(), and the first populated reload opens every account/group instead of leaving them all collapsed.
C-32 | FIXED-NOW | SidebarViewController.swift:410 | Turning the per-account notification toggle on now calls MailService.requestNotificationPermission(), matching the Settings switch.
W-16 | FIXED-NOW | MainWindowController.swift:741 | The FolderPicker was already retained until its sheet ends; Save Attachments, Empty Trash, Empty Spam and Sync Now now validate their preconditions.
Y-r-nav-1 | FIXED | SidebarViewController.swift:330 | Selecting a source whose row sits under a collapsed account/group silently fell back to another row, so ⌘1…9 never highlighted the requested folder; selectIfPresent now expands the parent and selects the real row.
Y-r-nav-2 | FIXED | MainWindowController.swift:365 | Running a scoped saved search left lastSource unchanged, so re-saving it stored a different folder; the search origin now becomes lastSource.
Y-r-nav-3 | FIXED | SearchFilterBar.swift:162 | Toggling a filter updated filters without refreshing Clear, which stayed hidden until an unrelated layout pass; changed() now updates it immediately.
