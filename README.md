![Web Experimental](https://github.com/user-attachments/assets/b54a2937-09d5-480a-9ca6-eae7967af30c)

# Web

A native macOS browser with local AI.

[What's changed](docs/releases/0.1.2.md) · [Build it](#build) · [Report a bug](https://github.com/nuance-dev/Web/issues)

## Local AI

Ask about the page with a model running on your Mac.

https://github.com/user-attachments/assets/a202d65b-1b71-4172-893c-b9ad4c48fdef

## Glance

Press `⌃⌥Space` for a quick lookup in your screen corner. Pin it or open it in a tab.

https://github.com/user-attachments/assets/21e4742f-c9a8-48cf-8f10-85eb5b77b610

## Focus Mode

Press `⇧⌘B` for just the page. `⌘L` brings back the address field.

https://github.com/user-attachments/assets/7c664b7c-f568-4448-a2eb-2dd914607d29

## Copy Quote

Select a passage. Copy the words and their source together.

https://github.com/user-attachments/assets/41588056-cba6-4f81-b521-74aa68ee0c6c

Captured app states over a macOS wallpaper. [Capture details](docs/demo-plan.md)

## Make room for the page

Keep tabs on the side, on top, or hidden. Find tabs and commands with `⌘K`. Pin what you need and turn on session restore to pick up where you left off.

The assistant uses MLX locally or your own OpenAI, Anthropic or Gemini API key. Cloud page sharing starts off. Private pages stay excluded. The assistant can read and summarize; it cannot click, type or submit forms. [AI providers and privacy](docs/ai-providers.md)

## Preview

Web 0.1.2 is a development preview. Local MLX generation and Stop are verified. Cloud completions and wider browser compatibility need more testing. [Validation](docs/validation.md) · [Security review](docs/security-audit.md) · [Browser gap](docs/product-direction.md)

## Build

macOS 26.5 or later. Apple Silicon. Xcode 26 with the Metal toolchain.

```sh
git clone https://github.com/nuance-dev/Web.git
cd Web
xcodebuild -downloadComponent MetalToolchain
open Web.xcodeproj
```

Choose your signing team locally, then run the Web scheme. The repository does not include a signing identity. Dependency revisions are pinned.

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

Built with SwiftUI, WebKit and [MLX](https://github.com/ml-explore/mlx-swift). [MIT license](LICENSE).
