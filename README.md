<div align="center">

# kingsland-setup

**Idempotent macOS development bootstrap, served from the edge.**

[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-F38020?logo=cloudflare&logoColor=white)](https://workers.cloudflare.com)
[![Wrangler](https://img.shields.io/badge/wrangler-4.x-0051C3?logo=cloudflare&logoColor=white)](https://developers.cloudflare.com/workers/wrangler/)
[![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon%20%7C%20Intel-000000?logo=apple&logoColor=white)](#requirements)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](src/setup.sh)

```sh
curl -fsSL https://kingsland.network/setup.sh | bash
```

</div>

---

## Overview

`kingsland-setup` is a tiny Cloudflare Worker that serves a single, curated
macOS development bootstrap script at **`https://kingsland.network/setup.sh`**.
Run it on a fresh Mac and you get Homebrew, a curated formula and cask list,
a configured `zsh`, and a ready-to-use shell — in one command.

The interesting code is the shell script itself. The worker is a thin static
responder: two source files, one config file, and no runtime fetching.

## Highlights

- **One-liner install** — `curl | bash` on a fresh Mac, with proper sudo handling
- **Idempotent** — detects what's already installed and skips it; safe to re-run
- **Zero surprises** — no KV, no asset storage, no runtime fetch; the script is inlined at build time
- **Curated stack** — Homebrew, ~35 formulas, a handful of casks, and a polished `zsh`
- **Pretty output** — progress counters, per-item status, final summary
- **Safe sudo** — prompts once, refreshes in the background, refuses to run as root

## Quick start

On a fresh machine:

```sh
curl -fsSL https://kingsland.network/setup.sh | bash
```

The script reads the sudo password from `/dev/tty`, so the one-liner works
even when piped. If your terminal does not expose `/dev/tty`, download it
first:

```sh
curl -fsSL https://kingsland.network/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh
```

## What the script does

| Stage          | Action                                                                   |
| -------------- | ------------------------------------------------------------------------ |
| Preflight      | Verifies macOS, detects architecture, installs Xcode Command Line Tools  |
| Sudo           | Prompts once, refreshes credentials in the background, refuses root      |
| Homebrew       | Installs Homebrew if missing, then loads `shellenv`                      |
| Taps           | Adds required taps (currently `oven-sh/bun`)                             |
| Formulas       | Installs a curated list of CLI tools (git, gh, fzf, ripgrep, starship …) |
| Casks          | Installs GUI apps (Android Studio, Inkscape, ngrok …)                    |
| Post-install   | Configures `fzf` key-bindings, sets `zsh` as the default shell           |
| Dotfiles       | Writes a consolidated `~/.zshrc` (any existing file is backed up first)  |
| Summary        | Prints counts of installed / skipped / failed items                      |

## Requirements

- macOS (Apple Silicon or Intel)
- Run as your regular user — **not** `root`. Homebrew refuses root installs;
  the script exits early if `EUID == 0`.
- Network access to `raw.githubusercontent.com` (Homebrew installer) and
  `formulae.brew.sh`.

## How it works

```
   ┌──────────────────────────────┐        ┌────────────────────────────┐
   │  curl kingsland.network/     │───────▶│   Cloudflare Worker        │
   │          setup.sh            │        │   (kingsland-setup)        │
   └──────────────────────────────┘        └──────────────┬─────────────┘
                                                          │  inlined at
                                                          │  build time
                                                          ▼
                                           ┌────────────────────────────┐
                                           │  src/setup.sh              │
                                           │  (bundled as a Text module)│
                                           └────────────────────────────┘
```

- `wrangler.toml` declares `[[rules]] type = "Text" globs = ["**/*.sh"]`,
  which tells Wrangler to bundle `.sh` files as text modules that can be
  imported from JavaScript.
- `src/worker.js` does `import setupScript from "./setup.sh"` — the script
  contents are inlined as a constant string at build time.
- Requests to `/` and `/setup.sh` return that string with
  `content-type: text/x-shellscript`. Every other path returns `404`.

There is no KV, no R2, no asset storage, no runtime fetch. Publishing a
script change means re-running `pnpm run deploy`.

## Local development

```sh
pnpm install          # install dependencies
pnpm run login        # one-time Cloudflare OAuth login
pnpm run dev          # local dev server at http://localhost:8787
```

Verify the served content while `dev` is running:

```sh
curl http://localhost:8787/setup.sh | less
```

## Deploy

```sh
pnpm run deploy
```

`pnpm run deploy` is wired to [`scripts/deploy.sh`](scripts/deploy.sh), which
runs a preflight before publishing:

1. Parses `zone_name` entries from `wrangler.toml`.
2. Verifies that `wrangler` is authenticated and extracts the account id.
3. If `CLOUDFLARE_API_TOKEN` is set (scope: `zone:read`), confirms each zone
   is reachable from the authenticated account.
4. Delegates to `wrangler deploy`.

> **Prerequisite:** the `kingsland.network` zone must live in the same
> Cloudflare account as the token you authenticated with via
> `pnpm run login`.

Useful extras:

```sh
pnpm run tail         # stream logs from the deployed worker
pnpm run whoami       # show the current Cloudflare account / token scopes
```

## Editing the script

All bootstrap logic lives in [`src/setup.sh`](src/setup.sh). Reuse the
existing UI helpers (`header`, `sub`, `render_item`, `run_quiet`, `have`) and
update the `COUNT_INSTALLED / COUNT_SKIPPED / COUNT_FAILED / FAILED_ITEMS`
counters so the final summary stays accurate.

Every step must remain **idempotent** — this is the load-bearing invariant
that makes `curl ... | bash` safe.

Typical update flow:

```sh
# edit src/setup.sh
pnpm run dev          # verify locally at http://localhost:8787/setup.sh
pnpm run deploy       # publish (runs the preflight first)
```

## Project layout

```
kingsland-setup/
├── src/
│   ├── worker.js         # Cloudflare Worker — serves the script
│   └── setup.sh          # the bootstrap script itself
├── scripts/
│   └── deploy.sh         # deploy preflight + wrangler deploy wrapper
├── wrangler.toml         # worker config, routes, Text module rule
├── package.json          # pnpm scripts (dev, deploy, tail, login, …)
└── README.md
```

## Troubleshooting

<details>
<summary><strong>First deploy returns <code>403 Forbidden</code> with an HTML body</strong></summary>

The Cloudflare account has not subscribed to the Workers Free plan yet.
Open the Workers dashboard once to accept the plan, then retry:

```
https://dash.cloudflare.com/<account-id>/workers-and-pages
```

</details>

<details>
<summary><strong>Preflight says a zone is not accessible</strong></summary>

The token you authenticated with does not have access to that zone. Make
sure `kingsland.network` lives in the same Cloudflare account you logged in
with via `pnpm run login`.

</details>

<details>
<summary><strong><code>sudo</code> hangs when running via <code>curl | bash</code></strong></summary>

Your terminal does not expose `/dev/tty`. Download the script first and run
it directly:

```sh
curl -fsSL https://kingsland.network/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh
```

</details>
