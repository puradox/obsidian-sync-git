# Reference guide

Everything beyond the [README](../README.md)'s quick start: internals, all
configuration options, security notes, and troubleshooting.

- [How a sync cycle works](#how-a-sync-cycle-works)
- [Conflict handling](#conflict-handling)
- [Changing the sync schedule](#changing-the-sync-schedule)
- [AI commit messages](#ai-commit-messages)
- [Keeping the vault in a subdirectory of the repo](#keeping-the-vault-in-a-subdirectory-of-the-repo)
- [Configuration reference](#configuration-reference)
- [Docker Compose](#docker-compose)
- [Recommended GitHub setup](#recommended-github-setup)
- [Security: secrets as environment variables](#security-secrets-as-environment-variables)
- [Rotating secrets](#rotating-secrets)
- [Getting the token with Node.js](#getting-the-token-with-nodejs)
- [Container images](#container-images)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [How it was built](#how-it-was-built-design-to-reality-notes)
- [Files](#files)

## How a sync cycle works

```
   Obsidian devices  ──sync──►  [ this container ]  ──git push──►  origin/main
        ▲                        (the only writer to             ▲
        └──────sync────────────   the /vault working tree)       │
                                                                 merged PRs
                                     automation (Claude Code    ─┘
                                     skills) works on a SEPARATE
                                     clone and lands changes via
                                     PRs to main
```

- **The vault working tree is authoritative.** Vault edits win conflicts.
- **This container is the ONLY writer to `/vault`.** Automation never touches
  the working tree directly — it operates on its own clone and merges into
  `main`. Those merged changes reach the vault only through this bridge.
- **Conflicts are never auto-resolved.** If a merged skill PR conflicts with a
  vault edit, the bridge aborts the rebase, leaves the repo clean, and alerts.
  The stale PR must be rebased onto the current vault and re-merged (or closed)
  upstream. See [Conflict handling](#conflict-handling).

> ⚠️ **The invariant:** nothing other than this container may write to the
> `/vault` working tree. Do not `git commit`/`push` into it from elsewhere, do
> not mount it read-write into other tools, and do not let a second bridge
> instance point at the same vault. Automation changes must arrive as PRs to
> `main` only.

It runs **one scheduled bridge cycle** on a cron schedule — no continuous sync,
no web server, nothing else. Every tick (default every 15 min), the whole cycle
runs under a non-blocking `flock` so cycles can never overlap:

1. `ob sync` — pull device changes down into the working tree.
2. `git add -A && commit` — if `git status --porcelain` is non-empty. The
   commit message is [AI-generated](#ai-commit-messages) when possible, else a
   deterministic fallback.
3. `git pull --rebase origin main` — bring in merged skill PRs. On a rebase
   **conflict**: abort, log, alert; the repo is left clean and nothing is
   pushed (vault-wins). Network failures are distinguished from conflicts and
   simply retry next tick.
4. `git push origin main`. If rejected (a merge raced us), fetch + rebase once
   and retry; otherwise defer to the next tick.
5. `ob sync` — propagate merged skill changes back out to devices.

`docker logs` shows each step. A cycle failure logs loudly and retries on the
next tick; the container itself exits non-zero only on unrecoverable **config**
errors at startup.

On first start the container: reads config, configures ssh, `git init`s the
repo and adds the remote, installs a vault `.gitignore` (if absent), runs
`ob sync-setup` idempotently, and (by default) runs one bridge cycle
immediately before handing off to the scheduler. Its `HEALTHCHECK` is baked
into the image, so `docker ps` shows health with no extra flags.

> **First push / bootstrap note.** If `origin/main` doesn't exist yet, the
> first cycle creates it from the vault contents. If the vault is **empty**
> and `main` already has content, the bridge adopts `main` and syncs it out to
> your devices. If **both** sides have content with differing history, the
> first `rebase` will conflict — start from an empty `main`, or seed `main`
> from the same vault, so history lines up.

## Conflict handling

The bridge **never** auto-resolves. When step 3's rebase conflicts:

1. It aborts the rebase (`git rebase --abort`), restoring the working tree to
   the vault commit — clean, no conflict markers.
2. It does **not** push. `main` keeps the merged skill commit; local `main`
   keeps the vault commit; they diverge.
3. It logs an `ALERT` line each tick and the healthcheck eventually goes
   unhealthy.

Because the vault always wins, resolution happens **upstream**: rebase the
conflicting skill PR onto the current vault (or close it). Once the skill
change no longer conflicts, the next rebase applies cleanly and the cycle
resumes automatically. Non-conflicting skill changes (different files/regions)
always merge fine — no intervention needed.

## Changing the sync schedule

Add a line to `bridge.env` — for example, every 5 minutes:

```
CRON_SCHEDULE=*/5 * * * *
```

then recreate the container (`docker rm -f obsidian-bridge`, and run the
[start command](../README.md#5-start-the-bridge) again). If you pick a
schedule that isn't "every N minutes" — hourly, daily, a comma-list — also set
`HEALTH_STALE_SECONDS` to roughly twice your interval in whole seconds, or the
health check will misreport.

## AI commit messages

Out of the box, each commit is labeled
`vault auto-commit: N files changed (<timestamp>)`. If you give the bridge an
AI provider, it writes a one-line summary of what actually changed instead —
and for bigger changes it adds a short bulleted body under the subject line
(one bullet allowed per ~1,000 characters of diff, up to 5; tiny diffs stay
subject-only).
Add to `bridge.env` **either** an OpenAI-compatible provider (Groq, Gemini,
Ollama, OpenRouter, …):

```
LLM_API_BASE=https://api.groq.com/openai/v1
LLM_MODEL=llama-3.1-8b-instant
LLM_API_KEY=your-key
```

**or** Anthropic:

```
ANTHROPIC_API_KEY=your-key
```

> **Privacy note:** the diff of your notes is sent to that provider, and free
> tiers commonly use submitted data to improve their models. For fully private
> summaries, run a local Ollama
> (`LLM_API_BASE=http://host.docker.internal:11434/v1`) so the diff never
> leaves your machine.

How it works: in cycle step 2, `commit-message.sh` sends
`git diff --stat --cached` plus a capped ~8 KB diff sample to the LLM and uses
the reply as the commit message (subject only for small edits; subject + a
bulleted body for larger ones, one bullet per ~1,000 diff characters up to 5).
The bullet count and both parts' byte lengths are enforced in the script, so a
model that ignores the instructions can't produce a runaway message. Provider
selection (first match wins):

1. **OpenAI-compatible** — when `LLM_API_BASE` (with an `http(s)://` scheme) +
   `LLM_API_KEY` + `LLM_MODEL` are set, it POSTs to
   `${LLM_API_BASE}/chat/completions` with a Bearer key. `LLM_MAX_TOKENS`
   (default 1024) is generous so a model that "thinks" first (e.g. Gemini
   Flash-Lite) still has room for the summary.
2. **Anthropic** — when `ANTHROPIC_API_KEY` is set (and `LLM_*` is not).
3. **Fallback** — otherwise.

`LLM_API_BASE` **must include `https://`** (a schemeless URL is refused, to
avoid sending the key over cleartext http). Short timeout (10–15s), and it
**can never block or fail the commit**: any failure — no key, no network,
timeout, bad response — falls back to the deterministic message.

## Keeping the vault in a subdirectory of the repo

By default the vault **is** the repo root: every file in the repository syncs
to your Obsidian devices. If you want the repository to also hold things that
should *not* end up in Obsidian — a [Quartz](https://quartz.jzhao.xyz/) site
that publishes the vault, Claude Code skills, build scripts — set
`VAULT_SUBDIR` and only that folder is synced:

```
VAULT_SUBDIR=vault
```

which gives a layout like:

```
your-repo/
├── vault/            ← synced with your Obsidian devices (VAULT_SUBDIR)
├── quartz/           ← in git, invisible to Obsidian
├── .claude/skills/   ← in git, invisible to Obsidian
└── README.md
```

How it behaves:

- **git covers the whole repo; `ob sync` covers only the subdirectory.** Every
  cycle commits and pushes whatever changed anywhere in the repo, but only
  files under `VAULT_SUBDIR` are pulled from / pushed to your devices. Changes
  merged to `main` outside the subdirectory reach the bridge's working tree and
  stay there — your devices never see them.
- **The invariant applies to the whole repo, not just the vault folder.** The
  bridge is still the only writer to its `/vault` volume. Work on Quartz,
  skills, etc. in a **separate clone** of the repository and land changes
  through `main` (ideally via PRs); the bridge folds them in on its next cycle.
- **Bootstrap is the same as the root layout:** the first cycle needs history
  to line up. Start from an empty `main`, or seed `main` with the vault
  contents at the same subdirectory path.
- **Pick the layout up front.** Changing `VAULT_SUBDIR` (or `VAULT_NAME`)
  against existing volumes is refused at startup — it would otherwise download
  a second vault copy alongside the old one. To change it, start with fresh
  `vault`/`config` volumes.
- The bridge's default `.gitignore` is installed at `VAULT_SUBDIR/.gitignore`
  (only if that file doesn't exist), so its patterns stay scoped to the vault.

## Configuration reference

All configuration is via environment variables (see
[`.env.example`](../.env.example) for a ready-to-copy template). Every
**secret** var also accepts a `VAR_FILE` variant that reads the value from a
mounted file (see
[Security](#security-secrets-as-environment-variables)).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `VAULT_NAME` | ✅ | — | Obsidian Sync remote vault **name or id** (`ob sync-list-remote`). Fixed once volumes exist — the bridge refuses changes at startup. |
| `GIT_REMOTE_URL` | ✅ | — | GitHub remote, SSH form: `git@github.com:owner/repo.git`. |
| `OBSIDIAN_AUTH_TOKEN` / `_FILE` | ✅ | — | Non-interactive auth token (README setup, step 2). |
| `GIT_DEPLOY_KEY` | ✅* | — | The passphrase-less SSH private key **contents** (write access). |
| `GIT_DEPLOY_KEY_FILE` | ✅* | — | …or a path to the mounted key file (the secret-safer option). |
| `OBSIDIAN_VAULT_PASSWORD` / `_FILE` | E2EE only | — | E2EE password. Ignored for standard vaults. |
| `VAULT_SUBDIR` | optional | — (vault = repo root) | Subdirectory of the repo that holds the vault, e.g. `vault` — see [Keeping the vault in a subdirectory](#keeping-the-vault-in-a-subdirectory-of-the-repo). Fixed once volumes exist. |
| `LLM_API_BASE` | optional | — | OpenAI-compatible base URL (must include `https://`), e.g. `https://api.groq.com/openai/v1`. |
| `LLM_API_KEY` / `_FILE` | optional | — | Bearer key for the OpenAI-compatible provider. |
| `LLM_MODEL` | optional | — | Model id (e.g. `llama-3.1-8b-instant`, `gemini-3.1-flash-lite`). |
| `LLM_MAX_TOKENS` | optional | `1024` | Max output tokens for the OpenAI-compatible path. |
| `ANTHROPIC_API_KEY` / `_FILE` | optional | — | Enables the native Anthropic path (only if `LLM_*` is unset). |
| `ANTHROPIC_MODEL` | optional | `claude-haiku-4-5` | Model for the Anthropic path. |
| `CRON_SCHEDULE` | optional | `*/15 * * * *` | Cycle cadence (5-field cron). |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | optional | `Obsidian Bridge` / `…@localhost` | Commit identity (committer defaults to author). |
| `HEALTH_STALE_SECONDS` | optional | 2× interval for `*/N`, else 1800s | Healthcheck staleness threshold. Set it for non-`*/N` schedules. |
| `RUN_ON_START` | optional | `true` | Run one cycle at container start. |
| `OBSIDIAN_CONFIG_DIR` | optional | `.obsidian` | Only for a non-default vault config dir. |
| `OBSIDIAN_DEVICE_NAME` | optional | — | Device name shown in Sync version history. |

\* Provide the deploy key **either** as `GIT_DEPLOY_KEY` (contents) **or**
`GIT_DEPLOY_KEY_FILE` (a mounted path) — one is required.

### Volumes

| Mount | Holds |
|---|---|
| `/vault` | The git repo working tree (the vault is at its root, or at `VAULT_SUBDIR` inside it). The only writer is this container. |
| `/config` | `HOME`/state: `obsidian-headless/auth_token`, `obsidian-headless/sync/<id>/{config.json,state.db,sync.log}`, plus bridge markers (last success, configured vault). |

`obsidian-headless` keeps **all** its state under
`$XDG_CONFIG_HOME/obsidian-headless` (we set `XDG_CONFIG_HOME=/config`), so
`state.db` and friends live in `/config` and **never** land in the vault
(verified from the CLI source). Only two transient artifacts ever appear in the
vault — `.obsidian/.sync.lock` (a self-healing lock dir) and `.OBSIDIANTEST` (a
case-sensitivity probe) — and both are in the installed `.gitignore`.

> **Volume ownership.** The published image runs as UID:GID **1000:1000**.
> Named volumes (as in the examples above) inherit that automatically. For
> **bind** mounts, `chown -R 1000:1000` the host directories first, or rebuild
> the image with `--build-arg UID=… --build-arg GID=…` to match the owner.

### `.gitignore` installed into the vault

If the vault has no `.gitignore`, the bridge installs one covering
`.obsidian/workspace*` (per-device UI churn), `.obsidian/.sync.lock`,
`.OBSIDIANTEST`, and `.trash/`. The rest of `.obsidian/` (plugins, appearance,
etc.) is versioned. Edit the vault's `.gitignore` to taste — it's just a
committed file.

## Docker Compose

If you prefer Compose, everything can live inline in the compose file — no env
file needed. (Unlike an env file, compose `environment:` values may span
multiple lines, so even the deploy key fits.)

```yaml
services:
  bridge:
    image: ghcr.io/puradox/obsidian-sync-git:latest
    restart: unless-stopped
    environment:
      VAULT_NAME: My Vault
      GIT_REMOTE_URL: git@github.com:YOUR-USERNAME/YOUR-REPO.git
      OBSIDIAN_AUTH_TOKEN: paste-your-token-here
      # OBSIDIAN_VAULT_PASSWORD: only-for-e2ee-vaults
      GIT_DEPLOY_KEY: |
        -----BEGIN OPENSSH PRIVATE KEY-----
        ...contents of your passphrase-less deploy_key...
        -----END OPENSSH PRIVATE KEY-----
    volumes:
      - vault:/vault
      - config:/config

volumes:
  vault:
  config:
```

> **This makes your compose file a secrets file** — it now holds your auth
> token and a key with write access to your repo. That's fine while the file
> stays private on a machine you own, but **don't commit it to version
> control** in this form.

If you do want the compose file in git, move the secrets out: point
`env_file:` at a gitignored `bridge.env` (mode 600) for the single-line
values, and mount the deploy key instead of inlining it:

```yaml
    env_file: bridge.env          # VAULT_NAME, GIT_REMOTE_URL, OBSIDIAN_AUTH_TOKEN, …
    environment:
      GIT_DEPLOY_KEY_FILE: /keys/id
    volumes:
      - ./deploy_key:/keys/id:ro  # gitignore deploy_key too
      - vault:/vault
      - config:/config
```

More on the trade-offs: [Security](#security-secrets-as-environment-variables).

## Recommended GitHub setup

**Enable branch protection on `main`** with **"Require branches to be up to
date before merging."**

This is what makes the vault-wins model safe: it forces every automation PR to
be rebased onto the current `main` before it can merge. A stale skill PR then
surfaces its conflict **at review time** (a human sees it and rebases against
the current vault), instead of merging cleanly into `main` and then blowing up
inside the bridge's rebase every cycle.

> ⚠️ **Do NOT enable "Require a pull request before merging"** (or any rule
> that blocks direct pushes to `main`) with classic branch protection — the
> bridge itself pushes directly to `main`, and a deploy key cannot bypass that
> rule, so every cycle's push would be rejected. If you want to keep *humans*
> out of `main`, use a **repository ruleset** instead and add the bridge's
> deploy key to the ruleset's bypass list.

## Security: secrets as environment variables

This container takes its secrets (auth token, vault password, API key, and —
via `GIT_DEPLOY_KEY` — the deploy key) as **environment variables**. That's
simpler than file/secret mounts, but the trade-off is real:

- **`docker inspect` exposes them.** A container's env is stored in its config
  and printed by `docker inspect <container>` (`.Config.Env`). Anything that
  can reach the Docker API/socket — another container with the socket mounted,
  a monitoring agent, a CI job — can read every secret. Mounted-file /
  Docker-Swarm / k8s secrets are **not** in `docker inspect`.
- **Every in-container process can read them.** Env vars are inherited by all
  children and readable at `/proc/<pid>/environ` by anything running as the
  same user (`ob`, `git`, `curl`, `node` all run in that environment). A
  mounted 600 file is only read by the code that opens it. The bridge never
  logs secrets, and it **unsets `GIT_DEPLOY_KEY` after writing it to a 600
  file**, so the key isn't in the cron/git child environments — but the
  token/password/API keys must stay in env because `ob` reads them on every
  call.
- **Wider leakage surface.** `--env-file` is a plaintext file on disk (keep it
  `600`, mind backups); inline `-e SECRET=...` lands in shell history and the
  CLI's process args; compose `environment:` puts secrets in the compose file.
  A crash dump or a stray `env` in a log then carries them.
- **The deploy key is the crown jewel** — it has write access to your repo. In
  env it's exposed via `docker inspect` (and, until unset, the process tree).

**Is this OK?** For a **single-tenant, self-hosted** host (you own the machine
and the Docker daemon), the practical exposure is mostly to yourself —
acceptable, and the simplicity is worth it. It gets riskier when other
containers mount the Docker socket, the host is shared/monitored, or you paste
`docker inspect` output into an issue.

**Lower the risk even with env vars:**

- Use `--env-file bridge.env` (mode 600) instead of inline `-e SECRET=...` to
  keep secrets out of shell history.
- Mount the deploy key as a file and use `GIT_DEPLOY_KEY_FILE` rather than
  `GIT_DEPLOY_KEY` — with `docker run`:
  `-v "$PWD/deploy_key":/keys/id:ro -e GIT_DEPLOY_KEY_FILE=/keys/id`.
- Don't run untrusted containers with `/var/run/docker.sock` mounted; restrict
  who can reach the Docker API.
- Keep the deploy key repo-scoped (a GitHub *deploy key* already is) and rotate
  on exposure.
- On multi-tenant / shared hosts, prefer real secret stores. Every secret var
  also accepts a `VAR_FILE` variant (`OBSIDIAN_AUTH_TOKEN_FILE`,
  `LLM_API_KEY_FILE`, …) that reads the value from a mounted file — use those
  with Docker/Swarm or k8s secrets instead of the plain env var.

The container also pins github.com's Ed25519 host key and forces
`HostKeyAlgorithms=ssh-ed25519`, so pushes only succeed against the real
GitHub.

## Rotating secrets

Secrets are read from the environment, so rotation is: update the value and
recreate the container.

```bash
# edit bridge.env with the new token/key, then:
docker rm -f obsidian-bridge
# ...and run the start command again (README setup, "Start the bridge")
```

The auth token is read fresh on every `ob` call and is **not** embedded in the
persisted `/config` sync config, so `sync-setup` is skipped on restart (no
re-setup). Rotating the **deploy key**: replace it, add the new public key to
GitHub, remove the old one, recreate. Secrets are never logged.

## Getting the token with Node.js

If you'd rather not use the Docker one-liner from the README, install the CLI
directly:

```bash
npm install -g obsidian-headless
ob login            # interactive: email, password, 2FA if enabled
ob sync-list-remote # note your vault's exact name (or id)
```

`ob login` writes the token to a file whose location is **platform-specific**
(verified from the CLI source):

| Platform            | Token file |
|---------------------|-----------|
| **Linux**           | `${XDG_CONFIG_HOME:-~/.config}/obsidian-headless/auth_token` |
| **macOS / Windows** | `~/.obsidian-headless/auth_token` |

Copy that file's contents into `OBSIDIAN_AUTH_TOKEN` — the container reads the
token from the env var (the CLI checks the env var before any token file).

## Container images

Multi-arch images (`linux/amd64`, `linux/arm64`) are published to **GitHub
Container Registry** whenever a semver tag is pushed, by
[`.github/workflows/release.yml`](../.github/workflows/release.yml). The same
workflow first creates the GitHub Release (with auto-generated notes) from that
tag — pushing the tag is the only step:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

Image reference:

```
ghcr.io/puradox/obsidian-sync-git
```

Image tags from a semver tag `v1.2.3`: `1.2.3` / `1.2` / `1`, plus
`latest` (newest non-prerelease) and `sha-<short>`. A prerelease tag
(`v1.2.3-rc.1`) marks the Release as a prerelease and skips `latest`.

```bash
docker pull ghcr.io/puradox/obsidian-sync-git:latest      # or :1.2.3 to pin
```

- **The first tag** creates the GHCR package as **private**. To allow
  unauthenticated `docker pull`, make it public in the package's GitHub
  settings (or `docker login ghcr.io` with a PAT that has `read:packages`).
- Each image carries SLSA build provenance + an SBOM (the extra
  `unknown/unknown` entries in the package UI are those attestations).
- A [CI workflow](../.github/workflows/ci.yml) shellchecks the scripts and
  builds the image on every PR/push to `main`, catching a broken build before
  a release.

## Verification

```bash
docker ps                                                  # health column
docker logs -f obsidian-bridge                             # watch cycles; look for "cycle complete"
docker exec obsidian-bridge ob sync-status --path /vault   # configured vault/path (no network); use /vault/<subdir> if VAULT_SUBDIR is set
docker exec obsidian-bridge git -C /vault log --oneline -n 20
docker exec obsidian-bridge ob sync-list-remote            # sanity-check auth / VAULT_NAME
```

The healthcheck reports **healthy** while a cycle has succeeded within the
staleness threshold — `HEALTH_STALE_SECONDS` if set, else 2× the interval for a
`*/N * * * *` schedule, else 1800s. **For a non-`*/N` schedule (hourly, daily,
comma-lists), set `HEALTH_STALE_SECONDS`** to ~2× your interval, or the fixed
1800s fallback will report false-unhealthy.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Container exits at startup with *"vault '…' not found"* | `VAULT_NAME` wrong, or the token belongs to a different account. Run `ob sync-list-remote` and use the exact name or id. |
| Startup error *"appears to be end-to-end encrypted"* | Set `OBSIDIAN_VAULT_PASSWORD` to the vault's E2EE password. |
| Startup error *"the provided OBSIDIAN_VAULT_PASSWORD was rejected"* | Wrong E2EE password. |
| Startup error *"No SSH deploy key provided"* | Set `GIT_DEPLOY_KEY` (contents) or `GIT_DEPLOY_KEY_FILE` (mounted path). |
| `Permission denied (publickey)` on push | Deploy key not added to the repo, lacks **write** access, or has a passphrase. |
| `dubious ownership in repository` | Volume owned by a different uid; `chown` the bind mount to 1000:1000 (or rebuild with matching UID/GID). The entrypoint also marks the repo as a safe directory. |
| Repeated `ALERT: rebase conflict` every tick | A merged skill PR conflicts with a vault edit. Rebase/close that PR upstream (see [Conflict handling](#conflict-handling)). |
| Healthcheck unhealthy | No cycle succeeded within the threshold — inspect `docker logs`. |

## How it was built (design-to-reality notes)

Designed against the **actual** `obsidian-headless@0.0.12` behavior, verified
by reading the CLI source, not against assumptions:

- `OBSIDIAN_AUTH_TOKEN` (env) short-circuits the token file entirely.
- On Linux the state dir is `$XDG_CONFIG_HOME/obsidian-headless`
  (`~/.config/obsidian-headless`), **not** `~/.obsidian-headless`. `state.db`,
  `sync.log`, and the local sync config all live there → in `/config`, never in
  the vault.
- `sync-list-remote` prints only `id "name" (region)` — no encryption field —
  so E2EE is detected by attempting `sync-setup` (which errors clearly when a
  password is needed) rather than by parsing list output.
- `sync-setup` accepts `--password` non-interactively; a managed vault ignores
  it, an E2EE vault requires it. Exit codes: `3` vault-not-found, `2` no/bad
  password, `1` ambiguous name.
- `ob sync` (one-shot) exit codes: `0` success, `1` network / lock / engine
  error, `2` encryption key missing, `3` not configured. There is no distinct
  "conflict" exit — Obsidian Sync resolves its own file conflicts per the
  vault's conflict strategy; git-level conflicts are handled separately in
  step 3.
- `ob sync` self-serializes with a self-healing lock at
  `.obsidian/.sync.lock` inside the vault directory (i.e. under `VAULT_SUBDIR`
  when set; stale after 5s); our outer whole-cycle `flock` lives on a
  container-local path (`/tmp`), not on a mounted volume.
- On Linux the `btime` native addon isn't used, so `node:22-slim` needs no
  extra runtime libs for it.

## Files

```
Dockerfile                  node:22-slim + git + obsidian-headless + supercronic; HEALTHCHECK baked in
.env.example                env-file template (docker run --env-file)
github_known_hosts          pinned github.com Ed25519 host key
docs/REFERENCE.md           this file
.github/workflows/          release.yml (create Release + build+push to GHCR on tag) + ci.yml (lint+build)
scripts/entrypoint.sh       resolve config, ssh/git/sync setup, launch supercronic
scripts/bridge.sh           one bridge cycle (flock-guarded)
scripts/commit-message.sh   AI (or fallback) commit message
scripts/healthcheck.sh      last-success staleness check
scripts/vault.gitignore     .gitignore installed into the vault
```
