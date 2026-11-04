# Verify tokens with the OSS `jwt` plugin plus a Lua scope check, not the OIDC plugin

Kong's `openid-connect` plugin is Enterprise-only, and the pattern this repo mirrors (Biswa Mohanty's Kong, SMART on FHIR and Okta post) uses it. This repo targets open-source Kong, so it verifies the signature, expiry and issuer with the `jwt` plugin and checks scopes and patient context in a small Lua function. The cost: the identity provider's signing key is configured statically, so key rotation is manual. This is a deliberate limit of a demo, and the README says so.
