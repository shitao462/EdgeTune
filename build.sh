#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
identity="${EDGETUNE_SIGNING_IDENTITY:-EdgeTune Local Development}"
if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
  echo "Missing signing identity: $identity. See README.md: 开发签名。" >&2
  exit 1
fi
if pgrep -x EdgeTune >/dev/null; then
  echo "Quit EdgeTune before building to preserve the active audio capture session." >&2
  exit 1
fi
mkdir -p outputs
stage=$(mktemp -d "$PWD/outputs/.build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/EdgeTune.app"
bin="$app/Contents/MacOS"
mkdir -p "$bin" "$app/Contents/Resources/scripts" "$app/Contents/Frameworks"
MACOSX_DEPLOYMENT_TARGET=14.0 make -C third_party/nowplaying-cli
swiftc -O -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework Carbon -framework ServiceManagement -framework ScreenCaptureKit -framework AVFoundation Sources/EdgeTune.swift -o "$bin/EdgeTune"
cp third_party/nowplaying-cli/nowplaying-cli "$bin/nowplaying-cli"
cp third_party/nowplaying-cli/scripts/mediaremote-mini.pl "$app/Contents/Resources/scripts/"
cp third_party/nowplaying-cli/build/mediaremote-mini/MediaRemoteMini.dylib "$app/Contents/Frameworks/"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign "$identity" "$app/Contents/Frameworks/MediaRemoteMini.dylib"
codesign --force --sign "$identity" "$bin/nowplaying-cli"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
requirement=$(codesign -d -r- "$app" 2>&1 | sed -En 's/^#{0,1} *designated => //p')
if [[ -z "$requirement" || "$requirement" == *cdhash* ]]; then
  echo "Refusing unstable signing requirement." >&2
  exit 1
fi
record="outputs/.signing-requirement"
if [[ -f "$record" && "$(cat "$record")" != "$requirement" ]]; then
  echo "Signing identity changed; refusing to invalidate audio permission." >&2
  exit 1
fi
if [[ -d outputs/EdgeTune.app ]]; then
  old=$(codesign -d -r- outputs/EdgeTune.app 2>&1 | sed -En 's/^#{0,1} *designated => //p')
  if [[ "$old" != *cdhash* && "$old" != "$requirement" ]]; then
    echo "Existing app has a different persistent signature; refusing replacement." >&2
    exit 1
  fi
fi
if pgrep -x EdgeTune >/dev/null; then
  echo "EdgeTune started during build; quit it and rebuild." >&2
  exit 1
fi
backup="outputs/.EdgeTune.previous.app"
[[ ! -e "$backup" ]] || { echo "Backup already exists: $backup" >&2; exit 1; }
[[ ! -d outputs/EdgeTune.app ]] || mv outputs/EdgeTune.app "$backup"
if ! mv "$app" outputs/EdgeTune.app; then
  [[ ! -d "$backup" ]] || mv "$backup" outputs/EdgeTune.app
  exit 1
fi
print -r -- "$requirement" > "$record"
rm -rf "$backup"
echo "Built outputs/EdgeTune.app with persistent signing identity."
