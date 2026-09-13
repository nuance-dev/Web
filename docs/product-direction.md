# Web, with Glance

Web stays the name. Glance opens a page in the screen corner so a quick lookup does not need a permanent tab.

## What earns a place

| Keep | Why |
| --- | --- |
| Glance | A small browser for the task you are doing elsewhere. |
| Native tabs and keyboard navigation | Everyday browsing must feel predictable. |
| Local AI, optional API providers | Users choose where their page content goes. |
| Bookmarks, history, downloads | Small, dependable tools for finding and keeping things. |
| Private browsing | A separate temporary session, with clear limits. |
| Opt-in session restore | Reopen normal tabs without saving page text or private tabs. |

| Cut or withhold | Why |
| --- | --- |
| Unattended AI page actions | The old implementation could click and type without reliable approval. |
| Decorative loading effects | They consume attention without helping navigation. |
| Settings that do nothing | A toggle should change real behavior. |
| Provider model guessing and silent fallbacks | A failed request should not turn into surprise paid requests. |

## Browser gap

This release is a development preview. Session restore is implemented: it saves bounded normal-tab metadata, keeps each window's record separate, and deletes the archive when disabled. Saved records reopen as browser windows are created; Web does not recreate every previous window automatically. [Session behavior](sessions.md)

| Area | Web's next gate |
| --- | --- |
| Session reliability | Exercise crash recovery and long sessions; add full window recreation only after those paths are reliable. |
| Hibernation | Protect unfinished forms and media before claiming complete page restoration. |
| Profiles | Separate cookies, storage, history and permissions before adding a profile picker. |
| Extensions | Evaluate a supported extension architecture before promising compatibility. |
| Downloads | Test interruption, resume, redirects, duplicate filenames and quarantine on real servers. |
| Passwords | Prefer established system tools until an explicit, audited autofill flow is complete. |
| Updates | Signed and notarized distribution with a tested update mechanism. |
| Accessibility | Keyboard and VoiceOver checks across the full app, including web content. |
| Compatibility | Ongoing tests for login, uploads, PDFs, media, popups and enterprise sites. |
| AI actions | Transaction previews, origin-bound approvals, cancellation and an independent security review. |

## Reference decisions

[Dia](https://www.diabrowser.com/changelog/mac) puts tab context and reusable skills close to browsing. Web adopts short, explicit page actions first. Integrations need a real permission model.

[Safari profiles](https://support.apple.com/en-ie/105100) separate browsing contexts. Web needs storage isolation before adding this UI.

[Chrome's split view](https://blog.google/products-and-platforms/products/chrome/chrome-productivity-improvements/) addresses comparison across pages. Glance addresses a different moment: briefly opening the web while working in another app.

## Bring people back

Lead with a short screen recording: summon Glance, search YouTube, open the result, dismiss. Show the interaction before the feature list.

Publish a compact release note with real screenshots and the preview's limits. Ask for bug reports with the macOS version and steps. Keep a public compatibility list and ship small fixes against it.
