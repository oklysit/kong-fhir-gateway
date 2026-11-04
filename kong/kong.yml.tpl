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
