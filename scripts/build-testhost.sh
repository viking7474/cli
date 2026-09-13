#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

LAYOUT="${ICLI_LAYOUT:-rootless}"
MIN_IOS="${ICLI_MIN_IOS:-16.0}"
TARGET="${ICLI_TARGET:-arm64-apple-ios${MIN_IOS}}"

case "$LAYOUT" in
  rootless)
    ARCH=iphoneos-arm64
    PREFIX=/var/jb
    SHELL_PATH=/var/jb/bin/sh
    UICACHE=/var/jb/usr/bin/uicache
    ;;
  rootful)
    ARCH=iphoneos-arm
    PREFIX=
    SHELL_PATH=/bin/sh
    UICACHE=/usr/bin/uicache
    ;;
  *)
    echo "unsupported TestHost layout: $LAYOUT" >&2
    exit 64
    ;;
esac

if [ "$LAYOUT" = rootless ]; then
  stage=.build/testhost-deb
else
  stage=.build/testhost-deb-rootful
fi
app="$stage$PREFIX/Applications/IcliTestHost.app"
rm -rf "$stage"
mkdir -p "$app" "$stage/DEBIAN"
xcrun clang -target "$TARGET" -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -fobjc-arc -fmodules -fmodules-cache-path=.build/module-cache -framework Foundation -framework UIKit -framework Vision -framework AVFoundation -framework Security \
  Tests/TestHost/main.m -o "$app/IcliTestHost"
cp Tests/TestHost/Info.plist "$app/Info.plist"
python3 - "$app/Info.plist" "$MIN_IOS" <<'PY'
import plistlib, sys
path, minimum = sys.argv[1:]
with open(path, 'rb') as source:
    info = plistlib.load(source)
info['MinimumOSVersion'] = minimum
with open(path, 'wb') as destination:
    plistlib.dump(info, destination)
PY
ldid -STests/TestHost/entitlements.plist "$app/IcliTestHost"
ldid -STests/TestHost/entitlements.plist "$app"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: dev.owngoal.icli.testhost
Name: icli TestHost
Version: 1.0
Architecture: $ARCH
Maintainer: OwnGoal
Section: Development
Depends: firmware (>= $MIN_IOS)
Description: Test-only fixture for icli acceptance
CONTROL
cat > "$stage/DEBIAN/postinst" <<POSTINST
#!$SHELL_PATH
set -e
$UICACHE -p $PREFIX/Applications/IcliTestHost.app
POSTINST
cat > "$stage/DEBIAN/prerm" <<PRERM
#!$SHELL_PATH
$UICACHE -u $PREFIX/Applications/IcliTestHost.app
PRERM
chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
dpkg-deb --root-owner-group -b "$stage" ".build/icli-testhost_1.0_${ARCH}.deb"
