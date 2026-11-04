// Mock LLM server: answers OpenAI-style chat completion requests with fixed text.
// Uses only node:http and node:url. No model, no API key, no dependencies.
import { createServer as createHttpServer } from "node:http";
import { fileURLToPath } from "node:url";

// The largest request body we accept, in bytes: 64 KB.
const MAX_BODY_BYTES = 64 * 1024;

// Model name echoed back when the request does not give a string model.
const DEFAULT_MODEL = "mock-clinical-model";

// Fixed "created" timestamp, so every reply is the same for the same input.
const CREATED = 1700000000;

// Send a JSON body with a status, the JSON content type and optional extra headers.
function send(res, status, body, extraHeaders = {}) {
  // A fixed length avoids chunked encoding, so raw clients can read the body as plain JSON.
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(text),
    ...extraHeaders,
  });
  res.end(text);
}

// Send the one error shape this server uses: { error: { message, type } }.
function sendError(res, status, message, extraHeaders = {}) {
  send(res, status, { error: { message, type: "invalid_request_error" } }, extraHeaders);
}

// Count words: split on any run of whitespace. A leading or trailing space makes an empty
// piece, and filter(Boolean) drops it.
function countWords(text) {
  return text.split(/\s+/).filter(Boolean).length;
}

// Name the caller from its authorization header. Kong swaps the caller's token for the
// internal key, so "internal-key" proves the swap happened.
function authLabel(header) {
  if (header === undefined) return "none";
  if (header === "Bearer mock-llm-key") return "internal-key";
  return "other";
}

// Read the request body up to MAX_BODY_BYTES. Resolves to { text } on a full read, or to
// { tooLarge: true } as soon as the cap is passed. The cap stops the buffering, not the reading:
// after the answer is decided, the data handler keeps draining bytes, so the client can finish
// sending and read our reply instead of hitting a reset socket.
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let done = false;
    req.on("data", (chunk) => {
      // Already answered: drop the bytes and keep the stream flowing.
      if (done) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        done = true;
        resolve({ tooLarge: true });
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (done) return;
      done = true;
      resolve({ text: Buffer.concat(chunks).toString("utf8") });
    });
    req.on("error", (err) => {
      if (done) return;
      done = true;
      reject(err);
    });
  });
}

// Handle one chat completion request. Only POST is allowed on this path.
async function chatCompletions(req, res) {
  if (req.method !== "POST") {
    // A 405 must say which method is allowed, so it carries an allow header.
    return sendError(res, 405, `Method ${req.method} is not supported`, { allow: "POST" });
  }

  const { text, tooLarge } = await readBody(req);
  if (tooLarge) return sendError(res, 413, `Request body is larger than ${MAX_BODY_BYTES} bytes`);

  // JSON.parse throws on bad input, so a parse failure becomes a 400.
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return sendError(res, 400, "Request body is not valid JSON");
  }

  // Reject null, arrays and numbers: only a plain object can carry "messages".
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return sendError(res, 400, "Request body must be a JSON object");
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return sendError(res, 400, "messages must be a non-empty array");
  }
  // Optional chaining (m?.content) means a null entry fails the check instead of throwing.
  if (!body.messages.every((m) => typeof m?.content === "string")) {
    return sendError(res, 400, "every message needs string content");
  }
  if (body.stream === true) {
    return sendError(res, 400, "streaming is not supported by the mock");
  }

  // The reply names the auth case only. It never repeats the prompt.
  const reply = `mock-llm: ok (auth=${authLabel(req.headers.authorization)})`;

  // Usage: prompt words across all messages (roles are not counted), reply words as completion.
  const promptTokens = body.messages.reduce((sum, m) => sum + countWords(m.content), 0);
  const completionTokens = countWords(reply);

  return send(res, 200, {
    id: "chatcmpl-mock-1",
    object: "chat.completion",
    created: CREATED,
    // Echo a string model from the request; otherwise use the default.
    model: typeof body.model === "string" ? body.model : DEFAULT_MODEL,
    choices: [
      { index: 0, message: { role: "assistant", content: reply }, finish_reason: "stop" },
    ],
    usage: {
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      total_tokens: promptTokens + completionTokens,
    },
  });
}

// Route one request by path first, so an unknown path is a 404 whatever the method.
async function handle(req, res) {
  // Take only the path, so a query string like ?foo=1 does not break routing.
  // A malformed request line is a client error, so 400.
  let path;
  try {
    path = new URL(req.url, "http://localhost").pathname;
  } catch {
    return sendError(res, 400, "Invalid request path");
  }

  if (path === "/health") {
    // Health is GET only, like the mock FHIR server.
    if (req.method !== "GET") return sendError(res, 405, `Method ${req.method} is not supported`, { allow: "GET" });
    return send(res, 200, { status: "ok" });
  }
  if (path === "/v1/chat/completions") return chatCompletions(req, res);

  // Anything else is a 404.
  return sendError(res, 404, `No resource at ${req.method} ${path}`);
}

// Build the server without listening. Tests call listen(0) to get a free port.
export function createServer() {
  // The handler is async, so a read error becomes a 400 here instead of an unhandled rejection.
  return createHttpServer((req, res) =>
    handle(req, res).catch(() => {
      // headersSent stops a second write after a reply already started.
      if (!res.headersSent) sendError(res, 400, "Request could not be read");
    }),
  );
}

// Run directly (node mock-llm/server.js): listen on PORT or 8082.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = process.env.PORT || 8082;
  createServer().listen(port, () => {
    console.log(`Mock LLM server listening on port ${port}`);
  });
}
