-- fhir-guard: the Kong plugin that enforces what a verified token may do.
-- It runs only after the jwt plugin has accepted the token (see PRIORITY below).
-- Rules, deny by default:
--   1. Only GET on exactly /fhir/Patient/<id>.
--   2. The token's "scope" claim must contain "patient/Patient.read" as a whole word.
--   3. The token's "patient" claim must equal <id>.
-- It also rewrites Kong's own 401 and 429 bodies into FHIR OperationOutcome.

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

-- Send an error answer with a FHIR body. Ends the request at once; no later plugin runs.
local function deny(status, code, text)
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

-- Access phase: runs for every request that reaches the fhir route, after jwt has accepted the token.
function FhirGuard:access(conf)
  -- The raw token string. jwt stores it here after it verified the signature and expiry.
  local token = kong.ctx.shared.authenticated_jwt_token

  -- Should never happen after jwt accepted the request. Deny anyway, so an unknown state fails closed.
  if not token then
    return deny(401, "login", "Missing or invalid bearer token.")
  end

  -- Parse the token. parser:new returns the parsed token, or nil and an error message.
  local parsed, err = jwt_parser:new(token)
  if not parsed then
    return deny(403, "forbidden", "The token could not be read.")
  end

  -- The decoded payload: the claims table, with fields such as scope, patient and iss.
  local claims = parsed.claims or {}

  -- Rule 1a: only GET. Writes are not offered through this gateway.
  if kong.request.get_method() ~= "GET" then
    return deny(403, "forbidden", "This method is not allowed.")
  end

  -- Rule 1b: the path must be exactly /fhir/Patient/<id>. The capture takes one segment with no slash.
  local id = string.match(kong.request.get_path(), "^/fhir/Patient/([^/]+)$")
  if not id then
    return deny(403, "forbidden", "Only single Patient reads are allowed.")
  end

  -- Rule 2: the token must carry the read scope for Patient.
  if not has_scope(claims.scope, "patient/Patient.read") then
    return deny(403, "forbidden", "The token does not allow reading Patient.")
  end

  -- Rule 3: the patient in the token must be the patient asked for.
  -- The message does not name either patient, so it reveals nothing about other records.
  if claims.patient ~= id then
    return deny(403, "forbidden", "The token does not allow this patient.")
  end

  -- All three rules pass. Return nothing, so the request goes on to the mock FHIR server.
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

  -- Rewrite only Kong-made 401 and 429 answers that are not already FHIR.
  -- Answers from the mock are never rewritten.
  local wanted = (status == 401 or status == 429)
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
    -- Last piece: send the whole OperationOutcome once. 401 means login, 429 means throttled.
    if status == 401 then
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
