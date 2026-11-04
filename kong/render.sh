#!/bin/sh
# Renders the Kong config. Runs once, in the kong-config container (alpine), before Kong starts.
# Plain POSIX sh on purpose: alpine's shell is busybox sh, not bash.
# Takes Keycloak's public key, wraps it as a PEM block and fills it into kong.yml.tpl.
# It holds only the PUBLIC key. No private key is read, stored or written anywhere.

# Stop at the first failing command (-e) and on any unset variable (-u).
# A broken render must fail loudly, not write a half-empty config for Kong to load.
set -eu

# Keycloak's realm endpoint. Inside the Docker network the host name is "keycloak", port 8080.
REALM_URL="http://keycloak:8080/realms/fhir"

# Input template, as mounted read-only into this container from the repo's kong/ folder.
TEMPLATE="/kong-src/kong.yml.tpl"

# Output file. /out is the shared named volume that the kong service reads.
OUT="/out/kong.yml"

# The exact text that the template uses as the key placeholder.
PLACEHOLDER="__KEYCLOAK_PUBLIC_KEY_PEM__"

# Temporary files for the realm JSON and the PEM block. mktemp makes unique names.
REALM_FILE=$(mktemp)
PEM_FILE=$(mktemp)

# Remove both temporary files when the script exits, whether it succeeds or fails.
trap 'rm -f -- "$REALM_FILE" "$PEM_FILE"' EXIT

# Wait for Keycloak to answer. Retry once per 2 seconds, up to 60 tries (about 2 minutes).
# The "until" condition does not trigger "set -e", so a failed try is not fatal by itself.
TRIES=0
until curl -fsS "$REALM_URL" -o "$REALM_FILE"; do
  TRIES=$((TRIES + 1))
  if [ "$TRIES" -ge 60 ]; then
    echo "render: Keycloak did not answer at $REALM_URL" >&2
    exit 1
  fi
  sleep 2
done

# Read the "public_key" field from the realm JSON. -r prints the raw string without quotes.
# "// empty" prints nothing when the field is missing, instead of the text "null".
KEY=$(jq -r '.public_key // empty' "$REALM_FILE")

# An empty key means the realm is not what we expect. Stop here instead of rendering a broken config.
if [ -z "$KEY" ]; then
  echo "render: the realm at $REALM_URL has no public_key" >&2
  exit 1
fi

# Build the PEM block. OpenSSL wants the base64 body wrapped at 64 characters per line.
# "fold -w 64" does that wrapping. Then the BEGIN and END lines go around it.
{
  echo "-----BEGIN PUBLIC KEY-----"
  printf '%s\n' "$KEY" | fold -w 64
  echo "-----END PUBLIC KEY-----"
} > "$PEM_FILE"

# Fill the placeholder line with the PEM block.
# awk reads the template line by line. When a line holds the placeholder, it keeps the indentation
# in front of the placeholder and prints that indentation before every PEM line.
# That keeps the YAML valid: the PEM lines stay inside the "rsa_public_key: |" block.
awk -v pem="$PEM_FILE" -v ph="$PLACEHOLDER" '
  index($0, ph) > 0 {
    # Text before the placeholder on this line: the indentation.
    prefix = substr($0, 1, index($0, ph) - 1)
    # Print each PEM line with that indentation in front.
    while ((getline line < pem) > 0) print prefix line
    close(pem)
    next
  }
  # Any other line passes through unchanged.
  { print }
' "$TEMPLATE" > "$OUT"

# Check that no placeholder is left in the output. A leftover placeholder would make Kong fail to load.
if grep -q "$PLACEHOLDER" "$OUT"; then
  echo "render: placeholder still present in $OUT" >&2
  exit 1
fi

# Confirm the output holds a PEM block. Prints one line for the log.
echo "render: wrote $OUT with $(grep -c 'BEGIN PUBLIC KEY' "$OUT") public key block(s)"
