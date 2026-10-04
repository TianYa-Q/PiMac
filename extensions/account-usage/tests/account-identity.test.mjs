import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { accountUsageCacheKey, resolveAccountId } = await createJiti(
  import.meta.url,
).import("../account-identity.ts");
const account = (
  name,
  id,
  access = "synthetic-access",
  provider = "openai",
) => ({
  name,
  provider,
  credential: {
    type: "oauth",
    accountId: id,
    access,
    refresh: "synthetic-refresh",
    expires: 123,
  },
});

test("keys distinguish same-name replaced identities and providers, not ordering or token refresh", () => {
  const first = [account("same", "id-one"), account("other", "id-two")];
  const key = accountUsageCacheKey(first);
  assert.equal(key, accountUsageCacheKey([...first].reverse()));
  assert.equal(
    key,
    accountUsageCacheKey([account("same", "id-one", "new-access"), first[1]]),
  );
  assert.notEqual(
    key,
    accountUsageCacheKey([account("same", "replacement"), first[1]]),
  );
  assert.notEqual(
    key,
    accountUsageCacheKey([
      account("same", "id-one", "synthetic-access", "openai-codex"),
      first[1],
    ]),
  );
  assert.match(key, /^identity-v1:[a-f0-9]{64}$/u);
  for (const secret of [
    "same",
    "id-one",
    "synthetic-access",
    "synthetic-refresh",
  ])
    assert.equal(key.includes(secret), false);
});

test("opaque grants invalidate on access replacement; JWT claims preserve identity", () => {
  const jwt = (id) =>
    `header.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: id } })).toString("base64url")}.signature`;
  assert.equal(
    resolveAccountId(account("same", undefined, jwt("jwt-id")).credential),
    "jwt-id",
  );
  assert.notEqual(
    accountUsageCacheKey([account("same", undefined, "opaque-one")]),
    accountUsageCacheKey([account("same", undefined, "opaque-two")]),
  );
  for (const token of ["opaque", "a.!!!.b", "a." + "x".repeat(65537) + ".b"])
    assert.equal(
      resolveAccountId(account("same", undefined, token).credential),
      undefined,
    );
  assert.equal(
    resolveAccountId(account("same", " ", jwt("jwt-id")).credential),
    "jwt-id",
  );
});
