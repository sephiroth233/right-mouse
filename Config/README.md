# Native build configuration

`Base.xcconfig` sets macOS 14 as the minimum deployment target. Copy `Local.xcconfig.example` to `Local.xcconfig` and provide your actual developer team and authorized App Group before testing a signed Finder extension. The default `group.cn.rightmouse.shared` is a development placeholder; it does not establish group membership.

Run `python3 Config/generate-project.py` after adding Swift files. This generates the host, Finder extension and core unit-test targets, plus the shared `RightMouse` scheme. The root Swift package provides `RightMouseCore`. With full Xcode selected, use:

```sh
xcodebuild -project RightMouse.xcodeproj -scheme RightMouse -configuration Debug build
xcodebuild -project RightMouse.xcodeproj -scheme RightMouse -configuration Debug test
```

Configure signing and App Groups for **both** targets in Xcode. For a provisioned `group.` identifier, each target needs a profile authorizing that group and its own bundle identifier. Xcode automatic signing can obtain profiles when the account and capabilities are configured; Apple's documentation also describes the `REGISTER_APP_GROUPS=YES` setting. The CLI environment variables below belong to our build script and do not configure Xcode signing automatically.

The generated project and scheme have been structurally parsed in the Command Line Tools environment. Full `xcodebuild` and XCTest execution require a complete Xcode installation and remain separate verification steps.

## Command Line Tools development bundle

```sh
scripts/build-app.sh --check-signing
scripts/build-app.sh
scripts/package-app.sh --development
```

The default output is `.build/native/RightMouse.app`. It contains a real FinderSync `.appex`, built against the installed SDK and linked to `NSExtensionMain`. Default development signing is ad hoc. Signature verification establishes bundle consistency; it does not prove sandbox or App Group authorization. The build script does not register the extension, restart Finder or change system settings.

On this machine, the ad-hoc extension registered and launched, but subsequent access to the protected App Group was rejected. See [the runtime evidence](validation/finder-load-2026-09-22.md). The host's explicit development data directory is useful for isolated functional tests; it does not make that directory available to a sandboxed Finder extension.

## Signing inputs

| Variable | Purpose |
| --- | --- |
| `RIGHTMOUSE_BUILD_DIR` | Build output directory; defaults to `.build/native` |
| `RIGHTMOUSE_ARCH` | One target architecture; defaults to the current machine architecture |
| `RIGHTMOUSE_APP_GROUP` | Authorized group written into bundle metadata and both entitlements |
| `RIGHTMOUSE_SIGNING_IDENTITY` | Exact valid Keychain identity name or SHA-1; defaults to `-` for ad-hoc development |
| `RIGHTMOUSE_TEAM_ID` | Optional expected 10-character team identifier; must agree with profiles, the group prefix when used, and actual signatures |
| `RIGHTMOUSE_HOST_PROFILE` | Path to the host's original CMS provisioning profile |
| `RIGHTMOUSE_EXTENSION_PROFILE` | Path to the Finder extension's original CMS provisioning profile |
| `RIGHTMOUSE_NOTARY_PROFILE` | Existing notarytool Keychain profile; needed only for actual release submission |

Supported App Group authorization routes:

| Route | Required inputs and checks |
| --- | --- |
| Registered `group.<name>` | Every certificate-signed build requires both host and extension profiles authorizing the group, target bundle IDs and selected signing certificate. This includes release builds. |
| macOS `<actual Team ID>.<name>` | Profiles are optional. The group prefix must match the real team in both Apple-issued signatures. Supplying an invented prefix cannot satisfy this check. If profiles are provided, the same profile checks apply. |
| Ad-hoc development | No profiles may be supplied. The app can be compiled and locally tested, but App Group access is not claimed. Release mode rejects ad-hoc signing. |

These routes follow Apple's distinction between provisioned groups and macOS team-prefixed groups. They are not interchangeable claims of authorization. [Apple: Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)

The script checks profile CMS decoding, macOS platform, expiration, declared team, application-identifier allowlist, App Group entitlement and certificate allowlist. A profile's App ID prefix is resolved from its `ApplicationIdentifierPrefix`; it is not assumed to equal the Team ID. Profile authorization identifiers are added to the generated entitlements. Signed builds verify the actual entitlements, Apple certificate chain, signature team and leaf certificate membership in the profile. Release mode additionally requires the Developer ID certificate issuer and Application leaf OIDs and rejects debugger-enabled profiles. The certificate requirements follow [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). These checks follow the profile allowlist model described in [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

The original profile bytes are snapshotted and embedded separately at:

```text
RightMouse.app/Contents/embedded.provisionprofile
RightMouse.app/Contents/PlugIns/RightMouseFinder.appex/Contents/embedded.provisionprofile
```

Previous embedded profiles are removed before the current profiles are installed and the bundles are signed. A successful ad-hoc build therefore cannot retain profiles from an earlier signed build. Signed output is checked against the snapshots; the script does not print profile contents or modify the Keychain.

CMS decoding and our consistency checks do not replace macOS's authoritative profile authorization and runtime checks. Real profile inputs and actual signed runtime access remain required evidence. Apple specifically notes that on macOS a returned container URL does not prove the group is valid. [Apple: containerURL](https://developer.apple.com/documentation/foundation/filemanager/containerurl%28forsecurityapplicationgroupidentifier%3A%29)

## Check signing inputs without building or publishing

After setting the applicable environment variables, run:

```sh
scripts/package-app.sh --release --check-signing
```

This performs local preflight checks only. It does not compile, sign, launch the app, submit for notarization, or require `RIGHTMOUSE_NOTARY_PROFILE`. Actual code-signature team and certificate/profile agreement are checked after a real build is signed. Missing identities, missing files and invalid CMS inputs stop before compilation.

For a signed build without a publication step, run `scripts/build-app.sh --release`. With supplied identities and profiles this signs and verifies the local app, but does not call notarytool or upload anything.

## Release package

Once local signing and Finder runtime tests pass, provide the authorized App Group, Developer ID Application identity, applicable profiles and existing notarytool Keychain profile, then run:

```sh
scripts/package-app.sh --release
```

This command **submits the built application to Apple's notarization service**. It builds, signs with hardened runtime, verifies signing/profile consistency, submits for notarization, staples and validates the ticket, and performs Gatekeeper assessment before writing the final release ZIP. It stops on failure. Never label the development ZIP as a notarized release.

## Verification performed without signing credentials

- Both shell scripts pass `bash -n`.
- Thirteen preflight cases cover default development, missing release identity, missing profiles, nonexistent profile paths, non-CMS input, invalid ad-hoc/profile combinations, malformed group/team values, mismatched group/team values, unavailable identities and unknown flags.
- An independent copy of a compiled development app was re-signed ad hoc; actual signed entitlements were read through `codesign --xml` and matched the generated entitlements.
- Stale embedded-profile path fixtures were removed before signing. No fake provisioning profile or certificate was generated.
- No real signing identity or provisioning profile is available in this environment, so positive certificate/profile matching and signed App Group access remain unverified. No notarization was submitted during these checks.
