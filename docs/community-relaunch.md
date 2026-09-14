# Returning to Web

[Web 0.1.3](https://github.com/nuance-dev/Web/releases/tag/v0.1.3) replaces the August 2025 download with a signed, notarized preview. The README, release and PR now show the same app: article-specific local AI, Glance and Focus, each on a different site. The original banner stays. [Release checks](releasing.md)

## Reports with a result

The release resolves Custom API support [#7](https://github.com/nuance-dev/Web/issues/7), the reported Google input and AI responsiveness symptoms [#14](https://github.com/nuance-dev/Web/issues/14), and local build signing [#20](https://github.com/nuance-dev/Web/issues/20). Each report includes the checks and their limits. Focus Mode [#18](https://github.com/nuance-dev/Web/issues/18) and the old assistant-loading behavior [#12](https://github.com/nuance-dev/Web/issues/12) were also resolved.

Platform and naming decisions are recorded separately from fixes. The unspecified app failure in [#21](https://github.com/nuance-dev/Web/issues/21) stays open for reproduction.

## Small ways to help

Three `help wanted` issues have starting points and checkable results:

| Check | Useful evidence |
| --- | --- |
| [Glance with VoiceOver](https://github.com/nuance-dev/Web/issues/30) | Whether its shortcut interferes with activating a focused control. |
| [Glance on two displays](https://github.com/nuance-dev/Web/issues/31) | Placement after scaling changes and disconnecting a display. |
| [Custom API with Ollama](https://github.com/nuance-dev/Web/issues/32) | Real engine inference, cancellation, consent and error handling. |

The [contribution guide](../CONTRIBUTING.md) and [issue forms](https://github.com/nuance-dev/Web/issues/new/choose) cover setup and reporting. Label testing requests `help wanted`; reserve `good first issue` for a small fix with a known starting point. [GitHub's label guidance](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/encouraging-helpful-contributions-to-your-project-with-labels)

Credits in the README, PR and release link the libraries and visual references behind the work. [Full credits](../CREDITS.md)

## Unpublished announcement draft

Web has a new preview: local AI for the page you're reading, quick lookups in Glance, and controls that can disappear. [Watch the demos and try it](https://github.com/nuance-dev/Web/releases/tag/v0.1.3). A public page that breaks or an awkward keyboard step helps decide what to fix next. [Report a bug](https://github.com/nuance-dev/Web/issues/new/choose)
