# Return gateway errors as FHIR OperationOutcome resources via Lua filter handlers

## Context

Kong produces standard JSON error responses when gateway-level plugins reject requests (such as 401 from `jwt`, 429 from `rate-limiting`, or 400 from `ai-prompt-guard`). In a FHIR environment, client applications expect all diagnostic errors as FHIR `OperationOutcome` resources carrying `Content-Type: application/fhir+json`.

## Decision

We implement `header_filter` and `body_filter` phases in the custom `fhir-guard` plugin. The plugin inspects `kong.response.get_source()`. When the response source is not `service`, the plugin intercepts status codes 400, 401, and 429. In `header_filter`, it sets `Content-Type: application/fhir+json` and clears `Content-Length`. In `body_filter`, it replaces Kong's JSON body with an `OperationOutcome`: status 400 yields code `invalid` with generic diagnostics, 401 yields `login`, and 429 yields `throttled`. Responses originating from upstream services (`source == "service"`) pass through unbuffered and unmodified. HTTP 403 responses are built directly by `fhir-guard` in its access phase with the same OperationOutcome shape, while the filter handlers only rewrite responses Kong makes elsewhere (401, 429, 400).

## Cost

Nginx response body buffering and transformation in Lua introduces slight compute and latency overhead during error conditions.

## Alternatives considered

1. Kong declarative `error_template_json`: rejected because it does not cover errors emitted directly by the `jwt` plugin.
2. Kong `exit-transformer` plugin: rejected because it requires an Enterprise license.
