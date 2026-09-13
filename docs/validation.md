# Release validation

September 13, 2026. Web 0.1.0, macOS, Apple Silicon.

The latest aggregate run passed **65 of 65 tests**. The unsigned Release build also succeeded with `CODE_SIGNING_ALLOWED=NO`.

These are local results. A [GitHub Actions template](ci/README.md) is prepared; hosted CI is not active.

| Test suite | Passed | Coverage |
| --- | ---: | --- |
| AIProviderTests | 12 | Consent, source boundaries, provider requests, local streaming and cancellation |
| SessionStoreTests | 7 | Bounded archives, private exclusion, window lifecycle and restore position |
| TabManagerTests | 7 | Tab updates, private duplication, window cleanup, pinning and bulk close |
| BrowserSecurityTests | 5 | Credential origins, bridge validation and download filenames |
| DownloadResponsePolicyTests | 4 | Attachments, unsupported content and in-browser documents/media |
| DownloadFileLifecycleTests | 8 | Owned staging, collisions, native quarantine and private metadata |
| FileSecurityValidatorTests | 3 | Text attachments, disguised executables and dangerous MIME types |
| QuoteActionTests | 6 | Selected text, source URLs, editable fields, bounds and stale documents |
| PanelPresentationTests | 4 | Window ownership, dismissal and close cleanup |
| PanelWindowIntegrationTests | 4 | Real AppKit windows, native sheets and missing-key-window routing |
| NavigationResolverTests | 3 | Addresses, encoded search queries and rejected schemes |
| PeekGeometryTests | 2 | Corner anchoring and small-screen bounds |

A locally signed build loaded a WebKit page and generated text through MLX without the `allow-jit` entitlement. A fresh local request returned the correct arithmetic result, and Stop interrupted a longer response. Cloud completions and billing reconciliation remain unverified. No credentials were copied or printed.

Installed-build checks passed for normal and private link promotion from Glance, private `target="_blank"` pages, Settings after Glance dismissal, Focus Mode, navigation revealed with `⌘L`, and Copy Quote with its source URL. The command palette focused on open, filtered to the correct action and opened Settings. A native text attachment retained its exact bytes and macOS quarantine attribute. First navigation, same-tab article changes and cross-origin navigation painted without resizing after moving Liquid Glass behind the WebKit content.

The Glance shortcut works with input sent directly to Web, and native global registration succeeds. Activation from a physical keyboard while another app is active remains unverified; app-targeted automation does not exercise the same event path.

The unsigned build verifies compilation. Public distribution still requires a Developer ID signature and notarization.
