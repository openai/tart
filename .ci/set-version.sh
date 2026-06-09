#!/bin/sh

TMPFILE=$(mktemp)
envsubst < Sources/tart/CI/CI.swift > $TMPFILE
mv $TMPFILE Sources/tart/CI/CI.swift

/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" Resources/Info.plist
