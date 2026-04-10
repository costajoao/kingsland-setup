#!/usr/bin/env bash
#
# Deploy preflight for kingsland-setup.
#
# Checks that:
#   1. wrangler is authenticated
#   2. The zone(s) referenced in wrangler.toml are reachable from the
#      authenticated Cloudflare account (when CLOUDFLARE_API_TOKEN is set)
#
# Then delegates to `wrangler deploy`.

set -uo pipefail

cd "$(dirname "$0")/.."

ARROW="==>"
if [[ -t 1 ]]; then
  c_reset=$'\033[0m'
  c_bold=$'\033[1m'
  c_green=$'\033[1;32m'
  c_yellow=$'\033[1;33m'
  c_red=$'\033[1;31m'
  c_cyan=$'\033[1;36m'
else
  c_reset="" c_bold="" c_green="" c_yellow="" c_red="" c_cyan=""
fi

info() { printf "%s%s%s %s%s%s\n" "$c_cyan" "$ARROW" "$c_reset" "$c_bold" "$*" "$c_reset"; }
ok()   { printf "%s✓%s %s\n" "$c_green" "$c_reset" "$*"; }
warn() { printf "%s!%s %s\n" "$c_yellow" "$c_reset" "$*"; }
fail() { printf "%s✗%s %s\n" "$c_red" "$c_reset" "$*" >&2; exit 1; }

# ------------------------------------------------------------
# 1. Parse zone_name(s) from wrangler.toml
# ------------------------------------------------------------
if [[ ! -f wrangler.toml ]]; then
  fail "wrangler.toml not found (cwd: $(pwd))"
fi

ZONES=$(grep -oE 'zone_name[[:space:]]*=[[:space:]]*"[^"]+"' wrangler.toml \
  | sed -E 's/.*"([^"]+)".*/\1/' | sort -u)

if [[ -z "${ZONES:-}" ]]; then
  fail "no zone_name found in wrangler.toml"
fi

# ------------------------------------------------------------
# 2. Ensure wrangler is authenticated
# ------------------------------------------------------------
info "Verifying wrangler authentication"

if ! command -v wrangler >/dev/null 2>&1; then
  fail "wrangler not on PATH — run 'pnpm install' first"
fi

if ! whoami_out=$(wrangler whoami 2>&1); then
  printf '%s\n' "$whoami_out" >&2
  fail "wrangler is not authenticated — run 'pnpm run login'"
fi

ACCOUNT_ID=$(printf '%s\n' "$whoami_out" | grep -oE '[a-f0-9]{32}' | head -1 || true)
if [[ -n "$ACCOUNT_ID" ]]; then
  ok "authenticated (account $ACCOUNT_ID)"
else
  ok "authenticated"
fi

# ------------------------------------------------------------
# 3. Verify zone access
# ------------------------------------------------------------
# Wrangler's OAuth token is not exposed to user scripts, so the direct
# zone check requires CLOUDFLARE_API_TOKEN (scope: zone:read). Without it
# we warn and proceed; wrangler deploy will still fail (with a less clear
# error) if the zone is not reachable.
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  while IFS= read -r zone; do
    [[ -z "$zone" ]] && continue
    info "Checking zone '$zone' via Cloudflare API"
    if ! response=$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$zone" 2>/dev/null); then
      fail "Cloudflare API call failed for zone '$zone'"
    fi
    if ! printf '%s' "$response" | grep -qE '"count":[1-9]'; then
      fail "zone '$zone' is NOT accessible with the current token — make sure it lives in the authenticated Cloudflare account and the token has zone:read"
    fi
    ok "zone '$zone' accessible"
  done <<< "$ZONES"
else
  warn "CLOUDFLARE_API_TOKEN not set — skipping direct zone API check"
  warn "set it with zone:read scope to enable stricter preflight"
  while IFS= read -r zone; do
    [[ -z "$zone" ]] && continue
    printf "    will deploy routes under: %s\n" "$zone"
  done <<< "$ZONES"
fi

# ------------------------------------------------------------
# 4. Deploy
# ------------------------------------------------------------
info "Deploying worker"
exec wrangler deploy "$@"
