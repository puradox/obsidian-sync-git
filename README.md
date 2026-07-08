<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/wordmark-dark.svg">
    <img src="assets/wordmark.svg" alt="obsidian-sync-git — every note, every version" width="520">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/puradox/obsidian-sync-git/actions/workflows/ci.yml"><img src="https://github.com/puradox/obsidian-sync-git/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/puradox/obsidian-sync-git/releases/latest"><img src="https://img.shields.io/github/v/release/puradox/obsidian-sync-git?label=release" alt="Latest release"></a>
  <a href="https://github.com/puradox/obsidian-sync-git/pkgs/container/obsidian-sync-git"><img src="https://img.shields.io/badge/ghcr.io-obsidian--sync--git-2496ED?logo=docker&logoColor=white" alt="Container image on GHCR"></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue" alt="License: MIT OR Apache-2.0"></a>
</p>

**Automatically keep a full, versioned copy of your Obsidian vault in a GitHub
repository.**

```
 your devices  ⇄  Obsidian Sync  ⇄  [ this bridge ]  ⇄  GitHub
```

A small Docker container checks [Obsidian Sync](https://obsidian.md/sync) every
15 minutes, commits whatever changed to GitHub, and sends anything merged on
GitHub back out to your devices.

- **Backup and history** — every version of every note, browsable on GitHub.
- **Safe automation** — tools like Claude Code can propose note edits as pull
  requests; nothing reaches your vault until you merge.

No git knowledge needed. Setup is about 15 minutes of copy-paste.

## What you'll need

- A computer that stays on (home server, NAS, Raspberry Pi, …) with
  [Docker](https://docs.docker.com/get-started/get-docker/) (Docker Compose is
  included)
- An Obsidian account with a [Sync](https://obsidian.md/sync) subscription
- A GitHub account

## Setup

### 1. Create an empty GitHub repository

Private is recommended — these are your notes. **Leave it completely empty**
(no README, no .gitignore, no license) or the first sync will fail. Note its
SSH address: `git@github.com:YOUR-USERNAME/YOUR-REPO.git`.

### 2. Get your Obsidian token

The bridge signs in with a token instead of your password. This one-off
command logs in and prints it — nothing to install:

```bash
docker run -it --rm --entrypoint bash ghcr.io/puradox/obsidian-sync-git:latest \
  -c 'ob login && ob sync-list-remote && cat "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless/auth_token" && echo'
```

Enter your Obsidian email, password, and 2FA code if you use one. It prints
your vault names and your token — copy the **exact vault name** and the
**token** for step 4. (If Docker says the pull was *denied*, see
[Troubleshooting](#troubleshooting).)

### 3. Create a deploy key

This key lets the bridge write to your repository — and nothing else. Make a
folder for the bridge and create the key inside it:

```bash
mkdir obsidian-bridge && cd obsidian-bridge
ssh-keygen -t ed25519 -N '' -C 'obsidian-bridge' -f ./deploy_key
```

Copy the output of `cat deploy_key.pub` into GitHub → your repository →
**Settings → Deploy keys → Add deploy key**, and tick **Allow write access**.

### 4. Create the Compose file

Save this as `docker-compose.yml` in the same folder, and fill in the three
values at the top. The optional settings are listed below them, commented out —
uncomment the ones you want and delete the rest.

```yaml
services:
  obsidian-bridge:
    image: ghcr.io/puradox/obsidian-sync-git:latest
    restart: unless-stopped
    volumes:
      - ./deploy_key:/keys/deploy_key:ro
      - vault:/vault
      - config:/config
    environment:
      # ---- fill in these three ----
      VAULT_NAME: "My Vault"
      GIT_REMOTE_URL: "git@github.com:YOUR-USERNAME/YOUR-REPO.git"
      OBSIDIAN_AUTH_TOKEN: "paste-the-token-from-step-2"

      # Where the deploy key is mounted (matches the volumes line above).
      GIT_DEPLOY_KEY_FILE: "/keys/deploy_key"

      # ---- optional: uncomment what you need, delete the rest ----
      # Vault encryption password — only for end-to-end encrypted vaults.
      # OBSIDIAN_VAULT_PASSWORD: "your-encryption-password"

      # How often to sync, in cron syntax (https://crontab.guru).
      # The default means every 15 minutes.
      # CRON_SCHEDULE: "*/15 * * * *"

      # Name and email shown on the commits.
      # GIT_AUTHOR_NAME: "Obsidian Bridge"
      # GIT_AUTHOR_EMAIL: "obsidian-bridge@localhost"

      # Keep the vault in a subfolder of the repository — see
      # "Keeping the vault in a subfolder of the repo" in the README.
      # VAULT_SUBDIR: "vault"

      # AI commit messages, option A: any OpenAI-compatible provider
      # (Groq, Gemini, Ollama, …) — see "AI commit messages" in the README.
      # LLM_API_BASE: "https://api.groq.com/openai/v1"
      # LLM_MODEL: "llama-3.1-8b-instant"
      # LLM_API_KEY: "your-api-key"
      # LLM_MAX_TOKENS: "1024"

      # AI commit messages, option B: Anthropic (used only if option A is unset).
      # ANTHROPIC_API_KEY: "your-api-key"
      # ANTHROPIC_MODEL: "claude-haiku-4-5"

      # Seconds without a successful sync before Docker reports "unhealthy".
      # Set to ~2x your interval if CRON_SCHEDULE isn't every-N-minutes.
      # HEALTH_STALE_SECONDS: "1800"

      # Sync once immediately when the container starts.
      # RUN_ON_START: "true"

      # Only if your vault uses a non-default config folder.
      # OBSIDIAN_CONFIG_DIR: ".obsidian"

      # Device name shown in Obsidian Sync's version history.
      # OBSIDIAN_DEVICE_NAME: "git-bridge"

volumes:
  vault:
  config:
```

> Vault end-to-end encrypted? Uncomment `OBSIDIAN_VAULT_PASSWORD`. Not sure?
> Skip it — the bridge will tell you at startup if it's needed.

This file now contains your token, so keep it private and don't commit it to
version control. To keep secrets out of the file entirely, see
[Security: Docker secrets](#security-docker-secrets).

### 5. Start the bridge

```bash
docker compose up -d
```

It runs in the background, restarts after reboots, and keeps your vault in
Docker volumes so nothing is lost across updates.

### 6. Check that it's working

```bash
docker compose logs -f
```

Within a minute or two you should see **`cycle complete`** (press `Ctrl+C` to
stop watching). Open your GitHub repository — your notes are there.

**Done.** It now syncs on its own every 15 minutes. Something wrong? See
[Troubleshooting](#troubleshooting).

## Good to know

- **One rule:** only the bridge may write to its `vault` volume. Make changes
  in Obsidian, or on GitHub via pull requests — nowhere else.
- **Conflicts are safe.** If a merged pull request clashes with a note you
  edited, your vault wins, nothing is lost, and the logs alert you until the
  pull request is fixed. Details: [How syncing works](#how-syncing-works).
- **Changing a setting:** edit `docker-compose.yml`, then run
  `docker compose up -d` again.
- **Updating:** `docker compose pull && docker compose up -d`.

## All settings

Everything is configured in `docker-compose.yml` (step 4).

| Setting | Required | Default | What it does |
|---|---|---|---|
| `VAULT_NAME` | ✅ | — | Your vault's exact name from step 2. Fixed once the bridge has run. |
| `GIT_REMOTE_URL` | ✅ | — | Your repository's SSH address: `git@github.com:owner/repo.git`. |
| `OBSIDIAN_AUTH_TOKEN` | ✅ | — | The Obsidian token from step 2. |
| `GIT_DEPLOY_KEY_FILE` | ✅ | — | Path of the mounted deploy key (`/keys/deploy_key` in the example). |
| `OBSIDIAN_VAULT_PASSWORD` | E2EE vaults only | — | The vault's encryption password. Ignored for normal vaults. |
| `CRON_SCHEDULE` | | `*/15 * * * *` | How often to sync, in [cron syntax](https://crontab.guru/) — the default means every 15 minutes. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | | `Obsidian Bridge` / `obsidian-bridge@localhost` | Name and email shown on the commits. |
| `VAULT_SUBDIR` | | — (vault = repo root) | Keep the vault in a subfolder of the repository ([details](#keeping-the-vault-in-a-subfolder-of-the-repo)). Fixed once the bridge has run. |
| `LLM_API_BASE` / `LLM_MODEL` / `LLM_API_KEY` | | — | AI commit messages via an OpenAI-compatible provider ([details](#ai-commit-messages)). |
| `LLM_MAX_TOKENS` | | `1024` | Response limit for that provider. |
| `ANTHROPIC_API_KEY` | | — | AI commit messages via Anthropic instead ([details](#ai-commit-messages)). |
| `ANTHROPIC_MODEL` | | `claude-haiku-4-5` | Model for the Anthropic option. |
| `HEALTH_STALE_SECONDS` | | 2× the sync interval | Seconds without a successful sync before Docker reports `unhealthy`. Set it (≈2× your interval) if `CRON_SCHEDULE` isn't every-N-minutes. |
| `RUN_ON_START` | | `true` | Sync once immediately when the container starts. |
| `OBSIDIAN_CONFIG_DIR` | | `.obsidian` | Only if your vault uses a different config folder. |
| `OBSIDIAN_DEVICE_NAME` | | — | Device name shown in Obsidian Sync's version history. |

The secret settings — `OBSIDIAN_AUTH_TOKEN`, `OBSIDIAN_VAULT_PASSWORD`,
`LLM_API_KEY`, `ANTHROPIC_API_KEY` — each also accept a `_FILE` variant that
reads the value from a file instead: see
[Security: Docker secrets](#security-docker-secrets). (`GIT_DEPLOY_KEY` with
the key's *contents* also exists, but mounting the file is safer.)

### Volumes

The bridge keeps its data in two named Docker volumes, so nothing is lost when
you update or recreate the container:

| Volume | Holds |
|---|---|
| `vault` | Your notes, as a git repository. Only the bridge writes here. |
| `config` | The bridge's Obsidian login and sync state. |

## Security: Docker secrets

The compose file from step 4 holds your secrets in plain text. On a machine
only you use, that's acceptable — but anything that can talk to Docker can
read environment variables with `docker inspect`, and a compose file full of
secrets is easy to leak by accident.

Docker secrets keep the values in separate files, out of the compose file and
out of `docker inspect`. Every secret setting accepts a `_FILE` variant that
reads its value from a file — point those at `/run/secrets/…`:

```yaml
services:
  obsidian-bridge:
    image: ghcr.io/puradox/obsidian-sync-git:latest
    restart: unless-stopped
    environment:
      VAULT_NAME: "My Vault"
      GIT_REMOTE_URL: "git@github.com:YOUR-USERNAME/YOUR-REPO.git"
      OBSIDIAN_AUTH_TOKEN_FILE: "/run/secrets/obsidian_auth_token"
      GIT_DEPLOY_KEY_FILE: "/run/secrets/deploy_key"
    secrets:
      - obsidian_auth_token
      - deploy_key
    volumes:
      - vault:/vault
      - config:/config

secrets:
  obsidian_auth_token:
    file: ./obsidian_auth_token.txt   # a file containing just the token
  deploy_key:
    file: ./deploy_key

volumes:
  vault:
  config:
```

The deploy key becomes a secret too, replacing the `./deploy_key:/keys/…`
mount from step 4. The same pattern works for `OBSIDIAN_VAULT_PASSWORD_FILE`,
`LLM_API_KEY_FILE`, and `ANTHROPIC_API_KEY_FILE`.

To rotate a secret, update the file (for the deploy key, also swap the public
key on GitHub), then run `docker compose restart`. Secrets are never logged.

## AI commit messages

Out of the box, each commit is labeled
`vault auto-commit: N files changed (<timestamp>)`. Give the bridge an AI
provider and it writes a short summary of what actually changed instead. In
`docker-compose.yml`, uncomment **one** of the two options:

**Option A — any OpenAI-compatible provider** (`LLM_API_BASE` + `LLM_MODEL` +
`LLM_API_KEY`):

| Provider | `LLM_API_BASE` | `LLM_MODEL` (example) |
|---|---|---|
| Groq | `https://api.groq.com/openai/v1` | `llama-3.1-8b-instant` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3.1-flash-lite` |
| Ollama (local) | `http://host.docker.internal:11434/v1` | `qwen2.5:3b` |

**Option B — Anthropic** (`ANTHROPIC_API_KEY`; used only when option A isn't
set).

Good to know:

- **Privacy:** the diff of your notes is sent to the provider, and free tiers
  commonly use submitted data to improve their models. For fully private
  summaries, run a local Ollama — the diff never leaves your machine.
- **It can never break a sync.** If the provider is down, slow, or
  misconfigured, the bridge just falls back to the plain label.
- `LLM_API_BASE` must start with `http://` or `https://`.

## Keeping the vault in a subfolder of the repo

By default your vault **is** the repository: every file in it syncs to your
devices. If you want the repository to also hold things that should *not*
show up in Obsidian — a [Quartz](https://quartz.jzhao.xyz/) site that
publishes the vault, Claude Code skills, build scripts — set `VAULT_SUBDIR`:

```yaml
      VAULT_SUBDIR: "vault"
```

giving a layout like:

```
your-repo/
├── vault/            ← synced with your Obsidian devices
├── quartz/           ← on GitHub, invisible to Obsidian
├── .claude/skills/   ← on GitHub, invisible to Obsidian
└── README.md
```

- Only files inside `vault/` reach your devices; the bridge still commits and
  pushes the whole repository.
- Work on the other folders in a separate clone of the repository — never
  inside the bridge's volume — and merge changes through GitHub.
- **Decide up front:** like `VAULT_NAME`, this can't be changed once the
  bridge has run — you'd have to start over with fresh volumes.

## Protecting `main` on GitHub

If automation (or other people) opens pull requests against your vault, enable
branch protection on `main` with **"Require branches to be up to date before
merging."** It forces every pull request to be updated with your latest notes
*before* it can merge, so conflicts surface on GitHub — where you can see and
fix them — instead of inside the bridge afterwards.

> ⚠️ Don't enable **"Require a pull request before merging"** or any other
> rule that blocks direct pushes to `main` — the bridge pushes to `main`
> directly, so every sync would be rejected. If you need that rule, use a
> repository *ruleset* instead and add the bridge's deploy key to its bypass
> list.

## How syncing works

Every 15 minutes (or your `CRON_SCHEDULE`) the bridge runs one cycle:

1. Pull note changes from your devices (Obsidian Sync).
2. Commit them.
3. Pull anything merged on GitHub.
4. Push everything to GitHub.
5. Send the merged changes back out to your devices (Obsidian Sync).

Two rules keep this safe:

- **Your vault always wins.** Edits made in Obsidian take priority over
  anything merged on GitHub.
- **Conflicts are never resolved automatically.** If a merged pull request
  clashes with a note you edited, the bridge sets the pull request's changes
  aside, keeps your vault exactly as it is, and prints an `ALERT` in the logs
  (the container also shows as `unhealthy`). Fix it on GitHub — update or
  close the conflicting pull request — and the next cycle carries on by
  itself.

**The first sync.** If the GitHub repository is empty, the first cycle fills
it from your vault. If your *vault* is empty and the repository already has
notes, the bridge adopts the repository and syncs it out to your devices. If
**both** sides already have content, the first sync will conflict — start
with an empty repository.

## Troubleshooting

Watch what's happening with `docker compose logs -f`;
`docker compose ps` shows the health status.

| Symptom | Fix |
|---|---|
| `denied` when pulling the image | The image package may be private. Sign in with `docker login ghcr.io` (username + a GitHub token with `read:packages`). |
| Startup error *"vault '…' not found"* | `VAULT_NAME` doesn't exactly match — use the vault name printed in step 2. |
| Startup error about end-to-end encryption or a rejected password | Set `OBSIDIAN_VAULT_PASSWORD` to your vault's correct encryption password. |
| Startup error *"No SSH deploy key provided"* | The key isn't mounted — check the `./deploy_key:/keys/deploy_key:ro` line and `GIT_DEPLOY_KEY_FILE`. |
| `Permission denied (publickey)` when pushing | The deploy key wasn't added to the repository, or **Allow write access** wasn't ticked. |
| `dubious ownership in repository` | Only with bind mounts: `chown -R 1000:1000` the folder (the bridge runs as user 1000). Named volumes (the default) are unaffected. |
| Repeated `ALERT: rebase conflict` in the logs | A merged pull request clashes with a note edit — see [How syncing works](#how-syncing-works). On the very first sync, it means the repository wasn't empty. |
| Container shows as `unhealthy` | No sync succeeded recently — check `docker compose logs` for the error. |

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or
  <http://opensource.org/licenses/MIT>)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this project by you, as defined in the Apache-2.0 license,
shall be dual licensed as above, without any additional terms or conditions.
