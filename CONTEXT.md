# kong-fhir-gateway

A reference implementation of an API gateway in front of a FHIR server: it checks SMART on FHIR access tokens and returns gateway errors in FHIR's error format.

## Language

**Gateway**:
The Kong instance that receives every client request and decides whether it reaches the FHIR server.
_Avoid_: Proxy, edge

**FHIR server**:
The service that holds patient records and answers FHIR requests. Here it is a small hand-written mock with synthetic data.
_Avoid_: EHR, backend

**Identity provider**:
The service that signs in users and issues access tokens. Here it is Keycloak.
_Avoid_: Auth server, IdP

**Access token**:
A signed JWT that proves who the caller is and what the caller may do.
_Avoid_: Bearer, credential

**Scope**:
A permission string inside the access token, such as `patient/Patient.read`.
_Avoid_: Role, permission

**Patient context**:
The one patient the access token is limited to, carried in the token's `patient` claim.
_Avoid_: Tenant, launch ID

**OperationOutcome**:
The FHIR resource that describes an error. The gateway returns one for every error it creates itself.
_Avoid_: Error body, error JSON

**Discovery document**:
The public JSON at `/.well-known/smart-configuration` that tells an app where to log in and get a token.
_Avoid_: Config endpoint, metadata
