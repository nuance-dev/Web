# Release validation

September 13, 2026. Web 0.1.3, macOS, Apple Silicon.

The final Debug aggregate run passed **106 of 106 tests**, with no failures or skips. All 16 release-tool checks also passed.

The new checks cover a reproduced extraction crash: a timeout followed by a late WebKit callback used to resume the same continuation twice. Timeout, cancellation and callback completion now share one completion gate. Page reading happens only on an assistant request. Native WebKit fixtures verify that it excludes forms, editable drafts and hidden content, keeps punctuation, and leaves input, focus and scroll position unchanged. Extraction has a 24,000-character bound, a node limit and a cooperative time budget. The old repeated DOM scans, persistent observers, page globals, scrolling, URL-only cache and responsiveness polling are removed.

Custom API has request-policy tests plus six real loopback transport tests. They verify Unicode, redirect rejection without credential forwarding, socket closure on completion/Stop/revocation, and response limits. No real API key or paid completion was used. Ordinary signing-enabled Debug and Release builds succeeded with ad-hoc signing and no signing team. Release 0.1.3, build 9 was also checked with a sandboxed development signature. Its stripped executable has no local account paths, and its bundled third-party notices match the source file.

In 0.1.2, a new tab accepted a URL immediately after opening. The installed Release showed the local-model loading globe and the request activity globe beside the page card, with the website remaining painted. Gemma 3 1B then answered a question about the attached NASA Saturn page correctly, and the activity indicator returned to idle. Source review confirmed bounded new-tab rendering, cancellation on typing and window deactivation, and the accessibility and Low Power Mode gates. The Appearance animation switch was turned off and restored on. These animation gates have not all been exercised with system settings. The narrow-sidebar check kept Thinking on one line.

In the sandboxed Release used for the walkthroughs, Google's public identifier field accepted text during real local Thinking and cleared during Writing. No blank page or crash recurred, and Next was never submitted. This verifies input responsiveness, not complete Google authentication. Glance loaded Kintsugi, pinned and unpinned, and promoted the page into a separate tab.

The new article-specific local AI check returned the ground observers' first sighting year, 2024, from a recent NASA article. The small 1B model also produced unsupported details and incorrect dates in other prompts. The successful walkthrough is not a model-quality benchmark.

These are local results. A [GitHub Actions template](ci/README.md) is prepared; hosted CI is not active.

| Test suite | Passed | Coverage |
| --- | ---: | --- |
| AIProviderTests | 24 | Consent, source boundaries, named and custom provider requests, endpoint/key isolation, streaming and cancellation |
| CompatibleAPITransportTests | 6 | Real loopback HTTP, credential redirects, Unicode, socket disposal and response bounds |
| PageScriptEvaluationTests | 4 | Timeout, late callbacks, cancellation and exactly one completion |
| PageContentExtractionTests | 3 | Native DOM reading, hidden/editable exclusions, limits and unchanged page state |
| AssistantMarkdownTests | 8 | Block formatting, tables, safe links, inert images and bounded output |
| AssistantMarkdownRendererTests | 3 | Latest-value streaming, immediate completion and canceled views |
| BackgroundNavigationTests | 4 | Native background loads, private storage, view reuse, page timers and link modifiers |
| NativePageContainerTests | 1 | Resizing preserves the configured WebView, coordinator and native clipping |
| SessionStoreTests | 7 | Bounded archives, private exclusion, window lifecycle and restore position |
| TabManagerTests | 7 | Tab updates, private duplication, window cleanup, pinning and bulk close |
| BrowserSecurityTests | 5 | Credential origins, bridge validation and download filenames |
| DownloadResponsePolicyTests | 4 | Attachments, unsupported content and in-browser documents/media |
| DownloadFileLifecycleTests | 8 | Owned staging, collisions, native quarantine and private metadata |
| FileSecurityValidatorTests | 3 | Text attachments, disguised executables and dangerous MIME types |
| PanelPresentationTests | 4 | Window ownership, dismissal and close cleanup |
| PanelWindowIntegrationTests | 4 | Real AppKit windows, native sheets and missing-key-window routing |
| NavigationResolverTests | 3 | Addresses, encoded search queries and rejected schemes |
| PeekGeometryTests | 2 | Corner anchoring and small-screen bounds |
| PageThemeColorTests | 6 | Opaque sRGB colors, invalid pixels, top-edge consensus and page-color fallback |

A locally signed build loaded a WebKit page and generated text through MLX without the `allow-jit` entitlement. A fresh local request returned the correct arithmetic result, and Stop interrupted a longer response. Cloud completions and billing reconciliation remain unverified. No credentials were copied or printed.

Earlier installed-preview checks passed for normal and private link promotion from Glance, private `target="_blank"` pages, Settings after Glance dismissal, Focus Mode and navigation revealed with `⌘L`. Copy Quote was removed in 0.1.3. The command palette focused on open, filtered to the correct action and opened Settings. A native text attachment retained its exact bytes and macOS quarantine attribute. First navigation, same-tab article changes and cross-origin navigation painted without resizing.

Additional installed-app checks:

| Area | Observed result |
| --- | --- |
| Tabs | `⌘S` moved tabs; `⇧⌘S` hid and restored their previous top position. |
| Hidden controls | `⇧⌘B` showed the page alone; `⌘L` revealed the address in its own row above the website; `⇧⌘H` hid only the address bar. |
| Assistant | Opening or closing it in one window left the other window unchanged. The page card showed its title and icon, with one open or close control. Private-page options stated that the page is never shared. |
| Find and commands | `⌘L` followed by `⌘F` focused Find and accepted a search. Help → Commands and Shortcuts opened the palette with the correct keys. |

The shorter welcome places **Summarize this page** above the composer. In the final installed build, native page clipping kept WebKit painted while opening or closing the assistant, switching between top and sidebar tabs, entering Focus Mode, and revealing the address with `⌘L`. Focus Mode hid an open assistant and restored it on exit. Window zoom and restore kept the page fitted to the available height, without a gray gap or reload.

In the final signed Release, Wikipedia remained legible with page matching off (dark controls, light text) and on (white frame and controls, dark text), including top tabs. Navigating to NASA restored a black frame and dark controls. Matching changed the browser frame without changing the webpage's colors.

The Glance shortcut works with input sent directly to Web, and native global registration succeeds. Activation from a physical keyboard while another app is active remains unverified; app-targeted automation does not exercise the same event path.

The final distribution archive has a Developer ID Application signature, hardened runtime and a valid stapled notarization ticket. Gatekeeper accepts it. Signed entitlements match the repository, including sandboxing and outbound networking, with no debug or JIT grants. The same checks passed after ZIP extraction. Those exact ZIP contents are installed locally as 0.1.3, build 9. The sandboxed profile opened correctly, Example Domain stayed painted, and local Gemma 3 1B answered its page-specific question correctly after loading. The whole-bundle review found no local account paths or owner identifiers outside signing certificates; the bundled notices match source. The packaging script and [release guide](releasing.md) preserve these checks for future releases.
