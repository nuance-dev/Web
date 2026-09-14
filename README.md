![Web Experimental](https://github.com/user-attachments/assets/b54a2937-09d5-480a-9ca6-eae7967af30c)

# Web

A native macOS browser with local AI.

[Download for Mac](https://github.com/nuance-dev/Web/releases/latest) · [What's changed](docs/releases/0.1.3.md) · [Build it](#build) · [Report a bug](https://github.com/nuance-dev/Web/issues)

Apple Silicon · macOS 26.5+

## Local AI

Ask about the page with a model running on your Mac.

https://github.com/user-attachments/assets/d046bc3b-9a55-4796-b8e8-ebeb484d435f

## Glance

Press `⌃⌥Space` for a quick lookup in your screen corner. Pin it or open it in a tab.

https://github.com/user-attachments/assets/5ae82570-20ba-4467-bdf9-c459a522bc1f

## Focus Mode

Press `⇧⌘B` for just the page. `⌘L` brings back the address field.

https://github.com/user-attachments/assets/f26f836a-abf8-465e-a6d7-f2afbd0624c4

Captured app states over a macOS wallpaper. [Capture details](docs/demo-plan.md)

## Make room for the page

Keep tabs on the side, on top, or hidden. Find tabs and commands with `⌘K`. Pin what you need and turn on session restore to pick up where you left off.

Use MLX on your Mac, a provider API key, or your own compatible server. Page sharing with an API starts off. Private pages stay excluded. The assistant reads and summarizes pages. [AI providers and privacy](docs/ai-providers.md)

## Preview

Web 0.1.3 is a development preview. Local MLX generation and Stop are verified. Cloud completions and wider browser compatibility need more testing. [Validation](docs/validation.md) · [Security review](docs/security-audit.md) · [Browser gap](docs/product-direction.md)

## Build

macOS 26.5 or later. Apple Silicon. Xcode with the macOS 26.5 SDK and Metal toolchain.

```sh
git clone https://github.com/nuance-dev/Web.git
cd Web
xcodebuild -downloadComponent MetalToolchain
open Web.xcodeproj
```

Run the Web scheme. Local builds use ad-hoc signing; no Apple Developer account is needed. Dependency revisions are pinned.

For a stripped local build, run `./scripts/build-release.sh`. Set `WEB_SIGNING_IDENTITY` to use your own certificate.

```sh
xcodebuild -project Web.xcodeproj -scheme Web \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:WebTests CODE_SIGNING_ALLOWED=NO test
```

<details>
<summary>Keyboard shortcuts</summary>

| Action | Shortcut |
| --- | --- |
| Glance | `⌃⌥Space` (change in Settings) |
| Commands | `⌘K` |
| New tab | `⌘T` |
| Private tab | `⇧⌘N` |
| Close / reopen tab | `⌘W` / `⇧⌘T` |
| Address | `⌘L` |
| Move tabs between sidebar and top | `⌘S` |
| Show / hide tabs | `⇧⌘S` |
| Show / hide address bar | `⇧⌘H` |
| Focus Mode | `⇧⌘B` |
| Find | `⌘F` |
| Bookmark page | `⌘D` |
| Next / previous tab | `⌃Tab` / `⇧⌃Tab` |
| History | `⌘Y` |
| Downloads | `⇧⌘J` |
| Assistant | `⇧⌘A` |

</details>

Built with SwiftUI, WebKit and [MLX](https://github.com/ml-explore/mlx-swift). [Credits](CREDITS.md) · [MIT license](LICENSE).
