#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# esbuild 的 Go 工作线程也受限；仅串行启动测试文件不足以限制打包阶段。
export GOMAXPROCS=2
./scripts/lint.sh
python3 -m unittest discover -s Tests/DevWatcher -p 'test_*.py'
./scripts/prepare-t3-server.sh
swift test --jobs 2 --no-parallel
npm --prefix extensions/account-usage run prepublishOnly
npm --prefix extensions/account-usage test
node scripts/test-fast-extension.mjs
node --test --test-concurrency=1 Tests/PiCompatibility/*.test.mjs
node scripts/test-pi-compatibility.mjs
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
