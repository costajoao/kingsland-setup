# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Cloudflare Worker (`kingsland-setup`) whose only job is to serve an idempotent macOS bootstrap shell script at `https://kingsland.network/setup.sh` (and `/`). The interesting code is the shell script itself; the worker is a thin static-text responder.

## Commands

```sh
pnpm run dev       # wrangler dev → curl http://localhost:8787/setup.sh
pnpm run deploy    # wrangler deploy
pnpm run tail      # live logs from the deployed worker
pnpm run whoami    # show Cloudflare account/token scopes
pnpm run login     # one-time OAuth login
```

There are no tests, no linter, and no build step.

## Architecture

Two files in `src/` and one config file do everything — and the mechanism connecting them is non-obvious:

- `wrangler.toml` declares `[[rules]] type = "Text" globs = ["**/*.sh"]`. This makes wrangler bundle `.sh` files as **text modules** that can be `import`ed from the worker entry.
- `src/worker.js` does `import setupScript from "./setup.sh"` — at build time wrangler inlines the entire `setup.sh` as a string constant. There is no runtime fetch, no KV, no asset storage. Deploying a script change means re-running `wrangler deploy`.
- The worker returns that string for both `/` and `/setup.sh` with `content-type: text/x-shellscript`. Any other path → 404.
- Routes in `wrangler.toml` bind the worker to `kingsland.network/` and `kingsland.network/setup.sh` via `zone_name`. The zone must live in the same Cloudflare account as the authenticated wrangler token.

### Editing the script

Work in `src/setup.sh`. It already defines its own UI helpers (`header`, `sub`, `render_item`, `run_quiet`, `have`) and tracks `COUNT_INSTALLED / COUNT_SKIPPED / COUNT_FAILED / FAILED_ITEMS` for the final summary — reuse these rather than inventing new output primitives. The script runs with `set -uo pipefail` (no `-e`): individual steps are expected to check their own failure and update counters.

The script must stay **idempotent** — every step should detect what's already installed (`have <cmd>`, file existence checks, etc.) and skip instead of re-running. This is the load-bearing invariant for `curl ... | bash` usage.

After editing `src/setup.sh`, `pnpm run dev` and hit `http://localhost:8787/setup.sh` to verify the served content before deploying.
