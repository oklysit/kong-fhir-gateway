// Static checks for the AI route through Kong (PR 7).
// Reads text only: no YAML parser, no Lua parser, no Docker, no dependencies.
// scripts/e2e-ai.sh is checked with `bash -n` (syntax only). It is not run here.
// These tests fail until the AI route, the handler rules, the compose and CI changes and the script exist.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The files this PR touches, relative to the repo root.
const FILES = {
  template: "kong/kong.yml.tpl",
  handler: "kong/plugins/fhir-guard/handler.lua",
  compose: "docker-compose.yml",
  ci: ".github/workflows/ci.yml",
  e2eAi: "scripts/e2e-ai.sh",
};

// Regex texts from the contract. The Kong YAML is single-quoted, so the backslashes stay literal.
const INJECTION_PATTERN = "(?i)(?:ignore|disregard)\\s+(?:all\\s+)?(?:previous|prior)\\s+instructions";
const SSN_PATTERN = "\\b\\d{3}-\\d{2}-\\d{4}\\b";

// The upstream URL that ai-proxy calls, with the port.
const MOCK_UPSTREAM = "http://mock-llm:8082/v1/chat/completions";

// Read a repo file as text. A missing file throws, so the test fails.
function read(path) {
  return readFileSync(new URL(`./${path}`, import.meta.url), "utf8");
}

// Return the lines of one service block in compose, from its key to the next key.
// A service key sits at 2-space indent. A top-level key sits at column 0.
function serviceBlock(text, name) {
  const lines = text.split("\n");
  const start = lines.findIndex((line) => new RegExp(`^  ${name}:\\s*$`).test(line));
  if (start < 0) return "";
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^(  [A-Za-z][\w-]*:|[A-Za-z])/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n");
}

// Return the text of one Kong route, from its "- name:" line to the next route or top-level key.
// Its plugins sit deeper in the indent, so they stay inside the block.
function routeBlock(text, name) {
  const lines = text.split("\n");
  const start = lines.findIndex((line) =>
    new RegExp(`^\\s*-\\s*name:\\s*["']?${name}["']?\\s*$`).test(line),
  );
  if (start < 0) return "";
  const indent = lines[start].match(/^\s*/)[0].length;
  const out = [lines[start]];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed !== "" && !trimmed.startsWith("#") && line.match(/^\s*/)[0].length <= indent) break;
    out.push(line);
  }
  return out.join("\n");
}

// The ai-chat route block, read once per test that needs it.
function aiRoute() {
  const block = routeBlock(read(FILES.template), "ai-chat");
  assert.ok(block, "route ai-chat is missing from kong/kong.yml.tpl");
  return block;
}

// True when the block names the plugin, for example `- name: ai-proxy`.
function hasPlugin(block, name) {
  return new RegExp(`name:\\s*["']?${name}["']?\\s*$`, "m").test(block);
}

// Files exist: the e2e script for the AI route.
test("scripts/e2e-ai.sh exists", () => {
  assert.ok(existsSync(new URL(`./${FILES.e2eAi}`, import.meta.url)), `missing ${FILES.e2eAi}`);
});

// Template: the mock LLM as a Kong service, and the ai-chat route on /ai/chat.
test("template has a mock-llm service at http://mock-llm:8082", () => {
  const text = read(FILES.template);
  assert.match(text, /^\s*-\s*name:\s*mock-llm\s*$/m);
  assert.match(text, /url:\s*["']?http:\/\/mock-llm:8082\/?["']?\s*$/m);
});

test("template has the ai-chat route on /ai/chat with strip_path false", () => {
  const block = aiRoute();
  assert.match(block, /paths:\s*\n\s*-\s*["']?\/ai\/chat["']?/);
  assert.match(block, /strip_path:\s*false/);
});

// The AI route runs the same token check as /fhir, and the FHIR guard (which owns the AI rules).
test("ai-chat route runs jwt with the same iss key claim and exp check as /fhir", () => {
  const block = aiRoute();
  assert.ok(hasPlugin(block, "jwt"), "ai-chat route has no jwt plugin");
  assert.match(block, /key_claim_name:\s*iss/);
  assert.match(block, /claims_to_verify/);
});

test("ai-chat route runs fhir-guard", () => {
  assert.ok(hasPlugin(aiRoute(), "fhir-guard"), "ai-chat route has no fhir-guard plugin");
});

test("ai-chat route runs rate-limiting, ai-prompt-guard and ai-proxy", () => {
  const block = aiRoute();
  assert.ok(hasPlugin(block, "rate-limiting"), "ai-chat route has no rate-limiting plugin");
  assert.ok(hasPlugin(block, "ai-prompt-guard"), "ai-chat route has no ai-prompt-guard plugin");
  assert.ok(hasPlugin(block, "ai-proxy"), "ai-chat route has no ai-proxy plugin");
});

// Rate limit on the AI route: 10 per minute, local counter, per consumer, fault tolerant.
test("ai-chat rate limit is 10 per minute, local, per consumer, fault tolerant", () => {
  const block = aiRoute();
  assert.match(block, /minute:\s*10\b/);
  assert.match(block, /policy:\s*["']?local\b/);
  assert.match(block, /limit_by:\s*["']?consumer\b/);
  assert.match(block, /fault_tolerant:\s*true/);
});

// ai-proxy: an OpenAI-style chat route to the mock model, with the internal key and no caller override.
test("ai-proxy is an llm/v1/chat openai route to the mock model on the mock upstream", () => {
  const block = aiRoute();
  assert.match(block, /route_type:\s*["']?llm\/v1\/chat\b/);
  assert.match(block, /provider:\s*["']?openai\b/);
  assert.match(block, /name:\s*["']?mock-clinical-model\b/);
  assert.ok(block.includes(MOCK_UPSTREAM), `upstream_url is not ${MOCK_UPSTREAM}`);
});

test("ai-proxy sets the internal key, refuses caller override, and logs statistics only", () => {
  const block = aiRoute();
  assert.match(block, /header_name:\s*["']?Authorization\b/);
  assert.match(block, /header_value:\s*["']?Bearer mock-llm-key\b/);
  assert.match(block, /allow_override:\s*false/);
  assert.match(block, /log_statistics:\s*true/);
  assert.match(block, /log_payloads:\s*false/);
});

// ai-prompt-guard: the two deny patterns, the whole history checked, and the body cap.
test("ai-prompt-guard denies the prompt-injection and SSN patterns", () => {
  const block = aiRoute();
  assert.ok(block.includes(INJECTION_PATTERN), "deny_patterns lacks the prompt-injection regex");
  assert.ok(block.includes(SSN_PATTERN), "deny_patterns lacks the SSN regex");
});

test("ai-prompt-guard checks all conversation history and caps the body at 8192 bytes", () => {
  const block = aiRoute();
  assert.match(block, /allow_all_conversation_history:\s*false/);
  assert.match(block, /max_request_body_size:\s*8192/);
});

// Handler: the /ai/chat branch (method, exact path, scope, deny by default) and the 400 rewrite.
test("fhir-guard admits only POST on exactly /ai/chat with the ai/chat scope", () => {
  const text = read(FILES.handler);
  assert.match(text, /\/ai\/chat/);
  assert.match(text, /["']POST["']/);
  assert.match(text, /["']ai\/chat["']/);
});

test("fhir-guard rewrites a Kong 400 into a generic invalid OperationOutcome", () => {
  const text = read(FILES.handler);
  assert.match(text, /\b400\b/);
  assert.match(text, /["']invalid["']/);
  assert.ok(text.includes("The request was rejected by the gateway."), "generic 400 diagnostics text is missing");
});

test("fhir-guard still rewrites only Kong-made answers, never the service's", () => {
  assert.match(read(FILES.handler), /source\s*~=\s*["']service["']/);
});

// Compose: kong waits for the mock LLM, and no new port is published.
test("compose kong waits for mock-llm to be healthy", () => {
  const block = serviceBlock(read(FILES.compose), "kong");
  assert.ok(block, "kong service block not found");
  assert.match(block, /mock-llm:\s*\n\s*condition:\s*service_healthy/);
});

test("compose publishes only 8000:8000 and 8081:8080", () => {
  const published = (read(FILES.compose).match(/^\s*-\s*["']?\d+:\d+["']?\s*$/gm) ?? [])
    .map((item) => item.replace(/[\s"'-]/g, ""))
    .sort();
  assert.deepEqual(published, ["8000:8000", "8081:8080"]);
});

// CI: the AI e2e step runs after the FHIR e2e step, and failure logs print mock-llm.
test("CI runs scripts/e2e-ai.sh after scripts/e2e.sh", () => {
  const text = read(FILES.ci);
  const fhir = text.indexOf("bash scripts/e2e.sh");
  const ai = text.indexOf("bash scripts/e2e-ai.sh");
  assert.ok(fhir >= 0, "CI no longer runs scripts/e2e.sh");
  assert.ok(ai > fhir, "CI does not run scripts/e2e-ai.sh after scripts/e2e.sh");
});

test("CI prints mock-llm logs in the failure step", () => {
  assert.match(read(FILES.ci), /if:\s*failure\(\)[\s\S]*docker compose logs mock-llm/);
});

// The script is syntax-checked only here. It needs Docker to run, and CI is the proof.
test("scripts/e2e-ai.sh passes bash -n", () => {
  const path = fileURLToPath(new URL(`./${FILES.e2eAi}`, import.meta.url));
  assert.doesNotThrow(() => execFileSync("bash", ["-n", path], { stdio: "pipe" }));
});

test("scripts/e2e-ai.sh names the AI route, the mock reply, the scope and the 429 check", () => {
  const text = read(FILES.e2eAi);
  for (const literal of ["/ai/chat", "mock-llm: ok (auth=internal-key)", "ai/chat", "localhost:8082", "throttled", "429"]) {
    assert.ok(text.includes(literal), `scripts/e2e-ai.sh lacks ${literal}`);
  }
});

// PR 9, S3: the prompt guard scans every role. Without match_all_roles it checks user messages only,
// so an injection or an SSN in a system or assistant message passes.
test("PR 9: ai-prompt-guard sets match_all_roles: true", () => {
  assert.match(aiRoute(), /^\s*match_all_roles:\s*true\b/m);
});

test("PR 9: the log_statistics comment does not claim the access log gets token counts", () => {
  const block = aiRoute();
  assert.match(block, /log_statistics:\s*true/);
  assert.doesNotMatch(
    block,
    /Add token counts and latency to Kong's access log/,
    "the old comment says token counts reach the access log, but no log plugin is configured",
  );
});

test("PR 9: scripts/e2e-ai.sh probes the system and assistant roles", () => {
  const text = read(FILES.e2eAi);
  assert.match(text, /"role":"system"/);
  assert.match(text, /"role":"assistant"/);
});
