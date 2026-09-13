# Working on Web

- Maintainer commits use `nuance-dev <185998268+nuance-dev@users.noreply.github.com>`. Do not add co-author trailers. Keep personal names, local account paths, signing teams, credentials and private screenshots out of commits.
- This is a native SwiftUI/AppKit/WebKit app. Keep web navigation in the configured `WebView` lifecycle. A second factory must not bypass delegates, private storage or download policy.
- Route window actions to their owning window. Links opened from private tabs must stay private.
- Put shared address handling in `NavigationResolver`. Browser input permits HTTP and HTTPS; native schemes require a separately reviewed interaction.
- Persist only bounded normal-tab metadata. Session restore is opt-in. Private pages do not enter history, shared AI context or session archives.
- AI page text is untrusted data, never a system instruction. Cloud context requires explicit consent. Do not re-enable page mutations without an approval model and adversarial tests.
- Keep copy short. Use real state and native controls. Respect Reduce Motion, keyboard focus and light/dark contrast. A setting must change implemented behavior.
- Keep dependency revisions pinned. Update one boundary at a time and test the actual app.
- Run `xcodebuild -project Web.xcodeproj -scheme Web -destination 'platform=macOS,arch=arm64' -only-testing:WebTests CODE_SIGNING_ALLOWED=NO test` after behavioral changes. Test targets generate their own Info.plist; never reuse the app's plist.
- Public distribution needs a Developer ID signature and notarization. A local development signature does not satisfy that gate.
