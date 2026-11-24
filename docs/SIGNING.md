# Signing and iCloud provisioning

One App ID and one iCloud container serve every platform:

| Item | Value |
| --- | --- |
| Team | `M9K2GT5S6F` |
| App ID (macOS + iOS/iPadOS) | `com.aditya.pdflibrary` |
| iCloud container | `iCloud.com.aditya.pdflibrary` (CloudKit, private database only) |
| Capabilities | iCloud (CloudKit), Push Notifications (CloudKit change pushes) |

## One-time Apple Developer setup

These portal steps change the developer account and are not reversible (iCloud containers can't be deleted), so they are done by the owner, not by automation.

1. In Certificates, Identifiers & Profiles → Identifiers, add the App ID `com.aditya.pdflibrary` (explicit). Enable **iCloud** (CloudKit support) and **Push Notifications**. Tick "Mac" under platform support if offered, so one ID covers macOS and iOS.
2. Identifiers → iCloud Containers: add `iCloud.com.aditya.pdflibrary`, then assign it to the App ID's iCloud capability.
3. Register the iPhone and iPad under Devices (Xcode does this when they are first connected with "Automatically manage signing").
4. Open `PDFLibrary.xcodeproj` (regenerate with `xcodegen generate`), select each target, Signing & Capabilities → Team `M9K2GT5S6F`. Xcode then creates development profiles for the Mac and the devices.
5. Run the app once on a signed build, then in the [CloudKit Console](https://icloud.developer.apple.com/) open the container's **Development** environment and confirm the `Document`, `PDFFile` and `Position` record types exist (see CLOUDKIT.md). Before any TestFlight/App Store build, **Deploy Schema Changes** to Production.

## Builds

Signed (needs the setup above):

```sh
xcodegen generate
xcodebuild -project PDFLibrary.xcodeproj -scheme PDFLibraryMac -destination 'platform=macOS' -allowProvisioningUpdates build
xcodebuild -project PDFLibrary.xcodeproj -scheme PDFLibraryiOS -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Unsigned (CI, machines without the team): entitlements are not embedded, so also turn sync off. The app then runs as a local-only library.

```sh
xcodebuild -project PDFLibrary.xcodeproj -scheme PDFLibraryMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO PDFL_CLOUD_SYNC=NO build
xcodebuild -project PDFLibrary.xcodeproj -scheme PDFLibraryiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO PDFL_CLOUD_SYNC=NO build
```

`PDFL_CLOUD_SYNC` becomes the `PDFLCloudSync` Info.plist key. With `NO`, the app never touches CloudKit (creating a `CKContainer` without the entitlement would crash).

Push: the entitlements use `aps-environment = development`. Archive/export for TestFlight switches it to production automatically.
