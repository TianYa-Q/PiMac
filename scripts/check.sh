#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/lint.sh
swift test
npm --prefix extensions/account-usage run prepublishOnly
npm --prefix extensions/account-usage test
node scripts/test-fast-extension.mjs
node --test Tests/PiCompatibility/*.test.mjs
node scripts/test-pi-compatibility.mjs
npm --prefix sidecars/t3-rpc run check
node --test Tests/T3Bridge/*.test.mjs
