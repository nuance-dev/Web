# Tabs and session restoration

Pin a tab to keep it at the front. Bulk close actions preserve pinned tabs. Duplicate opens another tab with the same URL and privacy mode. Close duplicate tabs preserves the active copy and pinned tabs; private and normal tabs are never merged.

**Reopen tabs at launch** is off by default. When enabled, Web stores normal HTTP(S) tab URLs, titles, pin state, zoom, and active position in a local session file. It stores no page text, forms, password records, screenshots, or private tabs. URLs with recognized credential parameters and common one-time authentication links are excluded; arbitrary URL paths and query values can still contain sensitive data. Disabling the setting deletes the saved archive.

Each browser window owns a separate session record. Saved windows are claimed once as browser windows open, so creating another window cannot duplicate or overwrite a restored window. This release does not automatically create every previously open window. Closing a browser window removes that window's record; quitting preserves the remaining open records. Writes are serialized, debounced, and atomic. The file uses owner-only permissions and is excluded from backups.

Window close explicitly stops requests, detaches script handlers and delegates, clears tab snapshots, and closes private-session registrations. Cleanup does not depend on SwiftUI or WebKit releasing their references first.

Validation covers private and recognized token-bearing URL exclusion, malformed archive rejection, bounded metadata, independent windows, restoring each record once, opt-out erasure, and close/quit ordering. A compiled standalone Swift persistence harness passed these lifecycle checks. Full app and unit test status is recorded with the release validation.
