# Browser design review

The browser uses one outer Liquid Glass surface. The page meets the chrome without a second inset frame. Navigation and footer controls stay plain at rest; the address field gains a surface when focused.

| Before | After | Why |
| --- | --- | --- |
| Separate navigation, address and footer pills | One continuous idle surface with local hover feedback | Keep the page visually connected to the window. |
| Window buttons squeezed into the tab rail beside a different-height toolbar | Native macOS buttons in one 36-point row above the rail and page | Give the corner one consistent alignment. |
| Wide horizontal padding and nested page corners | One shared toolbar and no inner page clipping | Use space for the page. |
| Small selected-tab square and an accent stripe | A 48-point sidebar, 40 × 36-point tab targets, 2-point gaps and a full selected-tab surface | Keep selection clear without a stripe. |
| Hover-only close icons | Visible 24 × 26-point close targets in the 36-point top tab strip | Keyboard users should not have to reveal a control. |
| Green filled lock | Neutral HTTPS lock with a 24-point target | HTTPS describes the connection, not the site's trustworthiness. |
| Mock recent pages and decorative loading loops | Saved pages, local recents and one loading strip | Show useful state with little motion. |
| URL fields with separate parsers | Shared address handling and explicit editing state | Pasting and searching should behave consistently. |
| Panels followed the key window | Each window owns its panels; menu routing handles sheets and missing key windows | Settings stays in the window that opened it. |
| Quick link checks created permanent tabs | Open in Glance, with an explicit move to a full tab | Keep the source page in place. |
| Copying a passage and its source took two steps | Copy Quote | Copy selected text with its page link. |

Navigation targets are 28 × 28 points. Sidebar footer targets are 44 × 28 points, without a shared pill. Missing site icons use a vector globe. Standard controls stay visible. Hover feedback changes only the local control; keyboard tab changes do not animate. Reduced Motion disables custom movement.

The View menu offers **Tabs → Sidebar / Top / Hidden**, **Show Address Bar** (`⇧⌘H`) and **Focus Mode** (`⇧⌘B`). `⌘L` reveals the address field when chrome is hidden. Window controls remain reachable through the floating bar.

The start page shows up to six saved pages and four recent hosts, using local records and cached icons. Private tabs hide recents. Native colors and Liquid Glass supply appearance changes; private reference images stay outside the repository.

Build results and completed live checks are recorded in [validation](validation.md). Light/dark contrast, keyboard focus and compact layouts still need wider accessibility coverage.
