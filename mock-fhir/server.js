// Mock FHIR server: serves two synthetic Patients over plain HTTP.
// Uses only node:http. No authentication here: Kong does that in a later PR.
import { createServer as createHttpServer } from "node:http";
import { fileURLToPath } from "node:url";

// The synthetic Patients, keyed by id. Plain data, no database.
const PATIENTS = {
  "patient-1": {
    resourceType: "Patient",
    id: "patient-1",
    name: [{ family: "Example", given: ["Ada"] }],
    gender: "female",
    birthDate: "1980-01-01",
  },
  "patient-2": {
    resourceType: "Patient",
    id: "patient-2",
    name: [{ family: "Sample", given: ["Ben"] }],
    gender: "male",
    birthDate: "1975-05-05",
  },
};

// Send a body as JSON with the given status and content type.
// extraHeaders is optional; it adds headers such as allow on a 405.
function send(res, status, contentType, body, extraHeaders = {}) {
  // A fixed length avoids chunked encoding, so clients and raw-socket tests can read the body as plain JSON.
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": contentType,
    "content-length": Buffer.byteLength(text),
    ...extraHeaders,
  });
  res.end(text);
}

// Send a FHIR OperationOutcome error. Every error in this server uses this shape.
function sendError(res, status, code, diagnostics, extraHeaders = {}) {
  const outcome = {
    resourceType: "OperationOutcome",
    issue: [{ severity: "error", code, diagnostics }],
  };
  send(res, status, "application/fhir+json", outcome, extraHeaders);
}

// Build the SMART discovery document. ISSUER is read on each request,
// so a changed environment variable takes effect without a restart.
function smartConfiguration() {
  const issuer = process.env.ISSUER || "http://localhost:8081/realms/fhir";
  return {
    authorization_endpoint: `${issuer}/protocol/openid-connect/auth`,
    token_endpoint: `${issuer}/protocol/openid-connect/token`,
    scopes_supported: ["openid", "launch/patient", "patient/Patient.read"],
    capabilities: ["launch-standalone", "client-public", "permission-patient"],
    code_challenge_methods_supported: ["S256"],
  };
}

// Handle one request. This mock is read-only, so any non-GET method gets 405.
function handle(req, res) {
  // A 405 must say which method is allowed, so it carries an allow header.
  if (req.method !== "GET") {
    return sendError(res, 405, "not-supported", `Method ${req.method} is not supported`, {
      allow: "GET",
    });
  }

  // Take only the path, so a query string like ?foo=1 does not break routing.
  // A malformed request line is a client error, so 400.
  let path;
  try {
    path = new URL(req.url, "http://localhost").pathname;
  } catch {
    return sendError(res, 400, "invalid", "Invalid request path");
  }

  if (path === "/.well-known/smart-configuration") {
    return send(res, 200, "application/json", smartConfiguration());
  }

  if (path === "/fhir/Patient") {
    // A searchset Bundle that lists every Patient.
    const entry = Object.values(PATIENTS).map((patient) => ({ resource: patient }));
    const bundle = { resourceType: "Bundle", type: "searchset", total: entry.length, entry };
    return send(res, 200, "application/fhir+json", bundle);
  }

  // Match /fhir/Patient/<id>. Object.hasOwn stops ids like "constructor" from matching.
  const match = /^\/fhir\/Patient\/([^/]+)$/.exec(path);
  if (match && Object.hasOwn(PATIENTS, match[1])) {
    return send(res, 200, "application/fhir+json", PATIENTS[match[1]]);
  }

  // Anything else, including an unknown Patient id, is a 404.
  return sendError(res, 404, "not-found", `No resource at GET ${path}`);
}

// Build the server without listening. Tests call listen(0) to get a free port.
export function createServer() {
  return createHttpServer(handle);
}

// Run directly (node mock-fhir/server.js): listen on PORT or 8080.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = process.env.PORT || 8080;
  createServer().listen(port, () => {
    console.log(`Mock FHIR server listening on port ${port}`);
  });
}
