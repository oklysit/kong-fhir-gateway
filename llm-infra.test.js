// Static checks for the mock LLM container files and its compose service (PR 6).
// Reads text only: no YAML parser, no Docker, no dependencies.
// These tests fail until the files exist. They do not run Docker.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

// The mock LLM files, relative to the repo root.
// The Dockerfile build context is ./mock-llm, so .dockerignore must sit in mock-llm/.
const FILES = {
  dockerfile: "mock-llm/Dockerfile",
  dockerignore: "mock-llm/.dockerignore",
  compose: "docker-compose.yml",
};

// Read a repo file as text. A missing file throws, so the test fails.
function read(path) {
  return readFileSync(new URL(`./${path}`, import.meta.url), "utf8");
}

// Return the text of one compose service block: its key line through the last line
// indented deeper than the key. Blank and comment lines never end the block.
function serviceBlock(text, name) {
  const lines = text.split("\n");
  const start = lines.findIndex((line) => new RegExp(`^\\s*${name}:\\s*$`).test(line));
  assert.ok(start >= 0, `${name} service block not found`);
  const indent = lines[start].match(/^\s*/)[0].length;
  const out = [lines[start]];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      out.push(line);
      continue;
    }
    if (line.match(/^\s*/)[0].length <= indent) break;
    out.push(line);
  }
  return out.join("\n");
}

test("the mock-llm Dockerfile, its .dockerignore and the compose file exist", () => {
  for (const path of Object.values(FILES)) {
    assert.ok(existsSync(new URL(`./${path}`, import.meta.url)), `missing ${path}`);
  }
});

// Dockerfile: the Node 22 base, the unprivileged node user, port 8082, and no npm install
// (the mock has no dependencies).
test("mock-llm Dockerfile starts from a node:22 base image", () => {
  assert.match(read(FILES.dockerfile), /^FROM\s+node:22/m);
});

test("mock-llm Dockerfile runs as the non-root node user", () => {
  assert.match(read(FILES.dockerfile), /^USER\s+node\s*$/m);
});

test("mock-llm Dockerfile exposes port 8082", () => {
  assert.match(read(FILES.dockerfile), /^EXPOSE\s+8082\b/m);
});

test("mock-llm Dockerfile does not run npm install", () => {
  assert.doesNotMatch(read(FILES.dockerfile), /npm install/);
});

test("mock-llm/.dockerignore exists", () => {
  assert.ok(existsSync(new URL(`./${FILES.dockerignore}`, import.meta.url)), `missing ${FILES.dockerignore}`);
});

// Compose: one mock-llm service, built from ./mock-llm, with a healthcheck that probes
// port 8082 with node's built-in fetch. The service publishes no host port (internal only).
test("compose defines the mock-llm service", () => {
  assert.match(read(FILES.compose), /^\s*mock-llm:\s*$/m);
});

test("compose mock-llm builds from ./mock-llm", () => {
  const block = serviceBlock(read(FILES.compose), "mock-llm");
  assert.match(block, /build:\s*\.\/mock-llm\b/);
});

test("compose mock-llm has a healthcheck that probes /health on 8082", () => {
  const block = serviceBlock(read(FILES.compose), "mock-llm");
  assert.match(block, /^\s*healthcheck:/m);
  assert.match(block, /8082\/health/);
});

test("compose mock-llm has no ports: key (internal only)", () => {
  const block = serviceBlock(read(FILES.compose), "mock-llm");
  assert.doesNotMatch(block, /^\s*ports:/m, "mock-llm still publishes ports");
});
