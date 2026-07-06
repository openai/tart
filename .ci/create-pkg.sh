#!/bin/sh

set -e

export VERSION="${VERSION:-0}"

mkdir -p .ci/pkg/
cp .build/arm64-apple-macosx/release/tart .ci/pkg/tart
cp Resources/embedded.provisionprofile .ci/pkg/embedded.provisionprofile
cp Resources/AppIcon.png .ci/pkg/AppIcon.png
cp Resources/Info.plist .ci/pkg/Info.plist
pkgbuild --root .ci/pkg/ --identifier com.github.cirruslabs.tart --version $VERSION \
  --scripts .ci/pkg/scripts \
  --install-location "/Library/Application Support/Tart" \
  --sign "Developer ID Installer: Cirrus Labs, Inc. (9M2P8L4D89)" \
  "./.ci/Tart-$VERSION.pkg"
xcrun notarytool submit "./.ci/Tart-$VERSION.pkg" --keychain-profile "notarytool" --wait
xcrun stapler staple "./.ci/Tart-$VERSION.pkg"
