import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { describeQuotaError } = await createJiti(import.meta.url).import(
  "../diagnostic-error.ts",
);

test("provider-controlled metadata cannot leak secrets", () => {
  const error = new Error("Bearer secret https://private.test?token=secret");
  error.name = "SECRET_TOKEN";
  error.code = "SECRET_TOKEN";
  error.syscall = "SECRET_TOKEN";
  error.cause = new Error("secret");
  assert.deepEqual(describeQuotaError(error), {
    name: "Error",
    cause: { name: "Error" },
  });
  assert.equal(
    JSON.stringify(describeQuotaError(error)).includes("SECRET"),
    false,
  );
});

test("known transport metadata and safe HTTP statuses remain actionable", () => {
  const error = new TypeError("fetch failed");
  error.code = "ECONNRESET";
  error.syscall = "connect";
  assert.deepEqual(describeQuotaError(error), {
    name: "TypeError",
    message: "fetch failed",
    code: "ECONNRESET",
    syscall: "connect",
  });
  assert.equal(
    describeQuotaError(new Error("额度接口返回 HTTP 503。")).message,
    "额度接口返回 HTTP 503。",
  );
});

test("cycles, aggregate width and non-error values are bounded", () => {
  const error = new AggregateError(
    Array.from({ length: 100 }, () => new Error("secret")),
    "secret",
  );
  error.cause = error;
  const report = describeQuotaError(error);
  assert.equal(report.errors.length, 4);
  assert.equal(report.cause.cause.cause.cause, undefined);
  assert.equal(JSON.stringify(report).includes("secret"), false);
  assert.deepEqual(describeQuotaError({ secret: "credential" }), {
    name: "object",
  });
});
