// Static checks for the Kong gateway (PR 4).
// Reads text only: no YAML parser, no Lua parser, no Docker, no dependencies.
// The e2e script is checked with `bash -n` (syntax only). It is not run here.
// These tests fail until the Kong files, the compose changes and the CI change exist.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

// The files this PR adds or changes, relative to the repo root.
const FILES = {
  template: "kong/kong.yml.tpl",
  render: "kong/render.sh",
  handler: "kong/plugins/fhir-guard/handler.lua",
  schema: "kong/plugins/fhir-guard/schema.lua",
  e2e: "scripts/e2e.sh",
  compose: "docker-compose.yml",
  ci: ".github/workflows/ci.yml",
};

// The issuer the token carries. Kong's consumer key must equal it.
const ISSUER = "http://localhost:8081/realms/fhir";

// The placeholder that render.sh replaces with the Keycloak public key.
const PLACEHOLDER = "__KEYCLOAK_PUBLIC_KEY_PEM__";

// Read a repo file as text. A missing file throws, so the test fails.
function read(path) {
  return readFileSync(new URL(`./${path}`, import.meta.url), "utf8");
}

// Return the lines of one service block in compose, from its key to the next key.
// A service key sits at 2-space indent. A top-level key sits at column 0.
// Comment lines do not end the block.
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

// Return every item of every `ports:` list in a text. A list item is a line that
// starts with "-" at a deeper indent than its `ports:` key. Quotes are removed.
function portItems(text) {
  const items = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const key = lines[i].match(/^(\s*)ports:\s*$/);
    if (!key) continue;
    const indent = key[1].length;
    for (let j = i + 1; j < lines.length; j++) {
      const line = lines[j];
      if (line.trim() === "" || line.trim().startsWith("#")) continue;
      const item = line.match(/^(\s*)-\s*(.+)$/);
      if (!item || item[1].length <= indent) break;
      items.push(item[2].replace(/["']/g, "").trim());
    }
  }
  return items;
}

// Split the `routes:` list of the template into one text chunk per route.
// A route starts at the list's own "- " indent and runs to the next route.
function routeChunks(text) {
  const lines = text.split("\n");
  const at = lines.findIndex((line) => /^\s*routes:\s*$/.test(line));
  if (at < 0) return [];
  const first = lines.findIndex((line, i) => i > at && /^\s*-\s/.test(line));
  if (first < 0) return [];
  const indent = lines[first].match(/^(\s*)/)[1];
  const chunks = [];
  let current = null;
  for (let i = first; i < lines.length; i++) {
    const line = lines[i];
    const lineIndent = line.match(/^(\s*)/)[1];
    // A non-empty line less indented than the list means the routes list has ended.
    if (line.trim() !== "" && lineIndent.length < indent.length) break;
    if (line.startsWith(`${indent}- `)) {
      current = [];
      chunks.push(current);
    }
    if (current) current.push(line);
  }
  return chunks.map((chunk) => chunk.join("\n"));
}

// Files exist: every file this PR adds.
test("all Kong PR 4 files exist", () => {
  for (const path of Object.values(FILES)) {
    assert.ok(existsSync(new URL(`./${path}`, import.meta.url)), `missing ${path}`);
  }
});

// Compose: the kong service. Pinned image, DB-less, the fhir-guard plugin, and its
// startup order. Each check reads only the kong block.
test("compose kong image is pinned to kong:3.9.4, not latest", () => {
  const block = serviceBlock(read(FILES.compose), "kong");
  assert.ok(block, "kong service block not found");
  assert.match(block, /^\s*image:\s*["']?kong:3\.9\.4["']?\s*$/m);
  assert.doesNotMatch(block, /kong:latest\b/);
});

test("compose kong runs DB-less (KONG_DATABASE is off)", () => {
  const block = serviceBlock(read(FILES.compose), "kong");
  assert.match(block, /KONG_DATABASE:\s*["']?off["']?/);
});

test("compose kong loads the fhir-guard plugin", () => {
  const block = serviceBlock(read(FILES.compose), "kong");
  assert.match(block, /KONG_PLUGINS:[^\n]*\bfhir-guard\b/);
});

test("compose kong mounts its plugin dir and config read-only (two or more :ro mounts)", () => {
  const block = serviceBlock(read(FILES.compose), "kong");
  const ro = block.match(/:ro["']?\s*$/gm) ?? [];
  assert.ok(ro.length >= 2, `expected two or more :ro mounts, found ${ro.length}`);
});

test("compose kong waits for kong-config to finish and for mock-fhir to be healthy", () => {
  const text = read(FILES.compose);
  const block = serviceBlock(text, "kong");
  assert.match(block, /kong-config:/);
  assert.match(block, /service_completed_successfully/);
  assert.match(block, /mock-fhir:/);
  assert.match(block, /service_healthy/);
  assert.match(text, /^\s*kong-config:\s*$/m, "kong-config service is missing");
});

// Compose: the only published Kong port is 8000. The admin API (8001) and the
// status listener (8100) must not be published to the host.
test("compose kong publishes only 8000:8000", () => {
  const block = serviceBlock(read(FILES.compose), "kong");
  assert.deepEqual(portItems(block), ["8000:8000"]);
});

test("no ports: entry in any service publishes 8001 or 8100", () => {
  const items = portItems(read(FILES.compose));
  const bad = items.filter((item) => /\b(8001|8100)\b/.test(item));
  assert.deepEqual(bad, [], `admin or status port is published: ${bad.join(", ")}`);
});

// Compose: mock-fhir is internal only. Kong is the only way in.
test("compose mock-fhir has no published ports", () => {
  const block = serviceBlock(read(FILES.compose), "mock-fhir");
  assert.ok(block, "mock-fhir service block not found");
  assert.doesNotMatch(block, /^\s*ports:/m, "mock-fhir still publishes ports");
});

// Template: the declarative Kong config. JWT is checked with RS256 against the
// Keycloak key; the discovery route is open.
test("template enables the jwt plugin with RS256, and verifies exp", () => {
  const text = read(FILES.template);
  assert.match(text, /\bjwt\b/);
  assert.match(text, /RS256/);
  assert.match(text, /claims_to_verify/);
  assert.match(text, /claims_to_verify[\s\S]{0,80}\bexp\b/);
});

test("template consumer keycloak-fhir has the issuer key, RS256 and the public key placeholder", () => {
  const text = read(FILES.template);
  assert.match(text, /keycloak-fhir/);
  assert.ok(text.includes(ISSUER), `template does not carry the issuer key ${ISSUER}`);
  assert.match(text, /algorithm:\s*["']?RS256["']?/);
  assert.match(text, /rsa_public_key:[\s\S]*__KEYCLOAK_PUBLIC_KEY_PEM__/);
  assert.ok(text.includes(PLACEHOLDER), `template lacks ${PLACEHOLDER}`);
});

test("template service mock-fhir points at http://mock-fhir:8080", () => {
  assert.ok(read(FILES.template).includes("http://mock-fhir:8080"));
});

test("template discovery route has no auth plugin (no jwt, no fhir-guard)", () => {
  const chunks = routeChunks(read(FILES.template));
  const discovery = chunks.find((chunk) => chunk.includes("/.well-known/smart-configuration"));
  assert.ok(discovery, "no route for /.well-known/smart-configuration");
  assert.doesNotMatch(discovery, /\bjwt\b/, "discovery route has a jwt plugin");
  assert.doesNotMatch(discovery, /fhir-guard/, "discovery route has fhir-guard");
});

test("template fhir route runs jwt, then fhir-guard", () => {
  const chunks = routeChunks(read(FILES.template));
  const fhir = chunks.find((chunk) => /\/fhir\b/.test(chunk) && !chunk.includes("smart-configuration"));
  assert.ok(fhir, "no route for /fhir");
  const jwt = fhir.indexOf("jwt");
  const guard = fhir.indexOf("fhir-guard");
  assert.ok(jwt >= 0, "fhir route has no jwt plugin");
  assert.ok(guard >= 0, "fhir route has no fhir-guard plugin");
  assert.ok(jwt < guard, "jwt must come before fhir-guard");
});

// render.sh: the one-shot container that fills the template from Keycloak.
test("render.sh fails loudly: set -eu", () => {
  assert.match(read(FILES.render), /^\s*set -eu\b/m);
});

test("render.sh reads the public key from Keycloak and wraps it as a PEM", () => {
  const text = read(FILES.render);
  assert.match(text, /http:\/\/keycloak:8080\/realms\/fhir/);
  assert.match(text, /public_key/);
  assert.match(text, /BEGIN PUBLIC KEY/);
  assert.match(text, /\bjq\b/);
});

// handler.lua: the fhir-guard plugin. Its priority must sit below jwt (1450).
test("handler.lua PRIORITY is lower than the jwt plugin's 1450", () => {
  const match = read(FILES.handler).match(/PRIORITY\s*=\s*(\d+)/);
  assert.ok(match, "handler.lua has no PRIORITY");
  assert.ok(Number(match[1]) < 1450, `PRIORITY ${match[1]} is not lower than 1450`);
});

test("handler.lua reads the verified token and its claims", () => {
  const text = read(FILES.handler);
  assert.match(text, /authenticated_jwt_token/);
  assert.match(text, /jwt_parser/);
});

test("handler.lua checks the patient/Patient.read scope and denies with forbidden or login", () => {
  const text = read(FILES.handler);
  assert.match(text, /patient\/Patient\.read/);
  assert.match(text, /forbidden/);
  assert.match(text, /login/);
});

test("handler.lua rewrites Kong errors as OperationOutcome in header_filter and body_filter", () => {
  const text = read(FILES.handler);
  assert.match(text, /OperationOutcome/);
  assert.match(text, /application\/fhir\+json/);
  assert.match(text, /body_filter/);
  assert.match(text, /header_filter/);
});

// No private key anywhere in the files this PR touches.
test("no PRIVATE KEY string in the PR 4 files", () => {
  for (const path of Object.values(FILES)) {
    assert.doesNotMatch(read(path), /PRIVATE KEY/, `PRIVATE KEY found in ${path}`);
  }
});

// CI: the compose job runs the e2e script, and keeps the failure logs and the teardown.
test("CI runs scripts/e2e.sh", () => {
  assert.match(read(FILES.ci), /scripts\/e2e\.sh/);
});

test("CI prints kong and kong-config logs on failure", () => {
  const text = read(FILES.ci);
  assert.match(text, /if:\s*failure\(\)/);
  assert.match(text, /docker compose logs\b[^\n]*\bkong(\s|$)/m);
  assert.match(text, /docker compose logs\b[^\n]*\bkong-config\b/);
});

test("CI keeps the always() teardown and the test and compose job keys", () => {
  const text = read(FILES.ci);
  assert.match(text, /if:\s*always\(\)/);
  assert.match(text, /^\s*test:\s*$/m);
  assert.match(text, /^\s*compose:\s*$/m);
});

// e2e.sh: the end-to-end script. Syntax is checked with `bash -n`. It is not run,
// because it needs Docker.
test("e2e.sh passes bash -n (syntax check)", () => {
  // execFileSync throws on a non-zero exit, which fails the test with bash's message.
  execFileSync("bash", ["-n", new URL(`./${FILES.e2e}`, import.meta.url).pathname], { stdio: "pipe" });
});

test("e2e.sh uses set -u and targets Kong on 8000 and Keycloak on 8081", () => {
  const text = read(FILES.e2e);
  assert.match(text, /^\s*set\s+-[a-zA-Z]*u[a-zA-Z]*\b/m);
  assert.match(text, /localhost:8000\b/);
  assert.match(text, /localhost:8081\b/);
});

test("e2e.sh gets tokens from fhir-demo with the password grant for ada and ben", () => {
  const text = read(FILES.e2e);
  assert.match(text, /fhir-demo/);
  assert.match(text, /password/);
  assert.match(text, /\bada\b/);
  assert.match(text, /\bben\b/);
});

test("e2e.sh checks the two negative proofs: mock on 8080 and admin on 8001 are unreachable", () => {
  const text = read(FILES.e2e);
  assert.match(text, /localhost:8080\b/);
  assert.match(text, /localhost:8001\b/);
});

test("e2e.sh exits non-zero on the first failed check", () => {
  assert.match(read(FILES.e2e), /exit 1\b/);
});
