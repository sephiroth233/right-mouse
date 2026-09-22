# Native build configuration

`Base.xcconfig` sets macOS 14 as the minimum deployment target. Copy `Local.xcconfig.example` to `Local.xcconfig` and provide your real developer team and registered App Group before testing a signed Finder extension. The default App Group is a placeholder, not proof of entitlement or runtime access.

Run `python3 Config/generate-project.py` after adding Swift files. This generates the host, Finder extension and core unit-test targets, plus the shared `RightMouse` scheme. The root Swift package provides `RightMouseCore`. With full Xcode selected, use:

```sh
xcodebuild -project RightMouse.xcodeproj -scheme RightMouse -configuration Debug build
xcodebuild -project RightMouse.xcodeproj -scheme RightMouse -configuration Debug test
```

The project and scheme have been structurally parsed in the Command Line Tools environment. Full `xcodebuild` and XCTest execution require a complete Xcode installation and remain separate verification steps.

## Command Line Tools development bundle

```sh
scripts/build-app.sh
scripts/package-app.sh --development
```

The default output is `.build/native/RightMouse.app`. It contains a real FinderSync `.appex`, built against the installed SDK and linked to `NSExtensionMain`. Development signing is ad hoc. Code signature verification establishes bundle consistency only; it does not prove Finder registration, sandbox access, App Group access or Finder menu behavior. The script does not register the extension, restart Finder or change system settings.

The extension reads only explicitly configured monitored locations. It refuses to issue commands when shared storage is unavailable. The host's development storage fallback does not grant the sandboxed extension access to that fallback directory.

Supported environment variables:

| Variable | Purpose |
| --- | --- |
| `RIGHTMOUSE_BUILD_DIR` | Build output directory; defaults to `.build/native` |
| `RIGHTMOUSE_ARCH` | One target architecture; defaults to the current machine architecture |
| `RIGHTMOUSE_APP_GROUP` | App Group written into bundle metadata and both entitlements |
| `RIGHTMOUSE_SIGNING_IDENTITY` | Signing identity; defaults to `-` for development |
| `RIGHTMOUSE_NOTARY_PROFILE` | Existing keychain notarytool profile, required for release packaging |

## Release package

Provide the registered group, Developer ID Application identity and existing notarytool keychain profile, then run `scripts/package-app.sh --release`. The release path builds, signs with hardened runtime, submits for notarization, staples and validates the ticket, and runs Gatekeeper assessment before writing the final ZIP. It fails if any required step fails. Never label the development ZIP as a notarized release.
