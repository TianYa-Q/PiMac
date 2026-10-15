#!/bin/zsh
set -euo pipefail

RESOURCES_DIR="$1"
SIGN_IDENTITY="$2"
[[ -d "$RESOURCES_DIR" ]] || { echo "Native signing resources missing: $RESOURCES_DIR" >&2; exit 1; }

# --deep 不保证识别 node_modules 中的原生库和无后缀 helper；两种打包路径共用此扫描。
# npm helper 常为 0700，只需任一执行位，不能用 -perm -111（要求三组执行位同时存在）。
# find -exec ... + 会传递遍历/子进程失败；不用进程替换隐藏 find 的错误。
find "$RESOURCES_DIR" -type f \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -perm -100 -o -perm -010 -o -perm -001 \) -exec /bin/zsh -euc '
  identity="$1"
  shift
  for native_file; do
    description="$(file -b "$native_file")"
    if [[ "$description" == *Mach-O* ]]; then
      codesign --force --sign "$identity" "$native_file"
    fi
  done
' native-runtime-signer "$SIGN_IDENTITY" {} +
