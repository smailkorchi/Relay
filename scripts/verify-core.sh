#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/relay-verify.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 "$script_dir/make-harness.py" \
    "$repo_root/Tests/RelayCoreTests/RelayCoreTests.swift" \
    "$work_dir/RelayCoreHarness.swift"

echo "Compiling Relay core verification fixtures…"
swiftc -parse-as-library -O -swift-version 5 \
    "$repo_root/Sources/RelayCore/Models.swift" \
    "$repo_root/Sources/RelayCore/TransferEngine.swift" \
    "$repo_root/Sources/RelayCore/DiskBenchmark.swift" \
    "$work_dir/RelayCoreHarness.swift" \
    -o "$work_dir/verify-core"

# RELAY_TEST_VOLUME is inherited unchanged; the external-drive fixture is opt-in.
"$work_dir/verify-core"
