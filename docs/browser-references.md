# Browser references

GitHub stars checked on September 13, 2026 through each repository's API. These are useful projects to study, not a security ranking. The recommendations below are proposals for Web; existing priorities remain in [product direction](product-direction.md).

| Project | Stars | What Web can borrow | What would cost too much |
| --- | ---: | --- | --- |
| [Zen](https://github.com/zen-browser/desktop) | [44,427](https://api.github.com/repos/zen-browser/desktop) | [Compact Mode](https://docs.zen-browser.app/user-manual/compact-mode) provides keyboard controls to reveal hidden navigation. Make Web's existing Focus controls just as discoverable. | A large set of toolbar modes, workspaces and Firefox patches. |
| [Ladybird](https://github.com/LadybirdBrowser/ladybird) | [66,179](https://api.github.com/repos/LadybirdBrowser/ladybird) | Its [issue guide](https://github.com/LadybirdBrowser/ladybird/blob/master/ISSUES.md) teaches reduced HTML test cases. Add small, public fixtures for Web-specific navigation and popup bugs. | An independent rendering engine. Keep WebKit and distinguish app bugs from engine bugs. |
| [Helium](https://github.com/imputnet/helium) | [20,620](https://api.github.com/repos/imputnet/helium) | A short download path, explicit beta status and direct platform release links. Once Web passes its distribution gate, offer one obvious macOS download with its requirements beside it. | Maintaining a Chromium fork and several platform packaging pipelines. |
| [Floorp](https://github.com/Floorp-Projects/Floorp) | [8,373](https://api.github.com/repos/Floorp-Projects/Floorp) | Its [onboarding](https://floorp.app/) offers import without an account. Help people bring saved pages into Web. | Four-way split view, persistent web panels and another notes app. Each adds state and testing combinations. |
| [Min](https://github.com/minbrowser/min) | [9,179](https://api.github.com/repos/minbrowser/min) | Its README gives users a short getting-started path and contributors an architecture guide. Put Web's keyboard reference within reach of the app. | Persistent full-text indexing of visited pages. Web's bounded history metadata is a smaller privacy and storage commitment. |

## Two small next steps

1. **Keyboard help, implemented.** Help → Commands and Shortcuts opens the existing command palette in the active window. It now includes Find, Focus Mode, tab placement, address-bar visibility and Close Tab, with their menu shortcuts. Assistant and Downloads also show their shortcuts. `⌘L` reveals the address field; `⌘K` opens the palette.
2. **Bookmark transfer, proposed.** Add explicit HTML import and export using native file panels. Bound file size and entry count, accept only HTTP(S) URLs, deduplicate exact URLs, and show the imported count. Start with flat bookmarks; keep folders and browser-profile migration out of this pass. Test malformed files and round trips.

Zen already names its [in-tab preview Glance](https://docs.zen-browser.app/user-manual/glance). Describe Web's Glance through its specific interaction: summon a corner browser while working in another app. Avoid claiming the name or preview concept is new.

Borrow interaction ideas. Review licenses before reusing code or assets.
