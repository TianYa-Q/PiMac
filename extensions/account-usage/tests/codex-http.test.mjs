import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createJiti } from "jiti";

const root = await mkdtemp(join(tmpdir(), "quota-http-tests-"));
process.env.PI_CODING_AGENT_DIR = root;
process.env.PI_OFFLINE = "1";
const { queryAccountUsage } = await createJiti(import.meta.url).import(
  "../codex.ts",
);
const originalFetch = globalThis.fetch;
const account = {
  name: "synthetic",
  provider: "openai",
  credential: {
    type: "oauth",
    access: "synthetic-access",
    refresh: "synthetic-refresh",
    expires: Date.now() + 3_600_000,
    accountId: "synthetic-id",
  },
};
const usage = () =>
  Response.json({
    rate_limit: {
      primary_window: { used_percent: 20, reset_at: 2_000_000_000 },
    },
  });

try {
  await test("HTTP failures cancel response bodies and never expose their contents", async () => {
    let cancelled = false;
    globalThis.fetch = async () =>
      new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
        { status: 403 },
      );
    const result = await queryAccountUsage(
      account,
      new AbortController().signal,
    );
    assert.equal(cancelled, true);
    assert.equal(result.primary, undefined);
    assert.equal(result.error, "额度接口返回 HTTP 403。");
  });

  await test("supplementary HTTP errors cancel their body without hiding usage", async () => {
    let cancelled = false;
    globalThis.fetch = async (url) =>
      String(url).endsWith("/usage")
        ? usage()
        : new Response(
            new ReadableStream({
              cancel() {
                cancelled = true;
              },
            }),
            { status: 500 },
          );
    const result = await queryAccountUsage(
      account,
      new AbortController().signal,
    );
    assert.equal(cancelled, true);
    assert.equal(result.primary.remainingPercent, 80);
    assert.equal(result.resetCredits, undefined);
    assert.equal(result.error, undefined);
  });

  await test("oversized supplementary chunked JSON preserves valid usage", async () => {
    let cancelled = false;
    globalThis.fetch = async (url) =>
      String(url).endsWith("/usage")
        ? usage()
        : new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(new Uint8Array(65 * 1024));
              },
              cancel() {
                cancelled = true;
              },
            }),
          );
    const result = await queryAccountUsage(
      account,
      new AbortController().signal,
    );
    assert.equal(cancelled, true);
    assert.equal(result.primary.remainingPercent, 80);
    assert.equal(result.resetCredits, undefined);
    assert.equal(result.error, undefined);
  });
} finally {
  globalThis.fetch = originalFetch;
  await rm(root, { recursive: true, force: true });
}
