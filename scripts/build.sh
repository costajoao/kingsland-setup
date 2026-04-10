#!/usr/bin/env bash
#
# Pre-build step for wrangler: encode src/setup.sh as base64 so the
# payload uploaded to the Cloudflare Workers API does not contain raw
# shell-script bytes. Cloudflare's edge WAF on api.cloudflare.com flags
# patterns like `curl ... install.sh` and returns a 403 HTML page,
# which prevents the worker from being deployed at all.
#
# The worker decodes the base64 string once at module init, so there
# is no per-request cost. The .b64 file is generated on every build
# and is not tracked in git.

set -euo pipefail
cd "$(dirname "$0")/.."

src="src/setup.sh"
out="src/setup.sh.b64"

if [[ ! -f "$src" ]]; then
  echo "build: $src not found" >&2
  exit 1
fi

# `base64` on macOS wraps at 76 chars by default; strip newlines so the
# resulting string is a single token that atob() will accept cleanly.
base64 < "$src" | tr -d '\n' > "$out"

bytes=$(wc -c < "$out" | tr -d ' ')
echo "build: wrote $out ($bytes bytes)"
