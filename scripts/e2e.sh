#!/usr/bin/env bash
# End-to-end checks for the Kong gateway in front of the mock FHIR server (PR 4).
# Run from the repo root after `docker compose up --wait`.
# Needs curl and jq only. Kong is on localhost:8000, Keycloak on localhost:8081.
# Prints one line per check. Stops and exits 1 on the first failed check.
# Demo and CI only: the users and the password grant are synthetic.
set -u

# Base URLs. Kong is the only public entry point. Keycloak issues the tokens.
KONG="http://localhost:8000"
KEYCLOAK="http://localhost:8081"

# Temporary files for the response body and headers. Removed on exit.
BODY=$(mktemp)
HDRS=$(mktemp)
trap 'rm -f -- "$BODY" "$HDRS"' EXIT

# Print a passing check with its label, on one line.
pass() {
  echo "PASS  $1"
}

# Print a failing check with its label and the detail, then stop the run.
fail() {
  echo "FAIL  $1: $2"
  exit 1
}

# Request a URL and store the result in globals. An optional second argument is a bearer token.
# Sets STATUS (the HTTP code, or 000 when no connection), CTYPE (the content type) and
# leaves the body in $BODY. curl does not treat HTTP errors as failures here, so the
# caller judges the status code.
request() {
  local url="$1"
  local token="${2:-}"
  if [ -n "$token" ]; then
    STATUS=$(curl -sS -o "$BODY" -D "$HDRS" -w '%{http_code}' -H "Authorization: Bearer $token" "$url") || STATUS=000
  else
    STATUS=$(curl -sS -o "$BODY" -D "$HDRS" -w '%{http_code}' "$url") || STATUS=000
  fi
  # The last content-type header wins, and CRLF line endings are stripped.
  CTYPE=$(grep -i '^content-type:' "$HDRS" | tail -n 1 | tr -d '\r' | cut -d: -f2- | sed 's/^ *//')
}

# Ask Keycloak for an access token with the password grant on fhir-demo.
# Arguments: username, scope. Prints the access_token, or nothing when the request fails.
token_for() {
  curl -sS -X POST "$KEYCLOAK/realms/fhir/protocol/openid-connect/token" \
    -d grant_type=password \
    -d client_id=fhir-demo \
    -d "username=$1" \
    -d "password=$1" \
    --data-urlencode "scope=$2" \
    | jq -r '.access_token // empty'
}

# True when the last response is a FHIR OperationOutcome with the given issue code.
# Arguments: expected code.
is_outcome() {
  case "$CTYPE" in
    *application/fhir+json*) ;;
    *) return 1 ;;
  esac
  jq -e --arg code "$1" \
    '.resourceType == "OperationOutcome" and .issue[0].code == $code' "$BODY" >/dev/null 2>&1
}

# Scope every token below asks for, unless a check says otherwise.
SCOPE="openid patient/Patient.read"

# 1. No token on patient-1 -> 401, FHIR content type, OperationOutcome code login.
request "$KONG/fhir/Patient/patient-1"
if [ "$STATUS" = "401" ] && is_outcome login; then
  pass "1 no token on /fhir/Patient/patient-1 -> 401 OperationOutcome login"
else
  fail "1 no token on /fhir/Patient/patient-1 -> 401 OperationOutcome login" "status $STATUS, content-type '$CTYPE'"
fi

# 2. Garbage bearer token -> 401, same OperationOutcome shape.
request "$KONG/fhir/Patient/patient-1" "not-a-real-token"
if [ "$STATUS" = "401" ] && is_outcome login; then
  pass "2 garbage bearer token -> 401 OperationOutcome login"
else
  fail "2 garbage bearer token -> 401 OperationOutcome login" "status $STATUS, content-type '$CTYPE'"
fi

# 3. Discovery document needs no token and advertises the token endpoint.
request "$KONG/.well-known/smart-configuration"
if [ "$STATUS" = "200" ] && jq -e 'has("token_endpoint")' "$BODY" >/dev/null 2>&1; then
  pass "3 /.well-known/smart-configuration without token -> 200 with token_endpoint"
else
  fail "3 /.well-known/smart-configuration without token -> 200 with token_endpoint" "status $STATUS"
fi

# Tokens for the checks below. An empty token means Keycloak refused the request.
ADA=$(token_for ada "$SCOPE")
BEN=$(token_for ben "$SCOPE")
if [ -z "$ADA" ] || [ -z "$BEN" ]; then
  fail "token setup" "Keycloak returned no access token for ada or ben"
fi

# 4. ada reads her own patient-1 -> 200 with Patient id patient-1.
request "$KONG/fhir/Patient/patient-1" "$ADA"
if [ "$STATUS" = "200" ] && jq -e '.resourceType == "Patient" and .id == "patient-1"' "$BODY" >/dev/null 2>&1; then
  pass "4 ada reads /fhir/Patient/patient-1 -> 200 Patient patient-1"
else
  fail "4 ada reads /fhir/Patient/patient-1 -> 200 Patient patient-1" "status $STATUS"
fi

# 5. ada reads patient-2 -> 403 with OperationOutcome code forbidden.
request "$KONG/fhir/Patient/patient-2" "$ADA"
if [ "$STATUS" = "403" ] && is_outcome forbidden; then
  pass "5 ada reads /fhir/Patient/patient-2 -> 403 OperationOutcome forbidden"
else
  fail "5 ada reads /fhir/Patient/patient-2 -> 403 OperationOutcome forbidden" "status $STATUS, content-type '$CTYPE'"
fi

# 6a. ben reads his own patient-2 -> 200 with Patient id patient-2.
request "$KONG/fhir/Patient/patient-2" "$BEN"
if [ "$STATUS" = "200" ] && jq -e '.resourceType == "Patient" and .id == "patient-2"' "$BODY" >/dev/null 2>&1; then
  pass "6a ben reads /fhir/Patient/patient-2 -> 200 Patient patient-2"
else
  fail "6a ben reads /fhir/Patient/patient-2 -> 200 Patient patient-2" "status $STATUS"
fi

# 6b. ben reads patient-1 -> 403.
request "$KONG/fhir/Patient/patient-1" "$BEN"
if [ "$STATUS" = "403" ]; then
  pass "6b ben reads /fhir/Patient/patient-1 -> 403"
else
  fail "6b ben reads /fhir/Patient/patient-1 -> 403" "status $STATUS"
fi

# 7. A token with scope openid only (no patient/Patient.read) reading patient-1 -> 403.
NOSCOPE=$(token_for ada "openid")
if [ -z "$NOSCOPE" ]; then
  fail "7 token with scope openid only -> 403" "Keycloak returned no access token"
fi
request "$KONG/fhir/Patient/patient-1" "$NOSCOPE"
if [ "$STATUS" = "403" ]; then
  pass "7 token with scope 'openid' only reads /fhir/Patient/patient-1 -> 403"
else
  fail "7 token with scope 'openid' only reads /fhir/Patient/patient-1 -> 403" "status $STATUS"
fi

# 8. Search is denied for patient-scoped tokens (deliberate limit) -> 403.
request "$KONG/fhir/Patient" "$ADA"
if [ "$STATUS" = "403" ]; then
  pass "8 ada GET /fhir/Patient (search) -> 403"
else
  fail "8 ada GET /fhir/Patient (search) -> 403" "status $STATUS"
fi

# 9. Any other resource type is denied by default -> 403.
request "$KONG/fhir/Observation/x" "$ADA"
if [ "$STATUS" = "403" ]; then
  pass "9 ada GET /fhir/Observation/x -> 403 (deny by default)"
else
  fail "9 ada GET /fhir/Observation/x -> 403 (deny by default)" "status $STATUS"
fi

# 10. The mock is not published to the host. A connection must fail, so curl exits non-zero.
if curl -sS -o /dev/null --max-time 5 "http://localhost:8080/" 2>/dev/null; then
  fail "10 localhost:8080 is not reachable (Kong is the only way in)" "the mock answered on the host"
else
  pass "10 localhost:8080 cannot connect (mock not published)"
fi

# 11. The Kong admin API is not published to the host. A connection must fail.
if curl -sS -o /dev/null --max-time 5 "http://localhost:8001/" 2>/dev/null; then
  fail "11 localhost:8001 is not reachable (admin API not published)" "the admin API answered on the host"
else
  pass "11 localhost:8001 cannot connect (admin API not published)"
fi

# Bypass probes (PR 5). Each one asks Kong with ada's token for a path that tries to reach
# patient-2. --path-as-is keeps dot segments and encoded slashes unchanged, so curl does not
# normalise them before Kong sees them. Rule: the answer must NOT be a Patient with id patient-2.
# A 403, 404, 400 or a Patient patient-1 all pass. The status is printed on the PASS line.
# Arguments: label, path (appended to Kong's base URL).
probe() {
  local label="$1"
  local path="$2"
  STATUS=$(curl -sS --path-as-is -o "$BODY" -D "$HDRS" -w '%{http_code}' \
    -H "Authorization: Bearer $ADA" "$KONG$path") || STATUS=000
  # A failed connection proves nothing about the bypass, so it fails the check too.
  if [ "$STATUS" = "000" ]; then
    fail "$label" "no connection to Kong"
  fi
  if jq -e '.resourceType == "Patient" and .id == "patient-2"' "$BODY" >/dev/null 2>&1; then
    fail "$label" "BYPASS: ada received Patient patient-2 (status $STATUS)"
  fi
  pass "$label -> status $STATUS, not Patient patient-2"
}

# 12a-12g. Path tricks with ada's token. Each one must not return patient-2.
probe "12a bypass /fhir/Patient/patient-2/../patient-1 (ada)" "/fhir/Patient/patient-2/../patient-1"
probe "12b bypass /fhir/Patient/patient-1/../patient-2 (ada)" "/fhir/Patient/patient-1/../patient-2"
probe "12c bypass /fhir/Patient/patient-1%2F..%2Fpatient-2 (ada)" "/fhir/Patient/patient-1%2F..%2Fpatient-2"
probe "12d bypass /fhir/Patient/patient-1/ trailing slash (ada)" "/fhir/Patient/patient-1/"
probe "12e bypass //fhir/Patient/patient-1 double slash (ada)" "//fhir/Patient/patient-1"
probe "12f bypass /fhir/Patient/patient-1?_id=patient-2 query (ada)" "/fhir/Patient/patient-1?_id=patient-2"
probe "12g bypass /fhir/Patient/patient-1%2e%2e/patient-2 encoded dots (ada)" "/fhir/Patient/patient-1%2e%2e/patient-2"

# 13. HEAD on patient-1 with ada's token -> 403 (deny by default for non-GET).
STATUS=$(curl -sS -I -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADA" \
  "$KONG/fhir/Patient/patient-1") || STATUS=000
if [ "$STATUS" = "403" ]; then
  pass "13 ada HEAD /fhir/Patient/patient-1 -> 403 (deny by default for non-GET)"
else
  fail "13 ada HEAD /fhir/Patient/patient-1 -> 403 (deny by default for non-GET)" "status $STATUS"
fi

# 14. OPTIONS on patient-1 with ada's token -> 403 (deny by default for non-GET).
STATUS=$(curl -sS -X OPTIONS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADA" \
  "$KONG/fhir/Patient/patient-1") || STATUS=000
if [ "$STATUS" = "403" ]; then
  pass "14 ada OPTIONS /fhir/Patient/patient-1 -> 403 (deny by default for non-GET)"
else
  fail "14 ada OPTIONS /fhir/Patient/patient-1 -> 403 (deny by default for non-GET)" "status $STATUS"
fi

# 15. LAST: rate limit. Up to 45 GETs of patient-1 with ada's token. The limit is 30 per minute
# for the one consumer, so at least one answer must be 429: a FHIR OperationOutcome with code
# throttled and content type application/fhir+json. The checks above send 16 requests through
# route fhir (checks 4-9, 12a-12g, 13, 14). Checks 1 and 2 do not count: jwt rejects those
# before rate-limiting runs.
HIT=0
for i in $(seq 1 45); do
  request "$KONG/fhir/Patient/patient-1" "$ADA"
  if [ "$STATUS" = "429" ]; then
    HIT=$i
    break
  fi
done
if [ "$HIT" -eq 0 ]; then
  fail "15 rate limit: a 429 within 45 GETs of /fhir/Patient/patient-1" "no 429 (last status $STATUS)"
fi
if [ "$STATUS" = "429" ] && is_outcome throttled; then
  pass "15 rate limit: GET $HIT of 45 -> 429 OperationOutcome throttled, application/fhir+json"
else
  fail "15 rate limit: a 429 within 45 GETs of /fhir/Patient/patient-1" "status $STATUS, content-type '$CTYPE'"
fi

echo "ALL CHECKS PASSED"
