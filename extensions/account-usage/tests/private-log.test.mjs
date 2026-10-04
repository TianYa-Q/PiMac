import assert from "node:assert/strict";
import { test } from "node:test";
import {
  chmodSync,
  linkSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { createJiti } from "jiti";

const { appendPrivateDiagnostic, MAX_DIAGNOSTIC_LOG_BYTES } = await createJiti(
  import.meta.url,
).import("../private-log.ts");

function fixture(run) {
  const root = mkdtempSync(join(tmpdir(), "pimac-log-"));
  try {
    run(root, join(root, "errors.jsonl"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("appends JSONL with private permissions and repairs existing modes", () => {
  fixture((_root, path) => {
    appendPrivateDiagnostic(path, { name: "first" });
    chmodSync(path, 0o644);
    appendPrivateDiagnostic(path, { name: "second\nline" });
    assert.deepEqual(
      readFileSync(path, "utf8").trim().split("\n").map(JSON.parse),
      [{ name: "first" }, { name: "second\nline" }],
    );
    assert.equal(statSync(path).mode & 0o777, 0o600);
  });
});

test("rotates before crossing the byte limit without following a backup symlink", () => {
  fixture((root, path) => {
    writeFileSync(path, "x".repeat(MAX_DIAGNOSTIC_LOG_BYTES - 1), {
      mode: 0o600,
    });
    const target = join(root, "unrelated");
    writeFileSync(target, "preserve", { mode: 0o644 });
    symlinkSync(target, `${path}.1`);
    appendPrivateDiagnostic(path, { ok: true });
    assert.equal(readFileSync(target, "utf8"), "preserve");
    assert.equal(statSync(`${path}.1`).size, MAX_DIAGNOSTIC_LOG_BYTES - 1);
    assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), { ok: true });
  });
});

test("rejects symlinks, hardlinks and directories without changing targets", () => {
  fixture((root, path) => {
    const target = join(root, "target");
    writeFileSync(target, "preserve", { mode: 0o644 });
    chmodSync(target, 0o644);
    symlinkSync(target, path);
    assert.throws(() => appendPrivateDiagnostic(path, {}));
    rmSync(path);
    linkSync(target, path);
    assert.throws(() => appendPrivateDiagnostic(path, {}));
    assert.throws(() => appendPrivateDiagnostic(root, {}));
    assert.equal(readFileSync(target, "utf8"), "preserve");
    assert.equal(statSync(target).mode & 0o777, 0o644);
  });
});

test("rejects oversized and unserializable entries before changing files", () => {
  fixture((_root, path) => {
    appendPrivateDiagnostic(path, { ok: true });
    const before = readFileSync(path);
    assert.throws(() =>
      appendPrivateDiagnostic(path, { value: "x".repeat(16384) }),
    );
    assert.throws(() => appendPrivateDiagnostic(path, { value: 1n }));
    assert.deepEqual(readFileSync(path), before);
  });
});

test("FIFO path is rejected promptly in an isolated process", () => {
  fixture((_root, path) => {
    assert.equal(spawnSync("mkfifo", [path]).status, 0);
    const module = new URL("../private-log.ts", import.meta.url).pathname;
    const result = spawnSync(
      process.execPath,
      [
        "--input-type=module",
        "-e",
        `
      import { createJiti } from 'jiti';
      const { appendPrivateDiagnostic } = await createJiti(import.meta.url).import(${JSON.stringify(module)});
      try { appendPrivateDiagnostic(${JSON.stringify(path)}, {}); process.exit(1); }
      catch { process.exit(0); }
    `,
      ],
      { cwd: new URL("..", import.meta.url), timeout: 10000 },
    );
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr?.toString());
  });
});
