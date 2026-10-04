import assert from "node:assert/strict";
import { test } from "node:test";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  truncateSync,
  writeFileSync,
  mkdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url);
const { readPrivateRegularFile, writePrivateJson, MAX_PRIVATE_JSON_BYTES } =
  await jiti.import("../private-json.ts");

function fixture(run) {
  const root = mkdtempSync(join(tmpdir(), "private-json-"));
  try {
    run(root, join(root, "data.json"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("atomic JSON round-trip enforces private permissions", () =>
  fixture((root, path) => {
    writePrivateJson(path, { value: "中文 😀" });
    assert.deepEqual(JSON.parse(readPrivateRegularFile(path)), {
      value: "中文 😀",
    });
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.equal(statSync(root).mode & 0o777, 0o700);
    assert.deepEqual(readdirSync(root), ["data.json"]);
  }));

test("reads accept exactly the byte limit and reject oversized sparse files", () =>
  fixture((_, path) => {
    writeFileSync(path, "a".repeat(MAX_PRIVATE_JSON_BYTES));
    assert.equal(readPrivateRegularFile(path).length, MAX_PRIVATE_JSON_BYTES);
    truncateSync(path, MAX_PRIVATE_JSON_BYTES + 1);
    assert.throws(() => readPrivateRegularFile(path), /4 MiB/u);
  }));

test("invalid UTF-8 cannot silently change persisted credentials", () =>
  fixture((_, path) => {
    writeFileSync(path, Buffer.from([0xff, 0xfe]));
    assert.throws(() => readPrivateRegularFile(path), /UTF-8/u);
  }));

test("symlinks and directories are rejected", () =>
  fixture((root, path) => {
    const target = join(root, "target");
    writeFileSync(target, "{}");
    symlinkSync(target, path);
    assert.throws(() => readPrivateRegularFile(path));
    assert.throws(() => readPrivateRegularFile(root), /普通文件/u);
  }));

test(
  "FIFO read fails immediately instead of blocking Pi",
  { timeout: 2000 },
  () =>
    fixture((_, path) => {
      execFileSync("mkfifo", [path]);
      assert.throws(() => readPrivateRegularFile(path), /普通文件/u);
    }),
);

test("oversized writes leave the previous document untouched", () =>
  fixture((root, path) => {
    writePrivateJson(path, { previous: true });
    assert.throws(
      () => writePrivateJson(path, "x".repeat(MAX_PRIVATE_JSON_BYTES)),
      /4 MiB/u,
    );
    assert.deepEqual(JSON.parse(readFileSync(path, "utf8")), {
      previous: true,
    });
    assert.deepEqual(readdirSync(root), ["data.json"]);
  }));

test("failed replacement removes its temporary file", () =>
  fixture((root, path) => {
    mkdirSync(path);
    assert.throws(() => writePrivateJson(path, { value: true }));
    assert.deepEqual(readdirSync(root), ["data.json"]);
  }));
