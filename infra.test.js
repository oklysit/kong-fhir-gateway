// Static checks for the container, compose and CI files (PR 2).
// Reads text only: no YAML parser, no Docker, no dependencies.
// These tests fail until the infra files exist. They do not run Docker.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

// The four infra files, relative to the repo root.
// The Dockerfile build context is ./mock-fhir, so .dockerignore must sit in mock-fhir/.
const FILES = {
  dockerfile: "mock-fhir/Dockerfile",
  dockerignore: "mock-fhir/.dockerignore",
  compose: "docker-compose.yml",
  ci: ".github/workflows/ci.yml",
};

// Read a repo file as text. A missing file throws, so the test fails.
function read(path) {
  return readFileSync(new URL(`./${path}`, import.meta.url), "utf8");
}

test("all four infra files exist", () => {
  for (const path of Object.values(FILES)) {
    assert.ok(existsSync(new URL(`./${path}`, import.meta.url)), `missing ${path}`);
  }
});

// Dockerfile: the image is the Node 22 base, runs as the unprivileged node user,
// exposes 8080, and installs nothing (the mock has no dependencies).
test("Dockerfile starts from a node:22 base image", () => {
  assert.match(read(FILES.dockerfile), /^FROM\s+node:22/m);
});

test("Dockerfile runs as the non-root node user", () => {
  assert.match(read(FILES.dockerfile), /^USER\s+node\s*$/m);
});

test("Dockerfile exposes port 8080", () => {
  assert.match(read(FILES.dockerfile), /^EXPOSE\s+8080\b/m);
});

test("Dockerfile does not run npm install", () => {
  assert.doesNotMatch(read(FILES.dockerfile), /npm install/);
});

// Compose: one mock-fhir service, port 8080 published, ISSUER configurable,
// and a healthcheck so `--wait` can tell when the service is ready.
test("compose defines the mock-fhir service", () => {
  assert.match(read(FILES.compose), /^\s*mock-fhir:\s*$/m);
});

test("compose publishes 8080:8080", () => {
  assert.match(read(FILES.compose), /8080:8080/);
});

test("compose sets the ISSUER environment variable", () => {
  assert.match(read(FILES.compose), /\bISSUER\b/);
});

test("compose has a healthcheck", () => {
  assert.match(read(FILES.compose), /^\s*healthcheck:/m);
});

// CI: runs on pull requests, has a `test` job (unit tests) and a `compose` job
// (container proof). Both jobs use pinned major versions of the actions.
test("CI triggers on pull_request", () => {
  assert.match(read(FILES.ci), /pull_request/);
});

test("CI pins actions/checkout@v4 and actions/setup-node@v4", () => {
  const text = read(FILES.ci);
  assert.match(text, /actions\/checkout@v4/);
  assert.match(text, /actions\/setup-node@v4/);
});

test("CI runs npm test", () => {
  assert.match(read(FILES.ci), /npm test/);
});

test("CI brings the stack up and waits for health", () => {
  const text = read(FILES.ci);
  assert.match(text, /docker compose up/);
  assert.match(text, /--wait/);
});

test("CI tears the stack down", () => {
  assert.match(read(FILES.ci), /docker compose down/);
});

test("CI teardown runs even when earlier steps fail", () => {
  assert.match(read(FILES.ci), /if:\s*always\(\)/);
});

test("CI has a job keyed `test`", () => {
  assert.match(read(FILES.ci), /^\s*test:\s*$/m);
});

test("CI has a job keyed `compose`", () => {
  assert.match(read(FILES.ci), /^\s*compose:\s*$/m);
});

// No secret-looking tokens in any infra file. Patterns: GitHub PAT prefix and AWS access key prefix.
test("no infra file contains a secret-looking token", () => {
  for (const path of Object.values(FILES)) {
    const text = read(path);
    assert.doesNotMatch(text, /ghp_/, `ghp_ found in ${path}`);
    assert.doesNotMatch(text, /AKIA/, `AKIA found in ${path}`);
  }
});
