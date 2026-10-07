import test from "node:test";
import assert from "node:assert/strict";
import { request, APIError } from "./api.ts";
test("same-origin reads carry cookies without token headers or automatic retry", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url, init) => {
    calls++;
    assert.equal(url, "/api/v1/dans/me");
    assert.equal(init?.credentials, "same-origin");
    assert.equal(new Headers(init?.headers).has("X-API-Key"), false);
    return Response.json({ id: "user" });
  };
  try {
    assert.deepEqual(await request("/dans/me"), { id: "user" });
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = original;
  }
});
test("lost mutation responses remain unknown and are never retried", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    throw new TypeError("network error");
  };
  try {
    await assert.rejects(
      request("/zones", { method: "PATCH", body: "{}" }),
      (error) => error instanceof APIError && error.uncertain,
    );
    assert.equal(calls, 1);
  } finally {
    globalThis.fetch = original;
  }
});
test("authoritative rejection preserves details; confirmed successful status survives an invalid optional body", async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async () =>
      Response.json({ error: "forbidden" }, { status: 403 });
    await assert.rejects(
      request("/zones", { method: "PATCH" }),
      (error) =>
        error instanceof APIError && !error.uncertain && error.status === 403,
    );
    globalThis.fetch = async () => new Response("broken", { status: 201 });
    assert.equal(await request("/zones", { method: "POST" }), undefined);
  } finally {
    globalThis.fetch = original;
  }
});
test("rate-limit refusals explain the wait or the capacity and are never retried", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  try {
    globalThis.fetch = async () => {
      calls++;
      return Response.json(
        { error: "Rate exceeded", errors: ["bucket: changes"] },
        {
          status: 429,
          headers: { "Retry-After": "3", "X-DANS-RateLimit-Bucket": "changes" },
        },
      );
    };
    await assert.rejects(
      request("/servers/localhost/zones/example.org.", {
        method: "PATCH",
        body: "{}",
      }),
      (error) =>
        error instanceof APIError &&
        !error.uncertain &&
        error.status === 429 &&
        error.retryAfter === 3 &&
        error.message.includes("changes") &&
        error.message.includes("Wait 3 seconds") &&
        error.message.includes("not applied"),
    );
    assert.equal(calls, 1);

    globalThis.fetch = async () =>
      Response.json(
        {
          error: "request cost exceeds rate-limit capacity",
          errors: ["bucket: changes", "cost: 60", "capacity: 50"],
        },
        { status: 413, headers: { "X-DANS-RateLimit-Bucket": "changes" } },
      );
    await assert.rejects(
      request("/servers/localhost/zones/example.org.", {
        method: "PATCH",
        body: "{}",
      }),
      (error) =>
        error instanceof APIError &&
        error.status === 413 &&
        error.retryAfter === undefined &&
        error.message.includes("cost 60, capacity 50") &&
        error.message.includes("Split it"),
    );

    globalThis.fetch = async () =>
      Response.json({ error: "request body too large" }, { status: 413 });
    await assert.rejects(
      request("/zones", { method: "PATCH", body: "{}" }),
      (error) =>
        error instanceof APIError && error.message === "request body too large",
    );
  } finally {
    globalThis.fetch = original;
  }
});
