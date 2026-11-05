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
# The raw Kong container log, and only its JSON lines.
KLOG=$(mktemp)
KJSON=$(mktemp)
trap 'rm -f -- "$BODY" "$HDRS" "$KLOG" "$KJSON"' EXIT

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

# Read one claim from a JWT payload. Arguments: token, claim name. Prints the value, or nothing.
# A JWT payload is base64url. Map it to base64, pad it to a multiple of 4, then decode it.
claim_of() {
  local payload
  payload=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do
    payload="$payload="
  done
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r --arg c "$2" '.[$c] // empty' 2>/dev/null
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

# 15a-15d. Write methods with ada's valid token -> 403 each (deny by default for non-GET).
# The guard allows GET only. Each probe sends a small JSON body where the method takes one.
# Arguments: label, method.
write_probe() {
  local label="$1"
  local method="$2"
  STATUS=$(curl -sS -X "$method" -o "$BODY" -D "$HDRS" -w '%{http_code}' \
    -H "Authorization: Bearer $ADA" -H 'Content-Type: application/fhir+json' \
    --data-binary '{"resourceType":"Patient","id":"patient-1"}' \
    "$KONG/fhir/Patient/patient-1") || STATUS=000
  if [ "$STATUS" = "403" ]; then
    pass "$label -> 403 (deny by default for non-GET)"
  else
    fail "$label -> 403 (deny by default for non-GET)" "status $STATUS"
  fi
}
write_probe "15a ada POST /fhir/Patient/patient-1" POST
write_probe "15b ada PUT /fhir/Patient/patient-1" PUT
write_probe "15c ada PATCH /fhir/Patient/patient-1" PATCH
write_probe "15d ada DELETE /fhir/Patient/patient-1" DELETE

# Audit log helpers. The checks below read the gateway's own log and send no requests,
# so they add nothing to the rate-limit budget of check 18.
# Copy the Kong container log into $KLOG and keep only its JSON object lines in $KJSON.
# Kong's file-log plugin writes one JSON object per request. Other lines (notices, the access
# log) are not JSON, and jq drops them. Run from the repo root, where docker compose finds the stack.
refresh_kong_log() {
  docker compose logs --no-color --no-log-prefix kong >"$KLOG" 2>/dev/null || return 1
  jq -c -R 'fromjson? | select(type == "object")' "$KLOG" >"$KJSON" 2>/dev/null
}

# True when some JSON log line satisfies a jq condition. Arguments: condition, then extra jq
# arguments (the arg option with a name and a value). The log may reach docker a moment after the request, so retry for 10 s.
log_has() {
  local cond="$1"
  shift
  local n
  for n in 1 2 3 4 5 6 7 8 9 10; do
    if refresh_kong_log && jq -e -s "$@" "any(.[]; $cond)" "$KJSON" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 15e-15h. Audit log. Field contract of the file-log JSON line:
#   .request.sub       the token's sub claim (the Keycloak user id)
#   .request.patient   the token's patient claim
#   .request.azp       the token's azp claim (the client)
#   .request.decision  "allow" or "deny", set by fhir-guard
#   .request.reason    on a deny: method, path, scope or patient_mismatch
#   .request.uri, .request.method, .response.status   Kong's own fields
# These reuse requests from checks 1, 2, 4 and 6b. CI has docker; without it the checks are skipped.
if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP  15e-15h audit log checks: docker is not on PATH (CI runs them)"
else
  ADA_SUB=$(claim_of "$ADA" sub)
  BEN_SUB=$(claim_of "$BEN" sub)
  ADA_AZP=$(claim_of "$ADA" azp)
  if [ -z "$ADA_SUB" ] || [ -z "$BEN_SUB" ] || [ -z "$ADA_AZP" ]; then
    fail "15e-15h audit log setup" "a token has no sub or azp claim"
  fi

  # 15e. ada's allowed read of patient-1 (check 4) is in the log with her identity and the decision.
  if log_has '.request.sub == $sub and .request.patient == "patient-1" and .request.azp == $azp
      and .request.decision == "allow" and .request.method == "GET"
      and .request.uri == "/fhir/Patient/patient-1" and .response.status == 200' \
      --arg sub "$ADA_SUB" --arg azp "$ADA_AZP"; then
    pass "15e log line: ada GET /fhir/Patient/patient-1 -> sub, patient-1, azp, decision allow, status 200"
  else
    fail "15e log line for ada's allowed read of patient-1" "no JSON line with ada's sub, patient-1, decision allow and status 200 in docker compose logs kong"
  fi

  # 15f. ben's denied read of patient-1 (check 6b) is in the log with his identity, his own patient
  # claim (patient-2, not the patient he asked for), decision deny and the reason patient_mismatch.
  if log_has '.request.sub == $sub and .request.patient == "patient-2"
      and .request.decision == "deny" and .request.reason == "patient_mismatch"
      and .request.uri == "/fhir/Patient/patient-1" and .response.status == 403' \
      --arg sub "$BEN_SUB"; then
    pass "15f log line: ben GET /fhir/Patient/patient-1 -> sub, patient-2, decision deny, reason patient_mismatch, status 403"
  else
    fail "15f log line for ben's denied read of patient-1" "no JSON line with ben's sub, decision deny, reason patient_mismatch and status 403 in docker compose logs kong"
  fi

  # 15g. No log line carries an Authorization request header (check 2 sent a Bearer header).
  # Header names are compared in lower case, because HTTP header names are not case sensitive.
  if jq -e -s 'any(.[]; (.request.headers // {}) | keys | map(ascii_downcase) | index("authorization"))' "$KJSON" >/dev/null 2>&1; then
    fail "15g no Authorization header in the log" "a JSON log line still has request.headers.authorization"
  fi
  pass "15g no JSON log line has an Authorization request header"

  # 15h. No Bearer token value and no full token of ada or ben appears in the whole log output.
  # grep -F matches the token as plain text. Offending lines print only after redaction.
  # This runs before 16a and 16b, which put a token in the URL on purpose and so into the access log.
  refresh_kong_log || fail "15h read the Kong log" "docker compose logs kong failed"
  # A legitimate WWW-Authenticate: Bearer realm header is fine. A leak is Bearer followed by a token-looking value.
  # On failure each offending line is redacted (any 20+ character token-like run) and cut to about 120 characters.
  if grep -qE 'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}' "$KLOG"; then
    echo "Lines with Bearer and a token-looking value (redacted):"
    grep -E 'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}' "$KLOG" \
      | sed -E 's/[A-Za-z0-9._~+\/=-]{20,}/<redacted>/g' \
      | grep -oE '.{0,50}Bearer[[:space:]]+<redacted>.{0,50}' | head -n 10
    fail "15h no Bearer token in the log" "$(grep -cE 'Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}' "$KLOG") log lines contain Bearer followed by a token-looking value"
  fi
  if grep -qF -e "$ADA" -e "$BEN" "$KLOG"; then
    fail "15h no full token in the log" "the log contains the full token of ada or ben"
  fi
  pass "15h the Kong log has no Bearer token and no full token of ada or ben"
fi

# 16a. A valid token in the URL (?jwt=) and no Authorization header -> 401. Kong must read the
# token from the header only. Check 4 proves the same token works in the header.
STATUS=$(curl -sS -o "$BODY" -D "$HDRS" -w '%{http_code}' "$KONG/fhir/Patient/patient-1?jwt=$ADA") || STATUS=000
CTYPE=$(grep -i '^content-type:' "$HDRS" | tail -n 1 | tr -d '\r' | cut -d: -f2- | sed 's/^ *//')
if [ "$STATUS" = "401" ] && is_outcome login; then
  pass "16a valid token in ?jwt= on /fhir/Patient/patient-1, no header -> 401 OperationOutcome login"
else
  fail "16a valid token in ?jwt= on /fhir/Patient/patient-1, no header -> 401" "status $STATUS, content-type '$CTYPE'"
fi

# 16b. Same on the AI route. A 401 stops at jwt, so it does not count against the AI budget.
STATUS=$(curl -sS -X POST -o "$BODY" -D "$HDRS" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary '{"messages":[{"role":"user","content":"Summarize the visit note for today"}]}' \
  "$KONG/ai/chat?jwt=$ADA") || STATUS=000
CTYPE=$(grep -i '^content-type:' "$HDRS" | tail -n 1 | tr -d '\r' | cut -d: -f2- | sed 's/^ *//')
if [ "$STATUS" = "401" ] && is_outcome login; then
  pass "16b valid token in ?jwt= on POST /ai/chat, no header -> 401 OperationOutcome login"
else
  fail "16b valid token in ?jwt= on POST /ai/chat, no header -> 401" "status $STATUS, content-type '$CTYPE'"
fi

# Call the Keycloak account API with a bearer token. Arguments: method, token, JSON body (optional).
# Sets STATUS and leaves the body in $BODY. This API is how a user edits their own profile.
account_call() {
  local method="$1"
  local token="$2"
  local payload="${3:-}"
  local -a args=(-X "$method" -H "Authorization: Bearer $token" -H 'Accept: application/json')
  if [ -n "$payload" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$payload")
  fi
  STATUS=$(curl -sS -o "$BODY" -D "$HDRS" -w '%{http_code}' "${args[@]}" "$KEYCLOAK/realms/fhir/account") || STATUS=000
}

# Diagnostic only. Print selected claims of a JWT payload (never the signature) as compact JSON.
# Argument: token.
claims_summary() {
  local payload
  payload=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do
    payload="$payload="
  done
  printf '%s' "$payload" | base64 -d 2>/dev/null \
    | jq -c '{aud, azp, scope, realm_access, resource_access, iss}' 2>/dev/null || echo "(payload not decodable)"
}

# 17. A user must not change their own patient attribute. The check has a positive control first,
# so that a rejection of the attack cannot come from a broken request.
# 17a. Baseline: ada's token carries patient-1 and ben's carries patient-2.
if [ "$(claim_of "$ADA" patient)" = "patient-1" ] && [ "$(claim_of "$BEN" patient)" = "patient-2" ]; then
  pass "17a baseline: ada's token has patient patient-1, ben's has patient-2"
else
  fail "17a baseline patient claims" "ada '$(claim_of "$ADA" patient)', ben '$(claim_of "$BEN" patient)'"
fi

# 17b. Control 1: ada's token can read her own profile from the account API -> 200.
# If this fails, the demo client's token cannot use the account API and 17c-17e would prove nothing.
account_call GET "$ADA"
if [ "$STATUS" = "200" ] && jq -e '.username == "ada"' "$BODY" >/dev/null 2>&1; then
  pass "17b control: ada GET account API with her own token -> 200"
else
  fail "17b control: ada GET account API -> 200" "status $STATUS, body $(head -c 300 "$BODY"); www-authenticate '$(grep -i '^www-authenticate:' "$HDRS" | tr -d '\r' | cut -d: -f2- | sed 's/^ *//')'; response headers: $(tr -d '\r' < "$HDRS" | tr '\n' '|'); ada token claims: $(claims_summary "$ADA")"
fi
PROFILE=$(cat "$BODY")

# 17c. Control 2: ada can edit a field she may edit. Send her profile back with a changed first
# and last name (the default profile requires both) and read it back -> 204, then the new value.
# Sending the whole profile keeps her other attributes. The same request shape carries the attack in 17d.
EDIT=$(printf '%s' "$PROFILE" | jq -c '.firstName = "Ada" | .lastName = "Demo"')
account_call POST "$ADA" "$EDIT"
if [ "$STATUS" != "204" ]; then
  fail "17c control: ada POST account API changes her first name -> 204" "status $STATUS, body $(head -c 300 "$BODY")"
fi
account_call GET "$ADA"
if [ "$STATUS" = "200" ] && jq -e '.firstName == "Ada" and .lastName == "Demo"' "$BODY" >/dev/null 2>&1; then
  pass "17c control: ada edits her own first name through the account API -> 204 and the change is visible"
else
  fail "17c control: the first name change is visible" "status $STATUS, body $(head -c 300 "$BODY")"
fi
PROFILE=$(cat "$BODY")

# 17d. Attack: the same request, with the patient attribute set to patient-2. A rejection (4xx)
# or a 204 that changes nothing both pass here. 17e decides by looking at the next token.
ATTACK=$(printf '%s' "$PROFILE" | jq -c '.attributes.patient = ["patient-2"]')
account_call POST "$ADA" "$ATTACK"
ATTACK_STATUS=$STATUS
case "$ATTACK_STATUS" in
  204|4??) pass "17d ada POST account API with patient=patient-2 -> $ATTACK_STATUS (17e checks the effect)" ;;
  *) fail "17d ada POST account API with patient=patient-2" "status $ATTACK_STATUS, body $(head -c 300 "$BODY")" ;;
esac

# 17e. A new token for ada still says patient-1, and ben's still says patient-2.
ADA_AFTER=$(token_for ada "$SCOPE")
BEN_AFTER=$(token_for ben "$SCOPE")
if [ -z "$ADA_AFTER" ] || [ -z "$BEN_AFTER" ]; then
  fail "17e new tokens after the attack" "Keycloak returned no access token for ada or ben"
fi
if [ "$(claim_of "$ADA_AFTER" patient)" = "patient-1" ] && [ "$(claim_of "$BEN_AFTER" patient)" = "patient-2" ]; then
  pass "17e after the attempt, a new ada token still has patient patient-1 (ben's patient-2)"
else
  fail "17e patient claim after the attempt" "ada '$(claim_of "$ADA_AFTER" patient)' (attack status $ATTACK_STATUS), ben '$(claim_of "$BEN_AFTER" patient)'"
fi

# 18. LAST: rate limit. Up to 45 GETs of patient-1 with ada's token. The limit is 30 per minute
# for the one consumer, so at least one answer must be 429: a FHIR OperationOutcome with code
# throttled and content type application/fhir+json.
# Budget arithmetic. Only requests that pass jwt count, because rate-limiting runs after jwt and
# before fhir-guard. Checks 1 and 2 and 16a are 401s from jwt, so they do not count. The Keycloak
# calls (tokens, account API) do not go through Kong, so they do not count either.
#   checks 4, 5, 6a, 6b, 7, 8, 9        =  7
#   checks 12a-12g                      =  7
#   checks 13 and 14                    =  2
#   checks 15a-15d (POST, PUT, PATCH, DELETE) = 4
#   total before the loop               = 20, under the limit of 30
# The audit log checks 15e-15h read the log and send no requests, so the total stays 20.
# So requests 1 to 10 of the loop get an answer, and request 11 is the first 429. The loop allows
# 45, so a window change during the run (the counter resets) still leaves one window over 30:
# 20 + 45 = 65 requests in at most two windows.
FHIR_BEFORE=20
HIT=0
for i in $(seq 1 45); do
  request "$KONG/fhir/Patient/patient-1" "$ADA"
  if [ "$STATUS" = "429" ]; then
    HIT=$i
    break
  fi
done
if [ "$HIT" -eq 0 ]; then
  fail "18 rate limit: a 429 within 45 GETs of /fhir/Patient/patient-1" "no 429 (last status $STATUS)"
fi
if [ "$STATUS" = "429" ] && is_outcome throttled; then
  pass "18 rate limit: $FHIR_BEFORE FHIR requests before the loop; GET $HIT of 45 -> 429 OperationOutcome throttled, application/fhir+json"
else
  fail "18 rate limit: a 429 within 45 GETs of /fhir/Patient/patient-1" "status $STATUS, content-type '$CTYPE'"
fi

echo "ALL CHECKS PASSED"
