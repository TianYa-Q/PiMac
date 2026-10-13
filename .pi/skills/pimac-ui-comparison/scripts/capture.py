#!/usr/bin/env python3
"""在独立 Swift 包中捕获真实 PiMac 视图，不改运行 checkout。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--workspace", required=True, type=Path)
parser.add_argument("--test-template", type=Path)
parser.add_argument("--baseline-ref")
parser.add_argument("--baseline-file", action="append", default=[])
args = parser.parse_args()
root = Path.cwd().resolve()
tmp = root / "tmp"
fixture, output, package = (p.resolve() for p in (args.fixture, args.output, args.workspace))
if not (root / "Package.swift").is_file():
    parser.error("请在 PiMac 仓库根目录执行")
if not package.is_relative_to(tmp) or package == tmp:
    parser.error("--workspace 必须是仓库 tmp 下的独立子目录")
if not output.is_relative_to(tmp) or output.is_relative_to(package):
    parser.error("--output 必须位于 tmp 内、独立包外")
if bool(args.baseline_ref) != bool(args.baseline_file):
    parser.error("--baseline-ref 与 --baseline-file 必须一起使用")
data = json.loads(fixture.read_text())
if not isinstance(data, dict) or not isinstance(data.get("shell"), dict):
    parser.error("fixture.shell 必须是对象")
if not isinstance(data.get("selectedThreadID"), str) or not data["selectedThreadID"]:
    parser.error("fixture.selectedThreadID 必须是非空字符串")
for key, default, low, high in [("width", 1100, 320, 3000), ("height", 800, 200, 2000)]:
    value = data.get(key, default)
    if type(value) not in (int, float) or not low <= value <= high:
        parser.error(f"fixture.{key} 必须在 {low}…{high}")
if data.get("theme", "dark") not in ("dark", "light"):
    parser.error("fixture.theme 必须为 dark 或 light")
template = args.test_template or Path(__file__).resolve().parent.parent / "assets/NativeCaptureTests.swift"
marker = package / ".pimac-ui-capture"
if package.exists() and not marker.is_file():
    parser.error("拒绝覆盖非本工具创建的目录")
package.mkdir(parents=True, exist_ok=True)
marker.write_text("isolated PiMac visual capture\n")
shutil.copy2(root / "Package.swift", package / "Package.swift")
# 保留独立构建缓存；同步源码时只 trash 本工具副本中过期的文件。
sources = root / "Sources"
copied_sources = package / "Sources"
if copied_sources.exists():
    for old in copied_sources.rglob("*"):
        if old.is_file() and not (sources / old.relative_to(copied_sources)).exists():
            subprocess.run(["trash", str(old)], check=True)
shutil.copytree(sources, copied_sources, dirs_exist_ok=True)
for name in args.baseline_file:
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts or not name.startswith("Sources/"):
        parser.error("--baseline-file 只允许 Sources 下的相对文件路径")
    target = package / relative
    if not target.is_file():
        parser.error(f"不存在的 baseline 文件：{name}")
    target.write_bytes(subprocess.check_output(["git", "show", f"{args.baseline_ref}:{name}"], cwd=root))
tests = package / "Tests/PiMacAppTests"
tests.mkdir(parents=True, exist_ok=True)
shutil.copy2(template, tests / "PiMacNativeCaptureTests.swift")
output.parent.mkdir(parents=True, exist_ok=True)
# 防止失败后把上一次 PNG 当成这次截图；不静默覆盖现存交付证据。
if output.exists():
    parser.error("output 已存在，请使用新路径或先手动 trash 自己的旧输出")
log = output.with_suffix(".log")
env = dict(os.environ, PIMAC_CAPTURE_FIXTURE=str(fixture), PIMAC_CAPTURE_OUTPUT=str(output))
with log.open("w") as stream:
    result = subprocess.run(
        ["swift", "test", "--filter", "PiMacNativeCaptureTests"],
        cwd=package, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
if result.returncode or not output.is_file():
    raise SystemExit(f"捕获失败，查看 {log}（exit={result.returncode}）")
metadata = {
    "fixture": str(fixture), "fixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
    "baselineRef": args.baseline_ref, "baselineFiles": args.baseline_file,
    "sourceSHA256": {
        str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in copied_sources.rglob("*.swift")
    },
    "kind": "native SwiftUI fixture capture", "log": str(log),
}
output.with_suffix(".json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
print(output)
