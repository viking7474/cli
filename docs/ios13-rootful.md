# Experimental iOS 13 rootful support

This profile targets **arm64 devices running iOS 13 or later with a rootful jailbreak**, with iPhone 6s as the first validation target. It is deliberately separate from the project's normal iOS 16+ rootless/RootHide release path.

The source manifest now permits iOS 13, but the existing default build still targets `arm64-apple-ios16.0`. iOS 13 support is **experimental until the device acceptance suite is run on real iOS 13 hardware**. In particular, the private AXRuntime attribute mapping has only been validated on the existing newer test environment.

## Toolchain

Use a macOS host with **Xcode 15.4** selected. The legacy profile needs an SDK/toolchain that still accepts an iOS 13 deployment target.

Confirm the active tools before building:

```sh
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
swift --version
```

## Build and verify the CLI

The normal build remains unchanged:

```sh
make all CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
```

Build the separate iOS 13 binary and rootful package with:

```sh
make legacy-rootful CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
make deb-rootful-legacy CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
```

Outputs:

| Artifact | Path |
| --- | --- |
| iOS 13 arm64 executable | `.build/icli-ios13` |
| Rootful DEB | `.build/com.icli.icli_<version>_iphoneos-arm-ios13.deb` |

The rootful package declares `firmware (>= 13.0)`. The existing rootless and RootHide packages continue to declare `firmware (>= 16.0)`.

Run the complete host-side legacy checks on the Mac with:

```sh
make legacy-check
```

That command verifies the Mach-O is arm64 with `minos 13.0`, checks signing and process-launch invariants, builds/extracts the rootful DEB, checks its architecture and firmware dependency, and builds a separate Swift Package consumer for an iOS 13 deployment target.

Because iOS 13/14 do not ship the Swift concurrency runtime, the legacy build adds `@executable_path/../lib/icli` as a private runpath. Packaging inspects the executable for `@rpath/libswift*.dylib` dependencies and copies matching Xcode back-deployment runtimes (notably `libswift_Concurrency.dylib`) into `/usr/lib/icli`. `.build/swift-runtime-ios13.json` records the exact bundled runtime files, deployment floors, hashes, and runpaths, and package verification fails if a required concurrency runtime is missing.

The pinned `libarchive.xcframework` dependency declares iOS 12 for its arm64 iOS slice, so it does not raise the iOS 13 deployment floor. `swift-argument-parser` 1.3.1 uses a Swift 5.7 package manifest and does not declare a higher iOS platform floor.

## Build the rootful TestHost and fixtures

```sh
make legacy-fixtures
```

This is equivalent to building the TestHost with `ICLI_LAYOUT=rootful ICLI_MIN_IOS=13.0` and then building the rootful install/self-test fixtures.

Outputs include:

```text
.build/icli-testhost_1.0_iphoneos-arm.deb
.build/install-fixtures-ios13/icli-install-fixture.ipa
.build/install-fixtures-ios13/icli-install-fixture.deb
.build/install-fixtures-ios13/SelfTestFixture.app
```

The rootless TestHost/fixture commands and paths remain unchanged when `ICLI_LAYOUT` is omitted.

## Install and run on iPhone 6s

Install the rootful package with the device's package manager or `dpkg`. The executable is installed at:

```text
/usr/bin/icli
```

Basic smoke tests should be run before privileged or disruptive commands:

```sh
icli --version
icli env info
icli device info
icli fs ls /tmp
icli proc list
icli screen info
```

Then test screenshot/app/IOHID features before AXRuntime and launchd operations.

## Acceptance runner

Build/install the rootful TestHost and upload the rootful install fixtures first. Then run, from the repository on the Mac:

```sh
ICLI_LAYOUT=rootful \
ICLI_BINARY=/usr/bin/icli \
python3 scripts/acceptance.py \
  --install \
  --report .build/acceptance-ios13-rootful.json
```

`ICLI_LAYOUT=rootful` switches acceptance paths from `/var/jb/...` to rootful locations, compares the device binary with `.build/icli-ios13`, uses the `iphoneos-arm` package, and selects the iOS 13 fixture directory.

For the first physical-device run, use named cases or groups before a complete run. Keep reboot/respring tests for last. A practical order is:

```sh
ICLI_LAYOUT=rootful python3 scripts/acceptance.py --case device_snapshot --case file_roundtrip
ICLI_LAYOUT=rootful python3 scripts/acceptance.py --group screen
ICLI_LAYOUT=rootful python3 scripts/acceptance.py --group apps
ICLI_LAYOUT=rootful python3 scripts/acceptance.py --group gestures
ICLI_LAYOUT=rootful python3 scripts/acceptance.py --group ax
ICLI_LAYOUT=rootful python3 scripts/acceptance.py --group system --skip-reboot
```

## Runtime compatibility notes

`Sources/IcliPrivate/Launchd.m` has a legacy transport path for iOS 13/14. It runtime-resolves version-dependent libxpc entry points, uses `xpc_pipe_routine` and the system domain on pre-iOS-15 systems, and uses file-descriptor output for legacy launchd `print` requests. Newer firmware keeps the existing interface-routine/shared-memory path and iOS 16+ user-domain lookup.

Most SpringBoardServices, BackBoard, IOHID and related private interfaces in icli are already resolved dynamically. Missing symbols should therefore surface as capability failures rather than forcing every OS release to expose the same private ABI.

Accessibility remains a device-validation gate. `Accessibility.m` keeps the numeric AXRuntime identifiers used by the project's newer test target, but now falls back to named attributes such as `AXLabel`, `AXFrame`, `AXValue`, `AXIdentifier`, and named root collections when numeric reads are unavailable. Pre-iOS-15 tree queries are capped at 50 elements to avoid aggressive private-AX traversal on older runtimes. If `ui tree`, `ui at`, or related commands still fail on iOS 13, capture those failures before introducing any iOS-specific numeric mapping; do not guess private attribute IDs.

Do not treat a successful compile as proof that every command works on iOS 13. Record support per command/capability in the acceptance report.
