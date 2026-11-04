// Tests for the mock LLM server (PR 6). Uses only node:test, node:assert/strict and global fetch.
// Usage numbers follow the contract's word-count rule: P = whitespace-separated words in
// messages[].content (roles are not counted); C = whitespace-separated words in the reply.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "./server.js";

// Start a server on a random free port. Returns the server and its base URL.
function start() {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, () => {
      resolve({ server, base: `http://127.0.0.1:${server.address().port}` });
    });
  });
}

// Close a server and wait until it has fully stopped.
function stop(server) {
  return new Promise((resolve, reject) => {
    server.close((err) => (err ? reject(err) : resolve()));
  });
}

// Run one test body against a fresh server, and always close the server afterwards.
async function withServer(run) {
  const { server, base } = await start();
  try {
    await run(base);
  } finally {
    await stop(server);
  }
}

// POST to /v1/chat/completions. A string body is sent as-is; an object is JSON-encoded.
function post(base, body, headers = {}) {
  return fetch(`${base}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// One known conversation: the content has 2 words ("hello", "there").
const HELLO = [{ role: "user", content: "hello there" }];

// Every error response uses one shape: { error: { message, type } }, as application/json.
async function assertErrorShape(res, status) {
  assert.equal(res.status, status);
  assert.equal(res.headers.get("content-type"), "application/json");
  const body = await res.json();
  assert.deepEqual(Object.keys(body), ["error"]);
  assert.deepEqual(Object.keys(body.error).sort(), ["message", "type"]);
  assert.equal(typeof body.error.message, "string");
  assert.ok(body.error.message.length > 0, "error message is empty");
  assert.equal(body.error.type, "invalid_request_error");
}

test("GET /health returns 200 application/json with status ok", async () => {
  await withServer(async (base) => {
    const res = await fetch(`${base}/health`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.deepEqual(await res.json(), { status: "ok" });
  });
});

// Bearer mock-llm-key is the header Kong sends after it swaps the caller's token.
test("success returns the full chat.completion shape with the internal-key reply", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: HELLO }, { authorization: "Bearer mock-llm-key" });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.deepEqual(await res.json(), {
      id: "chatcmpl-mock-1",
      object: "chat.completion",
      created: 1700000000,
      model: "mock-clinical-model",
      choices: [
        {
          index: 0,
          message: { role: "assistant", content: "mock-llm: ok (auth=internal-key)" },
          finish_reason: "stop",
        },
      ],
      // P = 2 (hello, there). C = 3 (mock-llm:, ok, (auth=none)). Total = 5.
      usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 },
    });
  });
});

test("no authorization header gives the auth=none reply", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: HELLO });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.choices[0].message.content, "mock-llm: ok (auth=none)");
  });
});

test("any other authorization header gives the auth=other reply", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: HELLO }, { authorization: "Bearer some-other-token" });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.choices[0].message.content, "mock-llm: ok (auth=other)");
  });
});

// P counts words in every message, so the system message adds to the user message.
// "You are a helpful assistant." = 5 words. "  hello   there  " = 2 words. P = 7.
test("usage counts words across all messages and ignores roles", async () => {
  await withServer(async (base) => {
    const messages = [
      { role: "system", content: "You are a helpful assistant." },
      { role: "user", content: "  hello   there  " },
    ];
    const res = await post(base, { messages });
    const body = await res.json();
    assert.deepEqual(body.usage, { prompt_tokens: 7, completion_tokens: 3, total_tokens: 10 });
  });
});

test("the reply never echoes the prompt", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: [{ role: "user", content: "zebra-marker-7741" }] });
    const body = await res.json();
    assert.doesNotMatch(body.choices[0].message.content, /zebra-marker/);
  });
});

test("the model name is echoed when the request gives one", async () => {
  await withServer(async (base) => {
    const res = await post(base, { model: "clinical-small-1", messages: HELLO });
    const body = await res.json();
    assert.equal(body.model, "clinical-small-1");
  });
});

test("the model defaults to mock-clinical-model when the request omits it", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: HELLO });
    const body = await res.json();
    assert.equal(body.model, "mock-clinical-model");
  });
});

test("stream false is accepted and returns a normal 200", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: HELLO, stream: false });
    assert.equal(res.status, 200);
  });
});

test("invalid JSON returns 400 with the error shape", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await post(base, "{not json"), 400);
  });
});

test("a body without messages returns 400", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await post(base, { model: "x" }), 400);
  });
});

test("an empty messages array returns 400", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await post(base, { messages: [] }), 400);
  });
});

test("messages that is not an array returns 400", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await post(base, { messages: "hello there" }), 400);
  });
});

test("a message without string content returns 400", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await post(base, { messages: [{ role: "user" }] }), 400);
    await assertErrorShape(await post(base, { messages: [{ role: "user", content: 42 }] }), 400);
  });
});

test("stream true returns 400 and says streaming is not supported", async () => {
  await withServer(async (base) => {
    const res = await post(base, { messages: HELLO, stream: true });
    await assertErrorShape(res.clone(), 400);
    const body = await res.json();
    assert.match(body.error.message, /stream/i);
    assert.match(body.error.message, /not supported/i);
  });
});

// The limit is 64 KB (65536 bytes). This body is valid JSON, one byte over the limit,
// so the 413 comes from size alone and not from a parse error.
test("a body over 64 KB returns 413 with the error shape", async () => {
  await withServer(async (base) => {
    const big = JSON.stringify({ messages: [{ role: "user", content: "x".repeat(64 * 1024 + 1) }] });
    assert.ok(Buffer.byteLength(big) > 64 * 1024);
    await assertErrorShape(await post(base, big), 413);
  });
});

test("an unknown path returns 404 with the error shape", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await fetch(`${base}/nope`), 404);
    await assertErrorShape(await fetch(`${base}/v1/nope`, { method: "POST", body: "{}" }), 404);
  });
});

test("a non-POST method on /v1/chat/completions returns 405 with the error shape", async () => {
  await withServer(async (base) => {
    await assertErrorShape(await fetch(`${base}/v1/chat/completions`), 405);
    await assertErrorShape(await fetch(`${base}/v1/chat/completions`, { method: "PUT", body: "{}" }), 405);
  });
});
