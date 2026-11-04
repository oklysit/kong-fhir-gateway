# kong-fhir-gateway

> Work in progress. v0.1.0 is not released yet.

A reference implementation of open-source Kong in front of a FHIR server: it checks SMART on FHIR access tokens and returns gateway errors as FHIR `OperationOutcome` resources. It mirrors the pattern in Biswa Mohanty's Kong post, ["Level Up Your Digital Health Platform with Kong, SMART on FHIR, Okta"](https://konghq.com/blog/engineering/health-platform-kong-smart-on-fhir-okta), built on OSS Kong with Keycloak. Two checks go beyond that post and are design decisions made here: the patient ID in the request must match the token's patient context, and the discovery document stays public.

All data is synthetic. This is an illustration, not a compliance claim.

## AI disclosure

This project was built in collaboration with Claude (Anthropic). The author reviews and merges every change and is responsible for the result.

## License

Apache-2.0
