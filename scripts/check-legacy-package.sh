#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/check-entitlements.py
make deb-rootful-legacy CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
rm -rf .build/package-check/rootful-ios13
mkdir -p .build/package-check/rootful-ios13
version=$(python3 -c 'import plistlib; print(plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleShortVersionString"])')
package=".build/com.icli.icli_${version}_iphoneos-arm-ios13.deb"
dpkg-deb -x "$package" .build/package-check/rootful-ios13
cmp .build/icli-ios13 .build/package-check/rootful-ios13/usr/bin/icli
shasum -a 256 .build/icli-ios13 .build/package-check/rootful-ios13/usr/bin/icli
python3 scripts/verify-legacy-package.py
python3 scripts/check-package-consumer.py --minimum-ios 13.0
