#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --build-system native -c release
bundle="$project_dir/dist/Relay.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/Relay "$bundle/Contents/MacOS/Relay"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
if [[ -f Resources/Relay.icns ]]; then
    cp Resources/Relay.icns "$bundle/Contents/Resources/Relay.icns"
fi
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf 'Packaged %s\n' "$bundle"
