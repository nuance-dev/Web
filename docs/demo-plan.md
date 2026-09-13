# Demo walkthroughs

The Glance and Copy Quote walkthroughs are attached to [PR #26](https://github.com/nuance-dev/Web/pull/26). The updated Focus walkthrough and assistant screenshot are attached to [PR #27](https://github.com/nuance-dev/Web/pull/27). They use captured app states with simple cuts, concise captions and a persistent **Captured app states** label. They are not continuous screen recordings and do not demonstrate animation timing. The native Screenshot recorder repeatedly stalled without saving a recording.

| Clip | Length | Captured states |
| --- | --- | --- |
| [Glance](https://github.com/user-attachments/assets/6658afa4-133c-45d5-ab10-c35ab70a5a21) | 26 seconds | Saturn in Web; Glance input; a Titan link; the loaded panel; pinned panel; Titan promoted to a full tab beside Saturn. |
| [Focus Mode](https://github.com/user-attachments/assets/aa4881b2-547e-4e3c-9e06-9386f4a014d6) | 19 seconds | Saturn with sidebar tabs; tabs moved to the top; Focus Mode; the address field revealed above the page with Command-L. |
| [Copy Quote](https://github.com/user-attachments/assets/dff8d111-215e-4881-ba88-09bce2000da6) | 20 seconds | A selected passage on `example.com`; a close-up of that selection; the passage and source pasted into an untitled TextEdit document. |

Panel and selection close-ups are labeled. No desktop composite, invented cursor movement or simulated app transition appears. The walkthroughs do not show the link context menu or validate the system-wide shortcut.

The inspected frames contain public NASA, Wikipedia and `example.com` pages only. No desktop, menu bar, personal account, local path or credential appears. The exports are silent H.264, 1280 × 900 at 30 fps, each below 1 MB. File metadata is stripped. The README retains the original Web banner. The updated Focus clip and assistant image show the final 0.1.1 build; Glance and Copy Quote retain their earlier walkthroughs.

## Publishing

The README embeds the same hosted clips. Put each `https://github.com/user-attachments/assets/…` URL on a line of its own, with blank lines around it. GitHub supports video in repository Markdown, including READMEs. Its Markdown API renders these three URLs as native video players; public range requests return MP4 content. Check playback and sizing on the published README and PR after updating them. [GitHub video support](https://github.blog/changelog/2021-05-13-video-uploads-now-generally-available/)

GitHub CLI supports inline video attachments through `--attach`. Put `![](./glance.mp4)` in its own paragraph in the body file, then pass `--body-file` and a matching `--attach` flag for each clip. Partial upload failures can still update the PR; inspect before retrying. [CLI instructions](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli)

H.264 MP4 follows GitHub's codec recommendation and the clips fit its free-plan limit. [Attachment guidance](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)

Reuse the hosted walkthroughs in release notes. Ask returning users for a failing page or awkward interaction, with the app version and steps to reproduce it.
