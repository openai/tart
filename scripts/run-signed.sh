#!/bin/sh

# helper script to build and run a signed tart binary
# usage: ./scripts/run-signed.sh run macos

set -e

swift build --product tart

rm -Rf .build/tart.app/
mkdir -p .build/tart.app/Contents/MacOS .build/tart.app/Contents/Resources
cp -c .build/debug/tart .build/tart.app/Contents/MacOS/tart
cp -c Resources/embedded.provisionprofile .build/tart.app/Contents/embedded.provisionprofile
cp -c Resources/Info.plist .build/tart.app/Contents/Info.plist
cp -c "Resources/actool/UPW Tart.icns" "Resources/actool/Assets.car" .build/tart.app/Contents/Resources/

ENTITLEMENTS="Resources/tart-dev.entitlements"
for argument in "$@"; do
  case "$argument" in
    --net-vmnet-subnet | --net-vmnet-subnet=*)
      ENTITLEMENTS="Resources/tart-vmnet-dev.entitlements"
      ;;
  esac
done

codesign --sign - --entitlements "$ENTITLEMENTS" --force .build/tart.app

.build/tart.app/Contents/MacOS/tart "$@"
