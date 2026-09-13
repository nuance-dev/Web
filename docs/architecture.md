# Architecture

Web uses SwiftUI for the app, AppKit for windows and shortcuts, and WebKit for pages. The current work removes competing paths instead of adding another framework.

| Boundary | Owner |
| --- | --- |
| Window lifecycle | `BrowserView`, `BrowserWindowBridge`, `TabManager` |
| Page lifecycle | `WebView`, `Tab`, `TabHibernationManager` |
| User-entered addresses | `NavigationResolver` |
| Temporary corner browser | `PeekController`, `PeekView` |
| Session metadata | `SessionStore` |
| AI transport and consent | Provider adapters, `AIContextPolicy`, provider settings |
| Origin and filename policy | `BrowserSecurityPolicy` |

Each browser window owns a tab manager. Menu notifications are scoped to the active window; links carry their source tab. Normal tab switches reuse the same WebKit view and delegate. Closing a window explicitly disposes its pages, because WebKit script handlers can retain their owners beyond SwiftUI's view lifetime.

Glance has its own nonpersistent WebKit store and no native page bridge. Expanding to Web opens a normal tab by URL; cookies and in-page state are not transferred. Closing Glance releases the temporary page. Global shortcut registration happens after application launch.

Session persistence runs on a serial queue. Windows own separate records, writes are atomic and debounced, and decoded data is validated again. Private pages and recognized sign-in callback URLs are excluded. The archive contains URLs, titles, pin state and zoom, not page contents or forms.

The assistant is read-only. A provider change clears the conversation. Source content is bounded and kept out of system instructions. Remote page sharing needs current explicit consent; adding a key alone does not select a cloud provider.

## Remaining work

The legacy app still has global services and a notification-based command layer. A typed per-window command interface would make future features easier to reason about. The MLX runtime is pinned, not fully modernized. Hibernation cannot promise preservation of arbitrary forms or in-page application state. These deserve focused follow-up work with compatibility fixtures.

Keep the release gates in [the browser gap](product-direction.md) visible. A successful build is necessary, but it does not establish production browser compatibility.
