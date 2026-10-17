#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
input_app="${1:-$repo_root/dist/Relay.app}"
output_dir="${2:-$repo_root/dist/release}"
version="1.1.0"
build="2"
expected_binary_sha="190aefbbafe45a8a4b8e4a749907630355f0b79ecf1986e2561dd63c0ffef992"
artifact_base="Relay-$version-macOS-arm64"

if [[ $# -gt 2 ]]; then
    echo "Usage: $0 [built Relay.app] [release output directory]" >&2
    exit 2
fi
if [[ ! -d "$input_app" || -L "$input_app" ]]; then
    echo "The input must be a built Relay.app bundle." >&2
    exit 1
fi
input_app="$(CDPATH= cd -- "$input_app" && pwd)"
mkdir -p -- "$output_dir"
output_dir="$(CDPATH= cd -- "$output_dir" && pwd)"
for name in "$artifact_base.dmg" "$artifact_base.zip" "SHA256SUMS.txt"; do
    if [[ -e "$output_dir/$name" || -L "$output_dir/$name" ]]; then
        echo "Refusing to replace an existing release artifact: $name" >&2
        exit 1
    fi
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/relay-package-release.XXXXXX")"
mount_dir="$work_dir/mounted"
mounted=0
cleanup() {
    status=$?
    trap - EXIT
    if [[ "$mounted" -eq 1 ]]; then
        if ! hdiutil detach "$mount_dir" >/dev/null 2>&1; then
            echo "Could not unmount the verification image. Preserving its temporary directory: $work_dir" >&2
            exit 1
        fi
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
icon_sha="$(hash_file "$input_app/Contents/Resources/Relay.icns")"
verify_app() {
    local app="$1"
    [[ "$(plist_value "$app" CFBundleShortVersionString)" == "$version" ]]
    [[ "$(plist_value "$app" CFBundleVersion)" == "$build" ]]
    [[ "$(plist_value "$app" CFBundleExecutable)" == "Relay" ]]
    [[ "$(plist_value "$app" CFBundleIdentifier)" == "local.ismail.relay" ]]
    [[ "$(plist_value "$app" LSMinimumSystemVersion)" == "14.0" ]]
    [[ -x "$app/Contents/MacOS/Relay" ]]
    [[ "$(lipo -archs "$app/Contents/MacOS/Relay")" == "arm64" ]]
    [[ "$(hash_file "$app/Contents/MacOS/Relay")" == "$expected_binary_sha" ]]
    [[ "$(hash_file "$app/Contents/Resources/Relay.icns")" == "$icon_sha" ]]
    codesign --verify --deep --strict --verbose=2 "$app"
}
verify_clean_metadata() {
    # macOS can synthesize protected provenance on local copies even when no attributes were copied.
    python3 - "$1" <<'PY'
import subprocess, sys
result=subprocess.run(['/usr/bin/xattr','-r',sys.argv[1]],capture_output=True,text=True,check=True)
for line in result.stdout.splitlines():
    if line.rsplit(': ',1)[-1] != 'com.apple.provenance':
        raise SystemExit('The app contains unexpected extended metadata')
PY
}

echo "Checking Relay $version (build $build), arm64…"
verify_app "$input_app"
codesign -dv --verbose=4 "$input_app" 2>"$work_dir/signature.txt"
if ! grep -q '^Signature=adhoc$' "$work_dir/signature.txt"; then
    echo "This packager expects the approved ad-hoc signed release build." >&2
    exit 1
fi

payload="$work_dir/payload"
mkdir -p -- "$payload" "$mount_dir" "$work_dir/unzipped"
# Copy bundle files and executable permissions, excluding local resource forks, ACLs, and extended metadata.
ditto --noextattr --norsrc --noacl --noqtn "$input_app" "$payload/Relay.app"
verify_app "$payload/Relay.app"
verify_clean_metadata "$payload/Relay.app"
ln -s /Applications "$payload/Applications"
cat >"$payload/Install.txt" <<'TXT'
Relay 1.1.0 (build 2)
Apple silicon Mac · macOS 14 or later

Drag Relay.app to Applications, then open Relay from Applications.

This release is locally ad-hoc signed and has not been notarized by Apple.
If macOS blocks it because the developer cannot be verified, first try opening
the app. Then open System Settings > Privacy & Security, select Open Anyway,
and confirm Open if you trust this download.

Apple's instructions: https://support.apple.com/en-us/102445
Project: https://github.com/smailkorchi/Relay
TXT

dmg="$work_dir/$artifact_base.dmg"
zip="$work_dir/$artifact_base.zip"
echo "Creating drag-install disk image…"
hdiutil create -volname "Relay $version" -srcfolder "$payload" -fs HFS+ -format UDZO "$dmg"
echo "Creating app-bundle ZIP…"
ditto -c -k --keepParent --noextattr --norsrc --noacl --noqtn "$payload/Relay.app" "$zip"

echo "Verifying read-only disk image…"
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" -plist "$dmg" >"$work_dir/attach.plist"
mounted=1
python3 - "$mount_dir" <<'PY'
import os, sys
if not os.statvfs(sys.argv[1]).f_flag & os.ST_RDONLY:
    raise SystemExit('Verification image was not mounted read-only')
PY
verify_app "$mount_dir/Relay.app"
verify_clean_metadata "$mount_dir/Relay.app"
[[ -L "$mount_dir/Applications" && "$(readlink "$mount_dir/Applications")" == "/Applications" ]]
cmp "$payload/Install.txt" "$mount_dir/Install.txt"
hdiutil detach "$mount_dir"
mounted=0

echo "Verifying extracted ZIP…"
ditto -x -k --noextattr --norsrc --noacl --noqtn "$zip" "$work_dir/unzipped"
verify_app "$work_dir/unzipped/Relay.app"
python3 - "$zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in archive.namelist():
        if not name.startswith('Relay.app/') or '__MACOSX/' in name or any(part.startswith('._') for part in name.split('/')):
            raise SystemExit('Unexpected ZIP metadata or path: '+name)
PY
verify_clean_metadata "$work_dir/unzipped/Relay.app"

# Publish complete, verified files without replacing an earlier release.
python3 - "$dmg" "$zip" "$output_dir" <<'PY'
from pathlib import Path
import hashlib, os, shutil, sys
destination=Path(sys.argv[3])
published=[]
try:
    for source in map(Path, sys.argv[1:3]):
        target=destination/source.name
        with target.open('xb') as output, source.open('rb') as original:
            published.append(target)
            shutil.copyfileobj(original, output)
            output.flush(); os.fsync(output.fileno())
    with (destination/'SHA256SUMS.txt').open('x') as checksums:
        published.append(destination/'SHA256SUMS.txt')
        for path in published[:-1]:
            digest=hashlib.sha256()
            with path.open('rb') as artifact:
                for block in iter(lambda: artifact.read(1024*1024), b''):
                    digest.update(block)
            checksums.write(digest.hexdigest()+'  '+path.name+'\n')
        checksums.flush(); os.fsync(checksums.fileno())
except BaseException:
    for path in published:
        path.unlink(missing_ok=True)
    raise
for path in published:
    print(path.name+': '+str(path.stat().st_size)+' bytes')
print((destination/'SHA256SUMS.txt').read_text(), end='')
PY
echo "Verified: version/build, arm64, strict signature, approved binary/icon hashes, Applications link, and clean bundle metadata."
echo "Signing: ad-hoc; Apple notarization: not performed."
echo "Release artifacts: $output_dir"
