# Governance Mapping: HIPAA Technical Safeguards

## Purpose and Stated Limits

This document maps repository architecture to HIPAA Security Rule technical safeguards (45 CFR 164.312).

HIPAA applies to covered entities and business associates; this repository is neither. The codebase contains no protected health information (PHI) and processes only synthetic data (Ada Example as patient-1, Ben Sample as patient-2). The project demonstrates API gateway policy enforcement using open-source Kong Gateway 3.9.4 and Keycloak 26.8.1. Nothing here constitutes legal advice or compliance evidence. The repo makes no claim to be compliant, certified, or HIPAA ready.

## 45 CFR 164.312(a)(1) Standard: Access control

> "Implement technical policies and procedures for electronic information systems that maintain electronic protected health information to allow access only to those persons or software programs that have been granted access rights as specified in § 164.308(a)(4)."

Kong applies jwt, rate-limiting, and fhir-guard plugins in kong/kong.yml.tpl. In kong/plugins/fhir-guard/handler.lua, Lua logic enforces deny by default, allowing only GET /fhir/Patient/<id>. The handler confirms token scope contains patient/Patient.read and matches token patient context to the path. In scripts/e2e.sh, Check 4 verifies Ada reads patient-1 (HTTP 200), Check 5 confirms Ada cannot read patient-2 (HTTP 403), Check 8 confirms search returns HTTP 403, and Checks 12a-12g verify path traversal bypasses fail. The `patient` claim decides which record a user may read, so keycloak/realm-fhir.json declares `patient` as a managed user-profile attribute that only an admin can view or edit. In scripts/e2e.sh, Checks 17a-17e prove it: Ada's token can call the Keycloak account API and edit her first name (the controls), an attempt to set her own `patient` to patient-2 changes nothing, and new tokens still carry patient-1 for Ada and patient-2 for Ben.

The demo provides no emergency break-glass procedure (164.312(a)(2)(ii)), no automatic logoff (164.312(a)(2)(iii)), and no encryption at rest (164.312(a)(2)(iv)). Search is blocked, and callers share one rate-limit counter.

Production systems require emergency break-glass workflows, inactivity logoffs, attribute-based access control, and database encryption at rest.

### 45 CFR 164.312(a)(2)(i) Implementation specification: Unique user identification (Required)

> "Assign a unique name and/or number for identifying and tracking user identities."

**Status: gap.** Keycloak holds one account per user (ada and ben), so identity exists at the login server. The gateway does not carry it forward: Kong maps every valid token to the one consumer keycloak-fhir, the rate limit counts all callers together, and the default access log has no field for the user or the token's `patient` claim. A request seen at the gateway cannot be tied to a person from the gateway's own records. Production systems require the user identifier in every audit record, for example through a logging plugin that writes the token subject.

## 45 CFR 164.312(b) Standard: Audit controls

> "Implement hardware, software, and/or procedural mechanisms that record and examine activity in information systems that contain or use electronic protected health information."

Writing access logs to stdout is the default behavior of the official kong:3.9.4 container image entrypoint rather than something configured in docker-compose.yml. The default log format records client IP address, the remote user field, local timestamp, HTTP request line (method, path, protocol version), HTTP status code, body bytes sent, HTTP referer, user agent, and Kong request ID. It has no user identity: no field holds the token subject or the `patient` claim. It has no AI fields either: no log plugin is configured, so the token counts that ai-proxy can collect (`log_statistics: true`) do not reach any log. In kong/plugins/fhir-guard/handler.lua, fhir-guard rewrites gateway errors into FHIR OperationOutcome responses. On /ai/chat, scripts/e2e-ai.sh Check 4 verifies denied prompt injections return generic diagnostics without exposing pattern regexes.

The demo does not stream audit logs to durable storage; stdout vanishes on container recreation. The gateway logs transport metadata without recording clinical fields accessed or who made the request. In kong/kong.yml.tpl, ai-proxy sets log_payloads: false, so prompt bodies are not collected for logging.

Production systems require audit pipelines emitting FHIR AuditEvent records to an immutable SIEM platform, automated alerting, and regular review. Audit log retention periods remain a policy decision for the system operator, as 45 CFR 164.312(b) does not set a fixed retention timeframe.

## 45 CFR 164.312(c)(1) Standard: Integrity

> "Implement policies and procedures to protect electronic protected health information from improper alteration or destruction."

The gateway protects data integrity by restricting the FHIR API to read operations. In kong/plugins/fhir-guard/handler.lua, Lua permits only GET on /fhir/Patient/<id>. In scripts/e2e.sh, Checks 15a to 15d send POST, PUT, PATCH, and DELETE to /fhir/Patient/patient-1 with Ada's valid token, and each receives HTTP 403. HEAD and OPTIONS are separate checks: Check 13 (HEAD) and Check 14 (OPTIONS) each receive HTTP 403.

On /ai/chat, ai-prompt-guard and ai-proxy provide application security and privacy controls that sit beside, rather than under, 164.312(c)(1). Specifically, ai-prompt-guard blocks prompt injections (application security) and social security numbers (privacy and data loss prevention) in messages of every role (`match_all_roles: true`), verified by HTTP 400 responses in scripts/e2e-ai.sh Checks 4, 5, 6, 6b (injection in a system message), and 6c (SSN in an assistant message). Check 3 confirms a clean conversation with system, user, and assistant messages still returns HTTP 200. In kong/kong.yml.tpl, ai-proxy replaces client credentials with an internal key (credential management and access compartmentalization), verified by scripts/e2e-ai.sh Check 3.

The demo provides no cryptographic checksums, digital signatures, or entity tags (ETags) to verify records remain unaltered. It provides no database transaction verification.

Production systems require cryptographic integrity controls, digital signatures, schema validation, transaction isolation, and FHIR resource version tracking (_history).

## 45 CFR 164.312(d) Standard: Person or entity authentication

> "Implement procedures to verify that a person or entity seeking access to electronic protected health information is the one claimed."

Keycloak 26.8.1 (keycloak/realm-fhir.json) authenticates users. Kong uses the open-source jwt plugin (priority 1450) to authenticate requests. At startup, kong/render.sh retrieves Keycloak public RSA keys to render kong.yml. The gateway verifies token signatures (RS256), expirations (exp), and issuers (iss). In scripts/e2e.sh, Check 1 confirms missing tokens return HTTP 401 login OperationOutcomes, Check 2 confirms malformed tokens return HTTP 401, and Checks 4 and 6a verify tokens authenticate Ada and Ben. In scripts/e2e-ai.sh, Check 1 confirms token enforcement on /ai/chat. Both jwt plugin blocks set `uri_param_names: []`, so a token is read from the Authorization header only. In scripts/e2e.sh, Checks 16a and 16b confirm a valid token sent as `?jwt=` without a header returns HTTP 401 on /fhir/Patient/patient-1 and on /ai/chat.

The demo does not enforce multi-factor authentication (MFA). Testing enables the OAuth 2.0 password grant (token_for in scripts/e2e.sh). The jwt plugin cannot poll dynamic JWKS endpoints; key rotation requires re-running render.sh and restarting the stack.

Production systems require multi-factor authentication, OAuth 2.0 Authorization Code Flow with PKCE, dynamic JWKS polling, and mutual TLS (mTLS).

## 45 CFR 164.312(e)(1) Standard: Transmission security

> "Implement technical security measures to guard against unauthorized access to electronic protected health information that is being transmitted over an electronic communications network."

Docker Compose network isolation keeps the mock FHIR server (8080), mock LLM (8082), and Kong admin API (8001) unpublished. In scripts/e2e.sh, Checks 10 and 11 confirm localhost:8080 and localhost:8001 are unreachable. In scripts/e2e-ai.sh, Check 9 confirms localhost:8082 is unreachable. All external requests must enter through Kong on port 8000.

The demonstration runs over unencrypted HTTP. Communication between clients and Kong, as well as internal container traffic, travels in cleartext without TLS encryption or certificates.

Production environments require TLS 1.3 across public interfaces (HTTPS on port 443 with HSTS), internal mutual TLS between gateway instances and backend services, and automated certificate management.

## Summary of Major Governance Gaps

This demonstration establishes perimeter token verification, deny by default routing, and network isolation. Five technical safeguard gaps separate this prototype from a production healthcare environment: communication operates over plain HTTP without TLS encryption; the gateway maintains no durable audit pipeline for regulatory record retention; its records do not identify the user (164.312(a)(2)(i)); signing key management relies on static templates requiring container restarts to rotate; and authentication lacks multi-factor enforcement, using password grants for testing.

Addressing these areas is essential for production security posture before deploying similar gateway patterns in live healthcare environments. Under HIPAA Security Rule structure, specifications like transmission encryption (164.312(e)(2)(ii)) and encryption at rest (164.312(a)(2)(iv)) are Addressable rather than Required, leaving technical implementation choices to organizational risk analysis while remaining standard production expectations.
