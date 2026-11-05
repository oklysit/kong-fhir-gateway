-- fhir-guard: the Kong plugin that enforces what a verified token may do.
-- It runs only after the jwt plugin has accepted the token (see PRIORITY below).
-- Rules, deny by default. This plugin runs on two routes; the path decides which rules apply:
--   /fhir routes:
--     1. Only GET on exactly /fhir/Patient/<id>.
--     2. The token's "scope" claim must contain "patient/Patient.read" as a whole word.
--     3. The token's "patient" claim must equal <id>.
--   /ai routes (any path that starts with /ai):
--     A. Only POST on exactly /ai/chat.
--     B. The token's "scope" claim must contain "ai/chat" as a whole word.
--     Any other /ai path is denied, so a new AI path needs a new rule here first.
-- It also rewrites Kong's own 400, 401 and 429 bodies into FHIR OperationOutcome.
-- Audit fields: once the token is parsed, it adds who asked and what the guard decided to the
-- request log line that the file-log plugin writes (see record_identity and record_decision).
-- Fields: request.sub, request.patient, request.azp, request.decision (allow or deny) and
-- request.reason (on a deny only: token, method, path, scope or patient_mismatch).
-- "allow" means only that this plugin let the request pass. A later plugin, such as
-- ai-prompt-guard, can still refuse it, and then the line shows allow with that plugin's status.
-- A request that jwt or rate-limiting refuses never reaches this plugin, so its line has no decision.

-- The jwt parser that ships inside Kong. Used to read the claims of the already-verified token.
local jwt_parser = require "kong.plugins.jwt.jwt_parser"

local FhirGuard = {
  -- Plugin version. Only for the record.
  VERSION = "0.1.0",

  -- Priority decides the order of plugins in the same phase. Higher runs first.
  -- jwt has PRIORITY 1450 and rate-limiting has 910. This value is lower than both, so fhir-guard
  -- runs after them in the access phase. Rate-limiting therefore counts a request before the guard
  -- can deny it. The value must stay above 0 and below 910.
  PRIORITY = 900,
}

-- Build a FHIR OperationOutcome as a JSON string.
-- Built by hand, not with a JSON library, so the output is always exactly this shape.
-- "text" must not contain double quotes, because it is placed inside the JSON as-is.
local function outcome(code, text)
  return '{"resourceType":"OperationOutcome","issue":[{"severity":"error","code":"'
    .. code .. '","diagnostics":"' .. text .. '"}]}'
end

-- Add one named field to the JSON log line of this request. Kong writes the line in the log phase,
-- after the response, and keeps the value until then. A dot in the name makes a nested field,
-- so "request.sub" ends up as {"request": {"sub": ...}}.
-- Only a string is kept. A claim of any other type (a number, a list) is dropped, so the log
-- never receives a structure we did not plan for.
local function log_field(name, value)
  if type(value) == "string" then
    kong.log.set_serialize_value(name, value)
  end
end

-- Record who made the request. Reads three claims of the verified token and nothing else.
-- sub is the Keycloak user id, patient is the patient the token is tied to, azp is the client.
-- The token string itself is never passed on.
local function record_identity(claims)
  log_field("request.sub", claims.sub)
  log_field("request.patient", claims.patient)
  log_field("request.azp", claims.azp)
end

-- Record the guard decision: "allow", or "deny" with a short reason code.
local function record_decision(decision, reason)
  log_field("request.decision", decision)
  log_field("request.reason", reason)
end

-- Send an error answer with a FHIR body. Ends the request at once; no later plugin runs.
-- reason is the short code written to the log line, for example "scope". The client never sees it.
-- Every denial of this plugin goes through here, so every denial is recorded before the answer is sent.
local function deny(status, code, text, reason)
  record_decision("deny", reason)
  return kong.response.exit(status, outcome(code, text), {
    -- The FHIR content type, so the client reads the body as a FHIR resource.
    ["Content-Type"] = "application/fhir+json",
  })
end

-- True when the space-separated scope string contains the wanted scope as a whole word.
-- "patient/Patient.read" matches, "patient/Patient.reads" and "patient/Patient.read.x" do not.
local function has_scope(scope_string, wanted)
  -- The claim may be missing. Treat missing as "no scopes".
  if type(scope_string) ~= "string" then
    return false
  end
  -- Walk the words. %S+ takes every run of non-space characters.
  for word in string.gmatch(scope_string, "%S+") do
    if word == wanted then
      return true
    end
  end
  return false
end

-- Rules for the AI route. Deny by default: only POST on exactly /ai/chat, with the ai/chat scope.
-- Returns true when every rule passes, so the request goes on to ai-prompt-guard and ai-proxy.
-- Returns false when a rule fails. The answer has already been sent and the decision recorded
-- (deny does both), so the caller only has to stop.
local function check_ai(claims, path)
  -- Rule A1: only POST. Kong's route also matches GET, and GET is not offered for chat.
  if kong.request.get_method() ~= "POST" then
    deny(403, "forbidden", "This method is not allowed.", "method")
    return false
  end

  -- Rule A2: the path must be exactly /ai/chat. Kong matches routes by prefix, so /ai/chat/extra
  -- reaches this plugin. The exact comparison refuses it.
  if path ~= "/ai/chat" then
    deny(403, "forbidden", "Only /ai/chat is allowed.", "path")
    return false
  end

  -- Rule B: the token must carry the ai/chat scope as a whole word.
  if not has_scope(claims.scope, "ai/chat") then
    deny(403, "forbidden", "The token does not allow AI operations.", "scope")
    return false
  end

  -- Every rule passed.
  return true
end

-- Access phase: runs for every request that reaches the fhir or ai route, after jwt has accepted the token.
function FhirGuard:access(conf)
  -- The raw token string. jwt stores it here after it verified the signature and expiry.
  local token = kong.ctx.shared.authenticated_jwt_token

  -- Should never happen after jwt accepted the request. Deny anyway, so an unknown state fails closed.
  if not token then
    return deny(401, "login", "Missing or invalid bearer token.", "token")
  end

  -- Parse the token. parser:new returns the parsed token, or nil and an error message.
  local parsed, err = jwt_parser:new(token)
  if not parsed then
    return deny(403, "forbidden", "The token could not be read.", "token")
  end

  -- The decoded payload: the claims table, with fields such as scope, patient and iss.
  local claims = parsed.claims or {}

  -- From here on every log line of this request names the caller, allowed or denied.
  record_identity(claims)

  -- The request path, without the query string. The branches below both read it.
  local path = kong.request.get_path()

  -- AI branch: every path that starts with /ai. string.sub compares plain text, so no escaping is needed.
  -- Anything under /ai that is not exactly /ai/chat is denied inside check_ai.
  if string.sub(path, 1, 3) == "/ai" then
    -- check_ai returns false when a rule failed. It has then already recorded the deny and sent the answer,
    -- so stop here and do not record an allow.
    if not check_ai(claims, path) then
      return
    end
    -- All AI rules passed. Record the allow, then return nothing, so the request goes on to ai-prompt-guard.
    record_decision("allow")
    return
  end

  -- FHIR branch: the rules below are the /fhir rules, unchanged by the AI route.

  -- Rule 1a: only GET. Writes are not offered through this gateway.
  if kong.request.get_method() ~= "GET" then
    return deny(403, "forbidden", "This method is not allowed.", "method")
  end

  -- Rule 1b: the path must be exactly /fhir/Patient/<id>. The capture takes one segment with no slash.
  local id = string.match(path, "^/fhir/Patient/([^/]+)$")
  if not id then
    return deny(403, "forbidden", "Only single Patient reads are allowed.", "path")
  end

  -- Rule 2: the token must carry the read scope for Patient.
  if not has_scope(claims.scope, "patient/Patient.read") then
    return deny(403, "forbidden", "The token does not allow reading Patient.", "scope")
  end

  -- Rule 3: the patient in the token must be the patient asked for.
  -- The message does not name either patient, so it reveals nothing about other records.
  if claims.patient ~= id then
    return deny(403, "forbidden", "The token does not allow this patient.", "patient_mismatch")
  end

  -- All three rules pass. Record the allow, then return nothing, so the request goes on to the mock FHIR server.
  record_decision("allow")
end

-- Header filter: runs when Kong sends the response headers. Decides whether the body must be rewritten.
function FhirGuard:header_filter(conf)
  -- The HTTP status of the response, for example 401.
  local status = ngx.status

  -- The response content type. Kong's own errors use application/json. Our FHIR answers use fhir+json.
  local ctype = ngx.header["Content-Type"] or ""
  if type(ctype) == "table" then
    -- A repeated header comes back as a list. Use the first entry.
    ctype = ctype[1] or ""
  end

  -- "exit" means Kong made this response itself (jwt or our own deny). "service" means the mock answered.
  local source = kong.response.get_source()

  -- Rewrite only Kong-made 400, 401 and 429 answers that are not already FHIR.
  -- Kong makes a 400 when ai-prompt-guard blocks a prompt. Kong's body for it is plain JSON, not FHIR,
  -- so we replace it with one generic OperationOutcome. The client learns nothing about which rule matched.
  -- Answers from the mock are never rewritten, because their source is "service".
  local wanted = (status == 400 or status == 401 or status == 429)
  if wanted and source ~= "service" and not string.find(ctype, "application/fhir+json", 1, true) then
    -- Remember for body_filter that this response must be replaced.
    ngx.ctx.fhir_rewrite = status
    -- Set the FHIR content type on the replacement.
    ngx.header["Content-Type"] = "application/fhir+json"
    -- The old length no longer fits. Clear it, so nginx sends the body in chunks instead.
    ngx.header["Content-Length"] = nil
  end
end

-- Body filter: runs for each piece of the response body. Replaces the whole body at the end.
function FhirGuard:body_filter(conf)
  -- Nothing to do unless header_filter marked this response for rewriting.
  local status = ngx.ctx.fhir_rewrite
  if not status then
    return
  end

  -- ngx.arg[2] is true on the last piece of the body.
  if ngx.arg[2] then
    -- Last piece: send the whole OperationOutcome once.
    -- 400 means the gateway rejected the request ("invalid"), 401 means login, 429 means throttled.
    -- The 400 text is deliberately generic: it does not say which pattern matched.
    if status == 400 then
      ngx.arg[1] = outcome("invalid", "The request was rejected by the gateway.")
    elseif status == 401 then
      ngx.arg[1] = outcome("login", "Missing or invalid bearer token.")
    else
      ngx.arg[1] = outcome("throttled", "Too many requests.")
    end
  else
    -- Earlier pieces: send nothing. The original body is dropped, so only one body reaches the client.
    ngx.arg[1] = ""
  end
end

return FhirGuard
