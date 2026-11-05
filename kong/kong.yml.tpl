# Kong declarative config TEMPLATE. Not used as-is: kong/render.sh fills in the one key placeholder
# line (further down) with Keycloak's real public key and writes the result to a volume.
# Kong reads the rendered file at startup (DB-less mode, KONG_DATABASE=off).

# Format version of this file. Kong 3.x reads the "3.0" layout used below.
_format_version: "3.0"

# The upstream service: the mock FHIR server, on the Docker network only (not published).
services:
  - name: mock-fhir
    # Internal address. The mock listens on 8080 inside its container.
    url: http://mock-fhir:8080

    # Routes decide which request paths reach this service.
    routes:
      # Discovery route: open to everyone, so a client can find the token endpoint before it has a token.
      - name: discovery
        paths:
          - /.well-known/smart-configuration
        # Keep the full path when sending upstream. The mock matches the full path.
        strip_path: false

      # FHIR route: every /fhir request.
      - name: fhir
        paths:
          - /fhir
        # Keep the full path when sending upstream, so the mock sees /fhir/Patient/<id>.
        strip_path: false
        # Kong OSS runs plugins by their numeric PRIORITY (higher runs first), not in the order listed here.
        # Priorities on this route: jwt 1450, rate-limiting 910, fhir-guard 900 (PRIORITY in handler.lua).
        # The order is deliberate: rate-limiting runs before fhir-guard, so a request the guard denies
        # still counts toward the limit. Only requests that pass jwt are counted, because jwt runs first.
        plugins:
          # Step 1: check the bearer token signature (RS256) and expiry. Rejects with 401.
          - name: jwt
            config:
              # Look up the consumer by the token's "iss" claim (the issuer URL).
              key_claim_name: iss
              # Read the token from the Authorization header only. The plugin default also reads a "jwt"
              # query parameter, which would put a live token in URLs, logs and referrer headers.
              # An empty list turns the query parameter off, so ?jwt=<token> without a header gets 401.
              uri_param_names: []
              # Check the "exp" claim, so an expired token is rejected.
              claims_to_verify:
                - exp
          # Step 2 (runs at PRIORITY 910): rate limit. Counts each request jwt accepted, then answers 429
          # when the limit is hit. Kong's 429 is rewritten to a FHIR OperationOutcome by fhir-guard.
          - name: rate-limiting
            config:
              # Allow 30 requests per minute. Demo value only; a real deployment would tune it per client.
              minute: 30
              # Keep the counter inside this Kong node (no Redis). Enough for one container in demo and CI.
              policy: local
              # Count per consumer. Every token maps to the one consumer keycloak-fhir, so all
              # clients share this one count. This is a demo limit, not a per-client limit.
              limit_by: consumer
              # If the counter store fails, still proxy the request. Harmless with policy local.
              fault_tolerant: true
          # Step 3 (runs at PRIORITY 900, after rate-limiting): our own rules (method, path, scope, patient).
          # Runs only after jwt accepts the token. A request it denies has already been counted above.
          - name: fhir-guard

  # The mock LLM: the AI service. Like mock-fhir, it sits on the Docker network only (not published).
  - name: mock-llm
    # Internal address. The mock listens on 8082 inside its container.
    url: http://mock-llm:8082

    routes:
      # AI route: POST /ai/chat. fhir-guard denies any other request under /ai, so this is the only AI path.
      - name: ai-chat
        paths:
          - /ai/chat
        # Keep the full path when sending upstream.
        strip_path: false
        # Plugin order on this route, by PRIORITY (higher runs first): jwt 1450, rate-limiting 910,
        # fhir-guard 900, ai-prompt-guard 771, ai-proxy 770. The order listed below does not decide it.
        # Rate-limiting counts a request before fhir-guard can deny it. It keys its counter by route,
        # so the requests here do not share the count of the FHIR route.
        plugins:
          # Step 1: check the bearer token signature (RS256) and expiry. Same settings as the FHIR route.
          - name: jwt
            config:
              # Look up the consumer by the token's "iss" claim (the issuer URL).
              key_claim_name: iss
              # Read the token from the Authorization header only. The plugin default also reads a "jwt"
              # query parameter, which would put a live token in URLs, logs and referrer headers.
              # An empty list turns the query parameter off, so ?jwt=<token> without a header gets 401.
              uri_param_names: []
              # Check the "exp" claim, so an expired token is rejected.
              claims_to_verify:
                - exp
          # Step 2 (PRIORITY 910): rate limit. Ten AI requests per minute per consumer. Kong's 429 is
          # rewritten to OperationOutcome by fhir-guard.
          - name: rate-limiting
            config:
              # Ten requests per minute. A demo value, kept low so CI can prove the limit cheaply.
              minute: 10
              # Keep the counter inside this Kong node (no Redis), same as the FHIR route.
              policy: local
              # Count per consumer. All tokens map to the one consumer keycloak-fhir.
              limit_by: consumer
              # If the counter store fails, still proxy the request. Harmless with policy local.
              fault_tolerant: true
          # Step 3 (PRIORITY 900): our own rules. On this route it checks POST, the exact path, and the ai/chat scope.
          - name: fhir-guard
          # Step 4 (PRIORITY 771): scan the prompt. Single quotes keep each backslash literal, so the regex
          # reaches Kong unchanged. A double-quoted string would turn \s and \d into bad escapes.
          - name: ai-prompt-guard
            config:
              # false: every user message in the conversation is checked, not only the newest one.
              # An injection in an earlier turn still blocks the request.
              allow_all_conversation_history: false
              # true: check messages of every role (system, assistant and user), not only user messages.
              # Without this, an injection phrase or an SSN in a system or assistant message passes.
              match_all_roles: true
              # Size cap for the body the guard inspects, in bytes (8 KB).
              max_request_body_size: 8192
              deny_patterns:
                # Prompt injection: "ignore/disregard all previous/prior instructions", any letter case.
                - '(?i)(?:ignore|disregard)\s+(?:all\s+)?(?:previous|prior)\s+instructions'
                # A US Social Security number shape (123-45-6789) as a whole word. Keeps it from the model.
                - '\b\d{3}-\d{2}-\d{4}\b'
          # Step 5 (PRIORITY 770): send the checked chat request to the mock LLM and return its answer.
          - name: ai-proxy
            config:
              # OpenAI-style chat in and out (/v1/chat/completions shape).
              route_type: llm/v1/chat
              model:
                # "openai" is the request format only. The model is our mock, not an OpenAI account.
                provider: openai
                name: mock-clinical-model
                options:
                  # The full URL, with the port. Without a port, Kong falls back to 443 (HTTPS) and the call fails.
                  upstream_url: http://mock-llm:8082/v1/chat/completions
              auth:
                # Kong sets this header on the upstream request. The mock sees this key, not the caller's token.
                header_name: Authorization
                header_value: Bearer mock-llm-key
                # false: a caller cannot supply its own Authorization header to replace the internal key.
                allow_override: false
              logging:
                # Ask ai-proxy to collect token counts and latency for Kong's logging plugins. No logging plugin
                # is configured here, and the default access log format has no AI fields, so nothing from
                # this setting reaches a log today. Add a log plugin to make use of the numbers.
                log_statistics: true
                # false: prompts and answers are never written to the log, so no patient text lands there.
                log_payloads: false

# The consumer is the Keycloak issuer. Its jwt_secrets entry holds the key that verifies tokens.
consumers:
  - username: keycloak-fhir
    jwt_secrets:
      # The key must equal the token's "iss" claim. Keycloak sets that claim to this URL.
      - key: "http://localhost:8081/realms/fhir"
        # Tokens from Keycloak are signed with RS256.
        algorithm: RS256
        # Public key only, in PEM form. render.sh replaces the one line below that holds the placeholder.
        # The indentation before the placeholder is kept, so every PEM line lines up under the "|".
        rsa_public_key: |
          __KEYCLOAK_PUBLIC_KEY_PEM__
