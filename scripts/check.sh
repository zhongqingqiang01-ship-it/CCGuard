#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
node_bin="${NODE_BIN:-$(command -v node || true)}"
if [[ -z "$node_bin" || ! -x "$node_bin" ]]; then
    print -u2 '需要 Node.js 22 或更高；可用 NODE_BIN=/path/to/node 指定。'
    exit 1
fi
"$node_bin" -e 'if (Number(process.versions.node.split(".")[0]) < 22) { throw new Error("Node.js 22+ is required"); }'
swift test --disable-sandbox
"$node_bin" scripts/verify-extractor.mjs
"$node_bin" scripts/verify-background-probe.mjs
