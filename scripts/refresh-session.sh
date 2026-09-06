#!/usr/bin/env bash
# Refresh the Plane CE app-session cookie (``session-id``) into an env file.
#
# Signs in like the web app (CSRF + /auth/sign-in/, the same flow as
# ``plane_mcp/app_session.py``) and rewrites ``PLANE_SESSION_COOKIE`` in the
# env file. Restart the MCP server afterwards: a cookie is only read at
# process start, and once it expires in-process recovery is impossible.
#
# Usage: refresh-session.sh [ENV_FILE]
#        ENV_FILE defaults to $PLANE_MCP_ENV_FILE or ~/.config/plane-mcp/env
#
# Requires: curl, python3. Never echoes the password or the cookie value.
set -euo pipefail

env_file="${1:-${PLANE_MCP_ENV_FILE:-$HOME/.config/plane-mcp/env}}"

if [ ! -f "$env_file" ]; then
    echo "refresh-session: env file not found: $env_file" >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$env_file"
set +a

origin="${PLANE_BASE_URL%/}"
if [ -z "$origin" ]; then
    echo "refresh-session: PLANE_BASE_URL is not set in $env_file" >&2
    exit 1
fi
if [ -z "${PLANE_SESSION_EMAIL:-}" ] || [ -z "${PLANE_SESSION_PASSWORD:-}" ]; then
    echo "refresh-session: PLANE_SESSION_EMAIL / PLANE_SESSION_PASSWORD are required in $env_file" >&2
    exit 1
fi

jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

# 1. CSRF token (also plants the csrftoken cookie in the jar).
csrf="$(curl -fsS -c "$jar" "$origin/auth/get-csrf-token/" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["csrf_token"])')" || {
    echo "refresh-session: could not fetch a CSRF token from $origin" >&2
    exit 1
}

# 2. Sign in. Success is a response that plants a session-id cookie — the
#    same criterion the server itself uses (app_session.py).
http_code="$(curl -sS -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" \
    -H "X-CSRFToken: $csrf" \
    -H "Referer: $origin/" \
    -H "Origin: $origin" \
    --data-urlencode "email=$PLANE_SESSION_EMAIL" \
    --data-urlencode "password=$PLANE_SESSION_PASSWORD" \
    "$origin/auth/sign-in/")"

# Netscape jar format: domain flag path secure expiry name value. session-id
# is HttpOnly, so its line carries a "#HttpOnly_" prefix on the domain field,
# which does not shift the name/value columns.
session_id="$(awk -F '\t' '$6 == "session-id" { sid = $7 } END { print sid }' "$jar")"
if [ -z "$session_id" ]; then
    echo "refresh-session: Plane sign-in failed (HTTP $http_code); check PLANE_SESSION_EMAIL / PLANE_SESSION_PASSWORD" >&2
    exit 1
fi

# 3. Rewrite PLANE_SESSION_COOKIE atomically, preserving the file's mode.
tmp="$(mktemp "$(dirname "$env_file")/.$(basename "$env_file").XXXXXX")"
trap 'rm -f "$jar" "$tmp"' EXIT
chmod --reference="$env_file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
awk -v sid="$session_id" '
    BEGIN { done = 0 }
    /^PLANE_SESSION_COOKIE=/ { print "PLANE_SESSION_COOKIE=" sid; done = 1; next }
    { print }
    END { if (!done) print "PLANE_SESSION_COOKIE=" sid }
' "$env_file" > "$tmp"
mv "$tmp" "$env_file"

echo "refresh-session: session cookie refreshed in $env_file (restart the MCP server to pick it up)"
