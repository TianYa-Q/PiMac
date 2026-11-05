import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import * as Effect from "effect/Effect";
import { preparePiAccountQuota } from "../pi-account-preflight.js";

const patches = JSON.parse(
  await readFile(new URL("../patches.json", import.meta.url), "utf8"),
) as Record<string, { oldText: string; newText: string }[]>;
const patch = patches["packages/provider-pi/src/server/adapter.ts"]!.find(
  (patch) => patch.newText.includes("preparePiAccountQuota(quotaModel)"),
)!;
const preflight = patch.newText.slice(
  0,
  patch.newText.indexOf("            const startedAt"),
);

// 执行真正注入 adapter 的 Effect 片段，不用字符串包含断言冒充执行顺序验证。
function run(
  model: unknown,
  payload: object | null,
  sample: () => Promise<void>,
  sent: string[],
) {
  const execute = new Function(
    "Effect",
    "getNative",
    "request",
    "recordField",
    "payload",
    "sent",
    `
    return Effect.gen(function* () {
      ${preflight}
      yield* Effect.sync(() => sent.push('prompt'));
    });
  `,
  ) as (...args: unknown[]) => Effect.Effect<void, unknown>;
  return Effect.runPromise(
    execute(
      Effect,
      () => ({
        preparePiAccountQuota: (model: unknown) =>
          preparePiAccountQuota(model, {
            accountStatus: async () => {
              sent.push("sample");
              await sample();
              sent.push("snapshot-written");
            },
          }),
      }),
      (command: { type: string }) =>
        Effect.sync(() => {
          sent.push(command.type);
          return { model };
        }),
      (value: Record<string, unknown>, key: string) => value[key],
      payload,
      sent,
    ),
  );
}

test("adapter waits for host snapshot before prompting and bypasses virtual/other providers and compaction", async () => {
  const sent: string[] = [];
  let release: (() => void) | undefined;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const flight = run(
    { provider: "openai-codex", api: "openai-codex-responses" },
    {},
    () => gate,
    sent,
  );
  try {
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(sent, ["get_state", "sample"]);
    release!();
    await flight;
    assert.deepEqual(sent, [
      "get_state",
      "sample",
      "snapshot-written",
      "prompt",
    ]);
  } finally {
    release?.();
    await flight;
  }
  for (const model of [
    { provider: "test" },
    { provider: "openai", api: "pi-virtual" },
  ]) {
    const sent: string[] = [];
    await run(
      model,
      {},
      async () => {
        throw new Error("Must not sample");
      },
      sent,
    );
    assert.deepEqual(sent, ["get_state", "prompt"]);
  }
  const compact: string[] = [];
  await run(
    { provider: "openai" },
    null,
    async () => {
      throw new Error("Must not sample");
    },
    compact,
  );
  assert.deepEqual(compact, ["prompt"]);
});

test("telemetry failure is non-fatal and never injects or replays a user prompt", async () => {
  const sent: string[] = [];
  await run(
    { provider: "openai" },
    {},
    async () => {
      throw new Error("private-upstream-error");
    },
    sent,
  );
  assert.deepEqual(sent, ["get_state", "sample", "prompt"]);
});
