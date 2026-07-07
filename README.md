# Obsidian Sync ⇄ GitHub bridge

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
  [Docker](https://docs.docker.com/get-started/get-docker/)
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
**token** for step 4. (If Docker says the pull was *denied*, the image package
may still be private — see
[Container images](docs/REFERENCE.md#container-images).)

### 3. Create a deploy key

This key lets the bridge write to your repository — and nothing else:

```bash
ssh-keygen -t ed25519 -N '' -C 'obsidian-bridge' -f ./deploy_key
```

Copy the output of `cat deploy_key.pub` into GitHub → your repository →
**Settings → Deploy keys → Add deploy key**, and tick **Allow write access**.

### 4. Create a settings file

Save this as `bridge.env` in the same folder as the deploy key (no quotes,
even if the vault name has spaces):

```
VAULT_NAME=My Vault
GIT_REMOTE_URL=git@github.com:YOUR-USERNAME/YOUR-REPO.git
OBSIDIAN_AUTH_TOKEN=paste-the-token-from-step-2
```

Then run `chmod 600 bridge.env` so only you can read it.

> Vault end-to-end encrypted? Add a line
> `OBSIDIAN_VAULT_PASSWORD=your-encryption-password`. Not sure? Skip it — the
> bridge will tell you at startup if it's needed.

### 5. Start the bridge

```bash
docker run -d --name obsidian-bridge \
  --restart unless-stopped \
  --env-file bridge.env \
  -e GIT_DEPLOY_KEY="$(cat deploy_key)" \
  -v obsidian_vault:/vault \
  -v obsidian_config:/config \
  ghcr.io/puradox/obsidian-sync-git:latest
```

It runs in the background, restarts after reboots, and keeps the vault in
Docker volumes so nothing is lost across updates.

### 6. Check that it's working

```bash
docker logs -f obsidian-bridge
```

Within a minute or two you should see **`cycle complete`** (press `Ctrl+C` to
stop watching). Open your GitHub repository — your notes are there.

**Done.** It now syncs on its own every 15 minutes. Something wrong? See
[Troubleshooting](docs/REFERENCE.md#troubleshooting).

## Good to know

- **One rule:** only the bridge may write to its `/vault` volume. Make changes
  in Obsidian, or on GitHub via pull requests — nowhere else.
- **Conflicts are safe.** If a merged pull request clashes with a note you
  edited, your vault wins, nothing is lost, and the logs alert you until the
  pull request is fixed. Details:
  [Conflict handling](docs/REFERENCE.md#conflict-handling).
- **Updating:** `docker pull ghcr.io/puradox/obsidian-sync-git:latest`, then
  `docker rm -f obsidian-bridge`, then run the step 5 command again.

## More options

Everything else lives in the **[reference guide](docs/REFERENCE.md)**:

- [AI-written commit messages](docs/REFERENCE.md#ai-commit-messages) (Groq,
  Gemini, Ollama, Anthropic, …)
- [Change the sync schedule](docs/REFERENCE.md#changing-the-sync-schedule)
- [Keep a Quartz site or Claude skills in the same repo, outside the vault](docs/REFERENCE.md#keeping-the-vault-in-a-subdirectory-of-the-repo)
- [Docker Compose](docs/REFERENCE.md#docker-compose)
- [All settings](docs/REFERENCE.md#configuration-reference) ·
  [Security notes](docs/REFERENCE.md#security-secrets-as-environment-variables) ·
  [How a sync cycle works](docs/REFERENCE.md#how-a-sync-cycle-works) ·
  [Troubleshooting](docs/REFERENCE.md#troubleshooting)
