// Tests for the mock FHIR server. Uses only node:test, node:assert/strict and global fetch.
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

const PATIENT_1 = {
  resourceType: "Patient",
  id: "patient-1",
  name: [{ family: "Example", given: ["Ada"] }],
  gender: "female",
  birthDate: "1980-01-01",
};

const PATIENT_2 = {
  resourceType: "Patient",
  id: "patient-2",
  name: [{ family: "Sample", given: ["Ben"] }],
  gender: "male",
  birthDate: "1975-05-05",
};

test("GET /fhir/Patient/patient-1 returns the first synthetic Patient", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/fhir/Patient/patient-1`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    assert.deepEqual(await res.json(), PATIENT_1);
  } finally {
    await stop(server);
  }
});

test("GET /fhir/Patient/patient-2 returns the second synthetic Patient", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/fhir/Patient/patient-2`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    assert.deepEqual(await res.json(), PATIENT_2);
  } finally {
    await stop(server);
  }
});

test("GET /fhir/Patient/{unknown} returns 404 OperationOutcome", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/fhir/Patient/no-such-patient`);
    assert.equal(res.status, 404);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    const body = await res.json();
    assert.equal(body.resourceType, "OperationOutcome");
    assert.equal(body.issue.length, 1);
    assert.equal(body.issue[0].severity, "error");
    assert.equal(body.issue[0].code, "not-found");
    assert.equal(typeof body.issue[0].diagnostics, "string");
    assert.notEqual(body.issue[0].diagnostics.length, 0);
  } finally {
    await stop(server);
  }
});

test("GET /fhir/Patient returns a searchset Bundle with both Patients", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/fhir/Patient`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    const body = await res.json();
    assert.equal(body.resourceType, "Bundle");
    assert.equal(body.type, "searchset");
    assert.equal(body.total, 2);
    assert.deepEqual(body.entry, [
      { resource: PATIENT_1 },
      { resource: PATIENT_2 },
    ]);
  } finally {
    await stop(server);
  }
});

test("GET /.well-known/smart-configuration uses the default ISSUER", async () => {
  const saved = process.env.ISSUER;
  delete process.env.ISSUER;
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/.well-known/smart-configuration`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
    const body = await res.json();
    const issuer = "http://localhost:8081/realms/fhir";
    assert.equal(body.authorization_endpoint, `${issuer}/protocol/openid-connect/auth`);
    assert.equal(body.token_endpoint, `${issuer}/protocol/openid-connect/token`);
    assert.deepEqual(body.scopes_supported, ["openid", "launch/patient", "patient/Patient.read"]);
    assert.deepEqual(body.capabilities, ["launch-standalone", "client-public", "permission-patient"]);
    assert.deepEqual(body.code_challenge_methods_supported, ["S256"]);
  } finally {
    await stop(server);
    if (saved === undefined) delete process.env.ISSUER;
    else process.env.ISSUER = saved;
  }
});

test("GET /.well-known/smart-configuration honours a changed ISSUER env var", async () => {
  const saved = process.env.ISSUER;
  const issuer = "https://auth.example.test/realms/other";
  process.env.ISSUER = issuer;
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/.well-known/smart-configuration`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.authorization_endpoint, `${issuer}/protocol/openid-connect/auth`);
    assert.equal(body.token_endpoint, `${issuer}/protocol/openid-connect/token`);
  } finally {
    await stop(server);
    if (saved === undefined) delete process.env.ISSUER;
    else process.env.ISSUER = saved;
  }
});

test("unknown GET path returns 404 OperationOutcome", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/no/such/path`);
    assert.equal(res.status, 404);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    const body = await res.json();
    assert.equal(body.resourceType, "OperationOutcome");
    assert.equal(body.issue[0].severity, "error");
    assert.equal(body.issue[0].code, "not-found");
    assert.equal(typeof body.issue[0].diagnostics, "string");
  } finally {
    await stop(server);
  }
});

test("POST /fhir/Patient returns 405 OperationOutcome with not-supported", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/fhir/Patient`, {
      method: "POST",
      headers: { "content-type": "application/fhir+json" },
      body: JSON.stringify(PATIENT_1),
    });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    const body = await res.json();
    assert.equal(body.resourceType, "OperationOutcome");
    assert.equal(body.issue.length, 1);
    assert.equal(body.issue[0].severity, "error");
    assert.equal(body.issue[0].code, "not-supported");
    assert.equal(typeof body.issue[0].diagnostics, "string");
  } finally {
    await stop(server);
  }
});

test("DELETE on a Patient id returns 405 OperationOutcome with not-supported", async () => {
  const { server, base } = await start();
  try {
    const res = await fetch(`${base}/fhir/Patient/patient-1`, { method: "DELETE" });
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("content-type"), "application/fhir+json");
    const body = await res.json();
    assert.equal(body.resourceType, "OperationOutcome");
    assert.equal(body.issue[0].code, "not-supported");
  } finally {
    await stop(server);
  }
});
