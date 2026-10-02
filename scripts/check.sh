#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/lint.sh
./scripts/prepare-t3-server.sh
swift test
npm --prefix extensions/account-usage run prepublishOnly
npm --prefix extensions/account-usage test
node scripts/test-fast-extension.mjs
node --test Tests/PiCompatibility/*.test.mjs
node scripts/test-pi-compatibility.mjs
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
