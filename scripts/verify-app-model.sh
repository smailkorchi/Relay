#!/bin/bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/relay-model-verify.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Compiling Relay AppModel flow checks…"
swiftc -parse-as-library -O -swift-version 5 -emit-library -emit-module \
    -module-name RelayCore -emit-module-path "$work_dir/RelayCore.swiftmodule" \
    -Xlinker -install_name -Xlinker '@rpath/libRelayCore.dylib' \
    "$repo_root/Sources/RelayCore/Models.swift" \
    "$repo_root/Sources/RelayCore/TransferEngine.swift" \
    "$repo_root/Sources/RelayCore/DiskBenchmark.swift" \
    -o "$work_dir/libRelayCore.dylib"

swiftc -parse-as-library -O -swift-version 5 \
    -I "$work_dir" -L "$work_dir" -lRelayCore \
    -Xlinker -rpath -Xlinker "$work_dir" \
    "$repo_root/Sources/RelayApp/RelayPage.swift" \
    "$repo_root/Sources/RelayApp/AppModel.swift" \
    "$repo_root/Tests/Support/AppModelFlowChecks.swift" \
    -o "$work_dir/verify-app-model"

# External transfer fixtures run only when explicitly opted in by the caller.
"$work_dir/verify-app-model" "$repo_root/QA/Receipts"
