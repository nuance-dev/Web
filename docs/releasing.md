# Releasing Web

Public downloads need a Developer ID Application signature, hardened runtime and notarization. Ad-hoc and Apple Development builds are for local use. Build from the exact commit you intend to tag, with the version and build number set in Xcode.

## Validate and archive

Run from the repository root with Xcode and Python 3.9 or newer installed:

```sh
python3 -m unittest discover -s scripts/tests
xcodebuild -project Web.xcodeproj -scheme Web \
  -destination 'platform=macOS,arch=arm64' -only-testing:WebTests \
  CODE_SIGNING_ALLOWED=NO test

umask 077
mkdir -p dist
xcodebuild -project Web.xcodeproj -scheme Web -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath dist/DerivedData \
  -archivePath dist/Web.xcarchive ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGN_ENTITLEMENTS=Web/Web.entitlements archive > dist/archive.log 2>&1

python3 scripts/package-notarized.py \
  dist/Web.xcarchive/Products/Applications/Web.app --check-archive
```

The archive check verifies the signature, sandbox entitlements, bundled license notices and local account paths. It creates no package. If it finds paths in the executable, strip that archived executable, restore its ad-hoc signature and repeat the check:

```sh
xcrun strip -S -x dist/Web.xcarchive/Products/Applications/Web.app/Contents/MacOS/Web
codesign --force --options runtime --timestamp=none --sign - \
  --entitlements Web/Web.entitlements dist/Web.xcarchive/Products/Applications/Web.app
```

Resolve any remaining failure before submission. Keep `dist/` private and untracked; build and distribution logs can contain account details.

## Sign and notarize

Use an enrolled account already signed into Xcode with permission to distribute the app. Create `dist/ExportOptions.plist` locally, replacing the team placeholder:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>YOUR_TEAM_ID</string>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
```

```sh
xcodebuild -exportArchive -archivePath dist/Web.xcarchive \
  -exportOptionsPlist dist/ExportOptions.plist -exportPath dist/notary-upload \
  -allowProvisioningUpdates > dist/submit.log 2>&1

xcodebuild -exportNotarizedApp -archivePath dist/Web.xcarchive \
  -exportPath dist/notarized > dist/export.log 2>&1
```

Wait for a successful notarization before exporting. Automatic provisioning may create or update managed signing certificates and profiles. A missing local Developer ID certificate does not rule out [Xcode cloud signing](https://developer.apple.com/help/account/certificates/cloud-managed-certificates). Xcode Organizer → Distribute App → Developer ID → Upload is the [documented interactive route](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Stop on account or permission errors; do not substitute a development signature.

## Package and check the download

```sh
python3 scripts/package-notarized.py dist/notarized/Web.app
```

The script checks Developer ID signing, timestamp, hardened runtime, the repository entitlements, notarization ticket and Gatekeeper. It requires the bundled `ThirdPartyNotices.txt` to match source and scans all regular bundle files for home-directory paths. It repeats these checks after copying and after ZIP extraction. `--entitlements` and `--notices` can point to files from the exact release checkout.

The output is `dist/Web-VERSION-arm64.zip` and its SHA256 file. Extract that ZIP and run the app before publishing. Confirm its version/build, browser navigation, local AI, downloads and sandboxed settings. Review package metadata for personal identifiers; signing certificates contain the publisher's identity.

Publish only the reviewed ZIP, checksum and release notes against the tested tag. The scripts do not upload releases or manage GitHub authentication. See Apple's [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) for command details and ticket handling.
