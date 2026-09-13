![Web — Experimental](https://github.com/user-attachments/assets/b54a2937-09d5-480a-9ca6-eae7967af30c)

# Web

A small native browser for macOS.

[What's changed](docs/releases/0.1.1.md) · [Build it](#build) · [Report a bug](https://github.com/nuance-dev/Web/issues)

## A quick look

Short walkthroughs assembled from captured app states. [Capture details](docs/demo-plan.md)

### Glance

Press `⌃⌥Space`. Look something up in your screen corner, pin it, or move it into a tab. Closing Glance clears its temporary session.

https://github.com/user-attachments/assets/6658afa4-133c-45d5-ab10-c35ab70a5a21

### Focus Mode

Press `⇧⌘B` for just the page. `⌘L` brings back the address field.

https://github.com/user-attachments/assets/aa4881b2-547e-4e3c-9e06-9386f4a014d6

### Copy Quote

Select a passage and choose **Copy Quote**. Paste the words and their source together.

https://github.com/user-attachments/assets/dff8d111-215e-4881-ba88-09bce2000da6

## Make room for the page

Keep tabs on the side, on top, or hidden. Find tabs and commands with `⌘K`. Pin what you need, remove duplicates, and turn on session restore if you want to pick up where you left off.

Private tabs use separate temporary storage. AI runs locally with MLX, or with your own OpenAI, Anthropic or Gemini API key. Cloud page sharing starts off. The assistant can read and summarize; it cannot click, type or submit forms. [AI providers and privacy](docs/ai-providers.md)

## Preview

Web 0.1.1 is a development preview. Local MLX generation and Stop are verified; cloud completions and wider browser compatibility need more testing. [Validation](docs/validation.md) · [Security review](docs/security-audit.md) · [Browser gap](docs/product-direction.md)

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
