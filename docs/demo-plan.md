# Demo walkthroughs

These walkthroughs show Web 0.1.2. Each uses real app-window captures over Apple's Monterey wallpaper, with simple cuts and a small "Captured app states" label. The local AI response came from Gemma 3 1B running on the Mac with the NASA page included.

| Clip | Length | Captured states |
| --- | --- | --- |
| [Local AI](https://github.com/user-attachments/assets/a202d65b-1b71-4172-893c-b9ad4c48fdef) | 15 seconds | A question about Saturn's composition, the thinking indicator, and the model's actual answer. |
| [Glance](https://github.com/user-attachments/assets/21e4742f-c9a8-48cf-8f10-85eb5b77b610) | 20 seconds | An empty search field, a Titan link, the loaded page, the pinned panel, and Titan opened as a full tab beside Saturn. |
| [Focus](https://github.com/user-attachments/assets/7c664b7c-f568-4448-a2eb-2dd914607d29) | 15 seconds | Saturn with browser controls, Focus Mode, the address field above the page, and a return to the page. |
| [Copy Quote](https://github.com/user-attachments/assets/41588056-cba6-4f81-b521-74aa68ee0c6c) | 13 seconds | A selected passage on `example.com` and the actual quotation and source pasted into a plain TextEdit document. |

The videos show cuts between captured states, so they do not demonstrate animation timing or generation speed. We attempted a native screen recording again; the Screenshot app timed out without exposing recorder controls. No app transition, cursor movement or model output was invented. Copy Quote was chosen from the page context menu; that menu is not shown in the clip. Glance was opened with its shortcut while Web was active, which does not establish behavior in other apps.

Full browser windows retain their native 1152 × 768 capture size. Glance keeps its input and page sizes, anchored at the bottom right. The TextEdit window is scaled uniformly for readability. The presentation adds only the wallpaper, outer window shadows, corner masks and footer captions.

The reviewed captures contain public NASA and `example.com` content. The exports omit the personal desktop, menu bar, accounts, local paths and credentials. They are silent H.264 MP4 files, 1280 × 900 at 30 fps, with file metadata stripped. The capture manifest records source and export hashes. The README retains the original Web banner.

## Publishing

The README and PR embed the same four hosted clips, with Local AI first. Put each `https://github.com/user-attachments/assets/…` URL in its own paragraph. GitHub supports video in repository Markdown, including READMEs. Check the native players and playback after publishing. [GitHub video support](https://github.blog/changelog/2021-05-13-video-uploads-now-generally-available/)

GitHub CLI accepts inline attachments with `--attach`. Use `![](./local-ai.mp4)` in the body file and pass a matching attachment flag for each clip. An upload failure can still update the PR, so inspect before retrying. [CLI instructions](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli)

H.264 MP4 follows GitHub's codec recommendation. Keep each clip within its attachment limit. [Attachment guidance](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)
