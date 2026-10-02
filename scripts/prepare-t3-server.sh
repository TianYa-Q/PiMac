#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node -e 'if (Number(process.versions.node.split(".")[0]) < 24) { console.error("T3 Server build requires Node.js 24+"); process.exit(1); }'
node sidecars/t3-server/fetch-upstream.mjs
npm --prefix sidecars/t3-server ci --ignore-scripts
npm --prefix sidecars/t3-server run build
