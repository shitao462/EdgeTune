#!/bin/zsh
set -e
cd "${0:A:h}"
mkdir -p outputs/EdgeTune.app/Contents/MacOS
MACOSX_DEPLOYMENT_TARGET=14.0 make -C third_party/nowplaying-cli
swiftc -O -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework Carbon -framework ServiceManagement -framework ScreenCaptureKit -framework AVFoundation Sources/EdgeTune.swift -o outputs/EdgeTune.app/Contents/MacOS/EdgeTune
cp third_party/nowplaying-cli/nowplaying-cli outputs/EdgeTune.app/Contents/MacOS/nowplaying-cli
mkdir -p outputs/EdgeTune.app/Contents/MacOS/scripts outputs/EdgeTune.app/Contents/MacOS/build/mediaremote-mini
cp third_party/nowplaying-cli/scripts/mediaremote-mini.pl outputs/EdgeTune.app/Contents/MacOS/scripts/
cp third_party/nowplaying-cli/build/mediaremote-mini/MediaRemoteMini.dylib outputs/EdgeTune.app/Contents/MacOS/build/mediaremote-mini/
cp Info.plist outputs/EdgeTune.app/Contents/Info.plist
codesign --force --deep --sign - outputs/EdgeTune.app
echo "Built outputs/EdgeTune.app"
