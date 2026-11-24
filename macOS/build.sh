#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app='build/写真スライドショー.app'
mkdir -p "$app/Contents/MacOS" build/ModuleCache
cp Info.plist "$app/Contents/Info.plist"
xcrun --sdk macosx swiftc -swift-version 6 -warnings-as-errors -O -target arm64-apple-macosx14.0 \
    -module-cache-path build/ModuleCache -framework AppKit -framework Photos -framework IOKit \
    -o "$app/Contents/MacOS/PhotoSlideshow" Sources/*.swift
codesign --force --sign - --timestamp=none --options runtime --entitlements Entitlements.plist "$app"
codesign --verify --strict "$app"
