# Contributing to Web

Web is a native macOS browser in development preview. Reproducible bug reports, keyboard and VoiceOver checks, and small fixes are useful contributions. You do not need to write Swift to help.

[Report a bug or suggest a change](https://github.com/nuance-dev/Web/issues/new/choose) · [Report a vulnerability privately](https://github.com/nuance-dev/Web/security/advisories/new)

## Start small

Search existing issues first. A report should explain what you tried, what happened, and what you expected. For a broken website, include a public example if possible and whether Safari on the same Mac behaves differently. Remove account details, private URLs and credentials from attachments.

Small fixes can go straight to a pull request. For larger features, describe the problem in an issue before investing in the implementation. The [product direction](docs/product-direction.md) explains the current scope and browser gaps.

Useful places to start:

| Try this | What to report |
| --- | --- |
| Use Glance on a second display | Corner placement, focus and dismissal |
| Navigate with the keyboard or VoiceOver | The control you cannot reach or identify |
| Open a page that fails in Web | Minimal steps and the Safari result |
| Build from a clean checkout | The first failing step and a redacted error |

## Build and test

Use Apple Silicon, macOS 26.5 or later, and Xcode 26 with the macOS 26.5 SDK or later. Install the Metal toolchain once:

```sh
xcodebuild -downloadComponent MetalToolchain
open Web.xcodeproj
```

Run the **Web** scheme. Local builds use ad-hoc signing and do not need an Apple Developer account. Keep any signing overrides local. Swift packages use the checked-in dependency revisions. The [README](README.md#build) has cloning and release-build instructions.

After a behavior change, run the app and the unit tests:

```sh
xcodebuild -project Web.xcodeproj -scheme Web \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:WebTests CODE_SIGNING_ALLOWED=NO test
```

The unit tests do not require an API key. For UI changes, check light and dark appearance, keyboard focus, and Reduce Motion. For window or navigation changes, also check a second window and a private tab. Describe anything you could not test.

For build-script changes, run `python3 -m unittest discover -s scripts/tests`. These checks cover local signing and rejection of source paths in the executable without using a certificate.

## Find the code

| Area | Start here |
| --- | --- |
| Browser chrome | `Web/Views/Components/` |
| Tabs and restoration | `Web/ViewModels/TabManager.swift`, `Web/Services/SessionStore.swift` |
| WebKit navigation | `Web/Views/Components/WebView.swift` |
| Glance | `Web/Services/PeekController.swift`, `Web/Views/Components/PeekView.swift` |
| Assistant and providers | `Web/AI/` |
| Regression tests | `WebTests/` |

## Send a pull request

Keep one clear problem per pull request. Explain the resulting behavior, link the issue if there is one, and include the checks you ran. A screenshot or short recording helps for visual changes. Add a regression test when it protects behavior that could break again; documentation and simple visual changes do not need artificial tests.

Review every change, including code written with AI tools. Keep credentials, signing identities, personal file paths and browsing data out of the diff. Read [AGENTS.md](AGENTS.md) for browser and privacy constraints, and [SECURITY.md](SECURITY.md) before reporting a vulnerability.

Keep feedback specific and respectful. An open issue or pull request is not a release commitment; review and release dates are not guaranteed.
