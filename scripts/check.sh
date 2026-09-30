#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/lint.sh
swift test
npm --prefix extensions/account-usage run prepublishOnly
npm --prefix extensions/account-usage test
node scripts/test-fast-extension.mjs
node scripts/test-pi-compatibility.mjs
