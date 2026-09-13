# CI template

[build.yml](build.yml) is prepared for GitHub Actions but is not active. Its hosted runner has not been tested.

To enable it, copy the file to `.github/workflows/build.yml` and push with credentials authorized to update workflows. Keep the pinned action revision and verify the selected Xcode image when enabling it.

All 65 tests passed locally. Run the same suite with:

```sh
xcodebuild -project Web.xcodeproj -scheme Web \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:WebTests CODE_SIGNING_ALLOWED=NO test
```
