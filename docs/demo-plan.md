# Demo walkthroughs

Three MP4 walkthroughs are attached to [PR #26](https://github.com/nuance-dev/Web/pull/26). They use captured app states with simple cuts, concise captions and a persistent **Captured app states** label. They are not continuous screen recordings and do not demonstrate animation timing. The native Screenshot recorder repeatedly stalled without saving a recording.

| Clip | Length | Captured states |
| --- | --- | --- |
| Glance | 26 seconds | Saturn in Web; Glance input; a Titan link; the loaded panel; pinned panel; Titan promoted to a full tab beside Saturn. |
| Focus Mode | 20 seconds | Titan with browser controls; Focus Mode; the address field revealed with Command-L; the page again. |
| Copy Quote | 20 seconds | A selected passage on `example.com`; a close-up of that selection; the passage and source pasted into an untitled TextEdit document. |

Panel and selection close-ups are labeled. No desktop composite, invented cursor movement or simulated app transition appears. The walkthroughs do not show the link context menu or validate the system-wide shortcut.

The inspected frames contain public Wikipedia and `example.com` pages only. No desktop, menu bar, personal account, local path or credential appears. The exports are silent H.264, 1280 × 900 at 30 fps, each below 1 MB. File metadata is stripped. The README now uses an actual Glance screenshot.

## Publishing

GitHub CLI supports inline video attachments through `--attach`. Put `![](./glance.mp4)` in its own paragraph in the body file, then pass `--body-file` and a matching `--attach` flag for each clip. Partial upload failures can still update the PR; inspect before retrying. [CLI instructions](https://docs.github.com/en/github-cli/github-cli/attaching-files-with-github-cli)

H.264 MP4 follows GitHub's codec recommendation and the clips fit its free-plan limit. [Attachment guidance](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)

Reuse the hosted walkthroughs in release notes. Ask returning users for a failing page or awkward interaction, with the app version and steps to reproduce it.
