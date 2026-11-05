// Static checks for the Keycloak login server (PR 3).
// Reads text and parses the realm JSON. No YAML parser, no Docker, no dependencies.
// These tests fail until the realm file, the compose service and the CI steps exist.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

// The files this PR touches, relative to the repo root.
const FILES = {
  realm: "keycloak/realm-fhir.json",
  compose: "docker-compose.yml",
  ci: ".github/workflows/ci.yml",
};

// Read a repo file as text. A missing file throws, so the test fails.
function read(path) {
  return readFileSync(new URL(`./${path}`, import.meta.url), "utf8");
}

// Read and parse the realm export. Invalid JSON or a missing file throws.
function loadRealm() {
  return JSON.parse(read(FILES.realm));
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

// Return an attribute value as an array. Keycloak exports attributes as arrays,
// so a plain string is accepted too.
function attributeValues(user, name) {
  const value = user.attributes?.[name];
  return Array.isArray(value) ? value : [value];
}

// Walk any JSON value and collect every non-empty value stored under a key named `secret`.
function findSecrets(node, found = []) {
  if (Array.isArray(node)) {
    for (const item of node) findSecrets(item, found);
  } else if (node && typeof node === "object") {
    for (const [key, value] of Object.entries(node)) {
      if (key === "secret" && value !== "" && value !== null && value !== undefined && value !== false) {
        found.push(value);
      }
      findSecrets(value, found);
    }
  }
  return found;
}

// Files exist: the realm file and the compose keycloak service.
test("keycloak realm file exists", () => {
  assert.ok(existsSync(new URL(`./${FILES.realm}`, import.meta.url)), `missing ${FILES.realm}`);
});

test("compose defines the keycloak service", () => {
  assert.match(read(FILES.compose), /^\s*keycloak:\s*$/m);
});

// Realm: the realm itself is `fhir`, enabled, and skips SSL (demo only).
test("realm is `fhir`, enabled, and sslRequired is none", () => {
  const realm = loadRealm();
  assert.equal(realm.realm, "fhir");
  assert.equal(realm.enabled, true);
  assert.equal(realm.sslRequired, "none");
});

// Client `fhir-demo`: a public client with the auth-code flow, the password grant
// (demo and CI only) and PKCE S256. Redirects are limited to localhost.
test("client fhir-demo is public with PKCE S256", () => {
  const client = loadRealm().clients?.find((c) => c.clientId === "fhir-demo");
  assert.ok(client, "client fhir-demo is missing");
  assert.equal(client.publicClient, true);
  assert.equal(client.standardFlowEnabled, true);
  assert.equal(client.directAccessGrantsEnabled, true);
  assert.ok(client.redirectUris?.includes("http://localhost:*"), "redirect is not http://localhost:*");
  assert.equal(client.attributes?.["pkce.code.challenge.method"], "S256");
});

// Both scopes must exist as realm client scopes and be optional scopes of fhir-demo.
test("launch/patient and patient/Patient.read exist and are optional scopes of fhir-demo", () => {
  const realm = loadRealm();
  const client = realm.clients?.find((c) => c.clientId === "fhir-demo");
  assert.ok(client, "client fhir-demo is missing");
  for (const name of ["launch/patient", "patient/Patient.read"]) {
    assert.ok(
      realm.clientScopes?.some((scope) => scope.name === name),
      `client scope ${name} does not exist`,
    );
    assert.ok(
      client.optionalClientScopes?.includes(name),
      `client scope ${name} is not an optional scope of fhir-demo`,
    );
  }
});

// The AI scope (PR 7): ai/chat exists as a client scope and is an optional scope of fhir-demo.
test("ai/chat exists and is an optional scope of fhir-demo", () => {
  const realm = loadRealm();
  const client = realm.clients?.find((c) => c.clientId === "fhir-demo");
  assert.ok(client, "client fhir-demo is missing");
  assert.ok(
    realm.clientScopes?.some((scope) => scope.name === "ai/chat"),
    "client scope ai/chat does not exist",
  );
  assert.ok(client.optionalClientScopes?.includes("ai/chat"), "ai/chat is not an optional scope of fhir-demo");
});

// Users: ada is patient-1 and ben is patient-2. Each user is enabled, has a verified
// email, and has a non-temporary password that equals the username (synthetic).
test("users ada and ben exist, are enabled, and email-verified", () => {
  const users = loadRealm().users ?? [];
  for (const username of ["ada", "ben"]) {
    const user = users.find((u) => u.username === username);
    assert.ok(user, `user ${username} is missing`);
    assert.equal(user.enabled, true, `${username} is not enabled`);
    assert.equal(user.emailVerified, true, `${username} email is not verified`);
  }
});

test("ada has patient attribute patient-1 and ben has patient-2", () => {
  const users = loadRealm().users ?? [];
  const expected = { ada: "patient-1", ben: "patient-2" };
  for (const [username, patient] of Object.entries(expected)) {
    const user = users.find((u) => u.username === username);
    assert.ok(user, `user ${username} is missing`);
    assert.deepEqual(attributeValues(user, "patient"), [patient], `${username} patient attribute`);
  }
});

test("ada and ben have non-temporary password credentials equal to their usernames", () => {
  const users = loadRealm().users ?? [];
  for (const username of ["ada", "ben"]) {
    const user = users.find((u) => u.username === username);
    assert.ok(user, `user ${username} is missing`);
    const ok = user.credentials?.some(
      (c) => c.type === "password" && c.value === username && c.temporary !== true,
    );
    assert.ok(ok, `${username} lacks a non-temporary password credential equal to the username`);
  }
});

// Mapper: an attribute mapper on fhir-demo copies the `patient` user attribute into
// a String claim named `patient`, and puts it in the access token.
test("fhir-demo has a mapper from the patient attribute to the patient claim", () => {
  const client = loadRealm().clients?.find((c) => c.clientId === "fhir-demo");
  assert.ok(client, "client fhir-demo is missing");
  const mapper = client.protocolMappers?.find(
    (m) => m.protocolMapper === "oidc-usermodel-attribute-mapper" && m.config?.["user.attribute"] === "patient",
  );
  assert.ok(mapper, "no oidc-usermodel-attribute-mapper reads the patient attribute");
  assert.equal(mapper.config["claim.name"], "patient", "claim name is not patient");
  assert.equal(mapper.config["jsonType.label"], "String", "claim JSON type is not String");
  assert.equal(mapper.config["access.token.claim"], "true", "mapper does not add the claim to the access token");
});

// No real secrets: the only passwords are the synthetic ones. No `secret` field may hold a value.
test("realm file has no non-empty secret field", () => {
  const secrets = findSecrets(loadRealm());
  assert.deepEqual(secrets, [], "a secret field has a value");
});

// Compose keycloak service: pinned 26.x image, start-dev with the realm import,
// port 8081 on the host, KC_HOSTNAME for the issuer, a healthcheck, and the realm file
// mounted read-only. Each check reads only the keycloak block.
test("compose keycloak image is pinned to keycloak 26.x.y, not latest", () => {
  const block = serviceBlock(read(FILES.compose), "keycloak");
  assert.ok(block, "keycloak service block not found");
  assert.match(block, /quay\.io\/keycloak\/keycloak:26\.\d+\.\d+\b/);
  assert.doesNotMatch(block, /keycloak:latest\b/);
});

test("compose keycloak command is start-dev --import-realm", () => {
  const block = serviceBlock(read(FILES.compose), "keycloak");
  assert.match(block, /start-dev\b[^\n]*--import-realm/);
});

test("compose publishes keycloak on 8081:8080", () => {
  const block = serviceBlock(read(FILES.compose), "keycloak");
  assert.match(block, /["']?8081:8080["']?/);
});

test("compose sets KC_HOSTNAME to the issuer host and port", () => {
  const block = serviceBlock(read(FILES.compose), "keycloak");
  assert.match(block, /KC_HOSTNAME:\s*["']?http:\/\/localhost:8081\/?["']?/);
});

test("compose keycloak has a healthcheck", () => {
  const block = serviceBlock(read(FILES.compose), "keycloak");
  assert.match(block, /^\s*healthcheck:/m);
});

test("compose mounts the realm file read-only at the import path", () => {
  const block = serviceBlock(read(FILES.compose), "keycloak");
  assert.match(block, /keycloak\/realm-fhir\.json["']?:\/opt\/keycloak\/data\/import\/realm-fhir\.json:ro/);
});

// CI: the failure logs for the keycloak service. The token checks now live in scripts/e2e.sh.
test("CI prints keycloak logs on failure", () => {
  const text = read(FILES.ci);
  assert.match(text, /docker compose logs keycloak/);
  assert.match(text, /if:\s*failure\(\)/);
});

test("CI keeps the always() teardown", () => {
  assert.match(read(FILES.ci), /if:\s*always\(\)/);
});

test("CI keeps the test and compose job keys", () => {
  const text = read(FILES.ci);
  assert.match(text, /^\s*test:\s*$/m);
  assert.match(text, /^\s*compose:\s*$/m);
});

// PR 9, S1: the patient claim is admin-only. A user must not edit their own `patient` attribute
// through the account API. The realm declares `patient` as a managed user-profile attribute that
// only an admin can view or edit, and it does not leave unmanaged attributes open to the user.
function loadUserProfile() {
  const provider = loadRealm().components?.["org.keycloak.userprofile.UserProfileProvider"]?.[0];
  assert.ok(provider, "realm has no user profile provider component");
  const raw = provider.config?.["kc.user.profile.config"]?.[0];
  assert.ok(raw, "user profile provider has no kc.user.profile.config");
  return JSON.parse(raw);
}

test("PR 9: user profile declares `patient` with admin-only view and edit", () => {
  const attribute = loadUserProfile().attributes?.find((a) => a.name === "patient");
  assert.ok(attribute, "user profile does not declare a managed `patient` attribute");
  assert.deepEqual(attribute.permissions?.edit, ["admin"], "patient edit permission is not [admin]");
  assert.deepEqual(attribute.permissions?.view, ["admin"], "patient view permission is not [admin]");
});

test("PR 9: unmanagedAttributePolicy is not ENABLED (users cannot write unmanaged attributes)", () => {
  assert.notEqual(loadUserProfile().unmanagedAttributePolicy, "ENABLED");
});

test("PR 9: e2e.sh tries to change the patient attribute and re-checks the claim", () => {
  const text = read("scripts/e2e.sh");
  assert.match(text, /realms\/fhir\/account/);
  assert.match(text, /patient-1/);
});
