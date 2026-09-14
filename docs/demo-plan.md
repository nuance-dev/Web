# Demo walkthroughs

These walkthroughs show Web 0.1.3, build 9. They use real app-window captures over Apple's Monterey wallpaper, with short cuts and a small “Captured app states” label.

| Clip | Site | What it shows |
| --- | --- | --- |
| Local AI · 9s | NASA Science | A recent Hubble article, a question about the first ground-based sighting, and Gemma 3 1B’s actual answer: 2024. |
| Glance · 7s | Wikipedia | Kintsugi in a corner card, then opened in a full tab. |
| Focus · 7s | Apple | A MacBook Pro page with controls, the page alone, and the address brought back above it. |

The shorter holds replace the older, slower clips. They do not demonstrate generation speed or continuous animation. No model output, app transition or cursor movement is invented. Glance is opened while Web is active; this does not establish physical shortcut behavior in other apps.

The presentation adds wallpaper, outer shadows and small captions. Glance’s exterior matte is trimmed to match its native 16-point corner radius. No second border is added.

The exports contain public pages and omit the personal desktop, menu bar, accounts, local paths and credentials. They are silent H.264 MP4 files at 1280 × 900, 30 fps, with file metadata stripped. The capture manifest records source and export hashes. The original Web banner stays.

## Publishing

The README and PR embed the same three hosted clips, with Local AI first. Put each hosted attachment URL in its own paragraph. GitHub supports video in repository Markdown, including READMEs. [GitHub video support](https://github.blog/changelog/2021-05-13-video-uploads-now-generally-available/)

GitHub CLI accepts inline attachments with `--attach`. Use `![](./local-ai.mp4)` in the body file and pass a matching attachment flag. An upload failure can still update the PR, so inspect before retrying. [CLI instructions](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli)

H.264 MP4 follows GitHub's codec recommendation. Keep each clip within its attachment limit. [Attachment guidance](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)
