#!/usr/bin/env python3
"""直接在仓库中捕获真实 PiMac 视图，复用共用 .build，不复制 Swift 包。"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True, type=Path)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
root = Path.cwd().resolve()
tmp = root / "tmp"
fixture, output = (p.resolve() for p in (args.fixture, args.output))
if not (root / "Package.swift").is_file():
    parser.error("请在 PiMac 仓库根目录执行")
if not output.is_relative_to(tmp):
    parser.error("--output 必须位于仓库 tmp 内")
data = json.loads(fixture.read_text())
if not isinstance(data, dict) or not isinstance(data.get("shell"), dict):
    parser.error("fixture.shell 必须是对象")
if not isinstance(data.get("selectedThreadID"), str) or not data["selectedThreadID"]:
    parser.error("fixture.selectedThreadID 必须为非空字符串")
for key, default, low, high in [("width", 1100, 320, 3000), ("height", 800, 200, 2000)]:
    value = data.get(key, default)
    if type(value) not in (int, float) or not low <= value <= high:
        parser.error(f"fixture.{key} 必须在 {low}…{high}")
if data.get("theme", "dark") not in ("dark", "light"):
    parser.error("fixture.theme 必须为 dark 或 light")
output.parent.mkdir(parents=True, exist_ok=True)
# 共享源码和 SwiftPM 缓存，但不共享截图输出；并发捕获直接报忙，不排队抢占。
(root / ".build").mkdir(exist_ok=True)
with (root / ".build/native-capture.lock").open("a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("另一个原生捕获任务正在运行，请等待完成后再执行")
    if any(path.exists() for path in (output, output.with_suffix(".log"), output.with_suffix(".json"))):
        parser.error("output 或关联日志/元数据已存在，请使用新路径")
    # 记录实际编译前的来源；构建期间有修改则拒绝认证，避免元数据冒充一致快照。
    source_paths = sorted((root / "Sources").rglob("*.swift")) + [
        root / "Package.swift", root / "Tests/PiMacAppTests/NativeCaptureTests.swift"]
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}
    fixture_hash = hashlib.sha256(fixture.read_bytes()).hexdigest()
    log = output.with_suffix(".log")
    env = dict(os.environ, PIMAC_CAPTURE_FIXTURE=str(fixture), PIMAC_CAPTURE_OUTPUT=str(output))
    with log.open("x") as stream:
        result = subprocess.run(
            ["swift", "test", "--jobs", "1", "--no-parallel", "--filter", "PiMacNativeCaptureTests"],
            cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
    if result.returncode or not output.is_file():
        raise SystemExit(f"捕获失败，查看 {log}（exit={result.returncode}）")
    current_paths = sorted((root / "Sources").rglob("*.swift")) + [
        root / "Package.swift", root / "Tests/PiMacAppTests/NativeCaptureTests.swift"]
    if (source_paths != current_paths
            or any(hashlib.sha256(p.read_bytes()).hexdigest() != hashes[str(p.relative_to(root))]
                   for p in current_paths)
            or hashlib.sha256(fixture.read_bytes()).hexdigest() != fixture_hash):
        raise SystemExit(f"捕获期间源码或 fixture 发生变化，截图未认证，请使用新 output 重试（{log}）")
    metadata = {
        "fixture": str(fixture), "fixtureSHA256": fixture_hash,
        "sourceSHA256": hashes, "workspace": str(root), "buildPath": str(root / ".build"),
        "kind": "native SwiftUI fixture capture", "log": str(log),
    }
    output.with_suffix(".json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
print(output)
