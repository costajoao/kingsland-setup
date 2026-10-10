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

Three rules the script depends on:

- **Everything runs from `main()`, called on the last line.** Under `curl | bash`, bash reads the script from the pipe as it executes; a child process that reads stdin (an installer prompt) would swallow the not-yet-read top-level lines and the run would stop silently halfway. That is why `run_quiet` and the Homebrew installer get `</dev/null`, and why anything interactive (`chsh`, the menu) reads `/dev/tty`. Never add top-level calls after `main "$@"`.
- **bash 3.2.** `curl | bash` runs macOS's `/bin/bash` 3.2: no associative arrays, `mapfile`, `${var,,}` or negative indexes. Packages are grouped in parallel arrays (`GROUP_IDS`, `GROUP_LABELS`, `GROUP_DEFAULT`, `GROUP_TAPS`, `GROUP_FORMULAS`, `GROUP_CASKS`); a new package goes in one group's string, a new group adds one entry to every array at the same index. Check with `/bin/bash -n src/setup.sh`.
- **Empty arrays under `set -u`** are expanded as `${arr[@]+"${arr[@]}"}`, or bash 3.2 aborts with "unbound variable".

The script must stay **idempotent** — every step should detect what's already installed (`have <cmd>`, file existence checks, etc.) and skip instead of re-running. This is the load-bearing invariant for `curl ... | bash` usage.

After editing `src/setup.sh`, `pnpm run dev` and hit `http://localhost:8787/setup.sh` to verify the served content before deploying.
