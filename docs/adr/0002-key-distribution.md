# Distribute Keycloak public key to Kong via an init container

## Context

Keycloak generates an RS256 token signing key when its realm starts up. The open-source Kong 3.9.4 `jwt` plugin reads a static public key configured directly on the consumer credential. Dynamic retrieval from Keycloak via a JWKS endpoint requires the `openid-connect` plugin, which is Enterprise-only.

## Decision

We use an ephemeral Alpine init container named `kong-config` running `kong/render.sh`. The container waits until Keycloak reports healthy. It queries `GET /realms/fhir` on the internal network to retrieve the realm public key. The script wraps the base64 string in standard 64-character PEM boundaries, substitutes it into `kong/kong.yml.tpl`, and writes the rendered `kong.yml` file to a shared Docker volume. Kong starts DB-less with declarative configuration, mounting this volume read-only. No private signing keys are committed to source control.

## Cost

Key rotation is not dynamic. When Keycloak generates a new signing key, an administrator must restart the stack so the init container re-renders the gateway configuration.

## Alternatives considered

1. Committing a fixed keypair in the realm export: rejected because checking private keys into a public git repository creates security risks and poor habits.
2. Custom Lua script to fetch JWKS: rejected because custom network I/O in the gateway access phase adds unnecessary operational complexity to a reference project.
