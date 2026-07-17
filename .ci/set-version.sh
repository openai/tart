#!/bin/sh

set -e

: "${VERSION:?VERSION must be set}"

TMPFILE=$(mktemp)
perl -pe 's/\$\{VERSION\}/$ENV{VERSION}/g' Sources/tart/CI/CI.swift > "$TMPFILE"
mv "$TMPFILE" Sources/tart/CI/CI.swift

/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" Resources/Info.plist
