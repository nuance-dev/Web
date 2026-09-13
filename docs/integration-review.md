# Browser integration review

Private-tab commands now reach the active browser window. The private-session service no longer creates invisible tabs. Cmd-click, link context menus and links that request a new window keep the source tab's private state and destination window. Form submissions keep their original request instead of becoming a GET request.

Closing a window disposes its pages and removes its private-session entries. The last private tab replaces the temporary website store. Closing a tab also removes any hibernation snapshot held by the shared service.

Waking a tab uses the same configured WebView as normal browsing. It no longer starts a separate page load without browser delegates. Snapshot callbacks check that the tab still owns the view and has not become active before releasing it. Page zoom follows the tab through duplication and session restoration.

`TabManagerTests` covers private duplication and session exclusion, window-close cleanup, pinned tabs during bulk closure, duplicate cleanup and invalid tab selection. The tests use isolated session files and preferences, and do not load websites. Aggregate build and test results belong in the release validation.

Live checks confirmed private `target="_blank"` pages and normal/private Glance promotion into the source window. Runtime checks still need to exercise private links across multiple windows, Glance promotion after the last browser window closes, and hibernation around complex forms or playing media. Hibernation's existing page-state heuristics do not provide complete form or media restoration.
