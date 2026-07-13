#!/usr/bin/env bash
# Bridge entrypoint: resolve secrets, configure ssh/git/sync idempotently, then
# hand off to supercronic. Exits NON-ZERO only on unrecoverable config errors;
# once supercronic is running, an individual failed cycle just logs and retries.
set -euo pipefail

BRIDGE_LIB="${BRIDGE_LIB:-/opt/bridge}"
# The mounted git repo working tree. The vault is at its root, or — with
# VAULT_SUBDIR — in a subdirectory of it; VAULT_DIR is derived in main.
export REPO_DIR="${REPO_DIR:-/vault}"
# obsidian-headless on Linux keeps ALL its state (auth_token, sync/<id>/state.db,
# sync.log) under $XDG_CONFIG_HOME/obsidian-headless. Point that at /config so it
# persists on the config volume and NEVER lands in the vault.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/config}"
export CRON_SCHEDULE="${CRON_SCHEDULE:-*/15 * * * *}"
# ANTHROPIC_MODEL is not consumed here — it flows from compose to commit-message.sh
# (which defaults it), so entrypoint doesn't re-plumb it. SUCCESS_MARKER is a
# Dockerfile ENV (the healthcheck must see it too, and HEALTHCHECK never sees
# entrypoint exports).
CRONTAB_FILE="${CRONTAB_FILE:-/tmp/obsidian-bridge.crontab}"
RUN_ON_START="${RUN_ON_START:-true}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[entrypoint %s] %s\n' "$(ts)" "$*"; }
die() { printf '[entrypoint %s] FATAL: %s\n' "$(ts)" "$*" >&2; exit 1; }

# --- resolve VAR from VAR or VAR_FILE (compose-secret style). Never logs values.
# $(...) strips the trailing newline a secret file usually carries.
resolve_secret() {
  local name="$1" file_var val
  file_var="${name}_FILE"
  if [ -n "${!file_var:-}" ]; then
    [ -r "${!file_var}" ] || die "${file_var} points to unreadable path: ${!file_var}"
    val="$(cat "${!file_var}")"
    export "${name}=${val}"
  fi
}

setup_ssh() {
  local dest="$HOME/.ssh/id_deploy"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # The key may be provided as an env var (GIT_DEPLOY_KEY, the contents) or as a
  # mounted file (GIT_DEPLOY_KEY_FILE, a path — the more secret-safe option).
  if [ -n "${GIT_DEPLOY_KEY:-}" ]; then
    # Normalize to exactly one trailing newline (OpenSSH requires the key to end
    # with a newline). umask keeps the file 600 as it's written.
    ( umask 077; printf '%s\n' "${GIT_DEPLOY_KEY%$'\n'}" > "$dest" )
    # Drop the key from the environment so child processes (cron/git/ob) and
    # /proc/<pid>/environ don't carry it; git reaches it via GIT_SSH_COMMAND.
    unset GIT_DEPLOY_KEY
  elif [ -n "${GIT_DEPLOY_KEY_FILE:-}" ]; then
    [ -r "$GIT_DEPLOY_KEY_FILE" ] || die "GIT_DEPLOY_KEY_FILE points to an unreadable path: $GIT_DEPLOY_KEY_FILE"
    # Same trailing-newline normalization as the env path — OpenSSH rejects a
    # key whose final newline was stripped (e.g. by a secret store).
    ( umask 077; printf '%s\n' "$(cat "$GIT_DEPLOY_KEY_FILE")" > "$dest" )
  else
    die "No SSH deploy key provided. Set GIT_DEPLOY_KEY (the private key contents) or GIT_DEPLOY_KEY_FILE (a mounted path). It must be passphrase-less and have write access to the repo."
  fi
  chmod 600 "$dest"
  [ -s "$dest" ] || die "The SSH deploy key is empty."

  cp "$BRIDGE_LIB/github_known_hosts" "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"

  # Pinned host key (ed25519 only), no passwords, no prompts. Connect/keepalive
  # timeouts so a blackholed connection can't hang a cycle (and its flock) forever.
  export GIT_SSH_COMMAND="ssh -i $dest -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o PasswordAuthentication=no -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
  log "ssh configured (pinned github.com ed25519 host key)"
}

init_git_repo() {
  export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Obsidian Bridge}"
  export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-obsidian-bridge@localhost}"
  export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
  export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

  # The volume may be owned by a different uid than us on first mount.
  git config --global --add safe.directory "$REPO_DIR" || true

  if [ ! -d "$REPO_DIR/.git" ]; then
    log "initializing git repo in $REPO_DIR"
    git -C "$REPO_DIR" init -q -b main
    first_init=true
  else
    first_init=false
  fi
  if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO_DIR" remote add origin "$GIT_REMOTE_URL"
  else
    git -C "$REPO_DIR" remote set-url origin "$GIT_REMOTE_URL"
  fi
  git -C "$REPO_DIR" config user.name  "$GIT_AUTHOR_NAME"
  git -C "$REPO_DIR" config user.email "$GIT_AUTHOR_EMAIL"

  # Seed the vault .gitignore on FIRST init only (reinstalling on every start
  # would resurrect a copy the user deliberately deleted). Prefer the one
  # already tracked on origin/main — installing a different default would hand
  # the very first rebase an add/add conflict on it — and fall back to the
  # bridge default when the remote has none (or isn't reachable yet).
  if [ "$first_init" = true ] && [ ! -f "$VAULT_DIR/.gitignore" ]; then
    local gitignore_ref="origin/main:${VAULT_SUBDIR:+${VAULT_SUBDIR}/}.gitignore"
    if git -C "$REPO_DIR" fetch --prune origin main >/dev/null 2>&1 \
       && git -C "$REPO_DIR" cat-file -e "$gitignore_ref" 2>/dev/null; then
      git -C "$REPO_DIR" cat-file blob "$gitignore_ref" > "$VAULT_DIR/.gitignore"
      log "adopted the vault .gitignore tracked on origin/main"
    else
      cp "$BRIDGE_LIB/vault.gitignore" "$VAULT_DIR/.gitignore"
      log "installed default vault .gitignore"
    fi
  fi
}

setup_sync() {
  # The sync config in /config is keyed by PATH only, so changing VAULT_NAME or
  # VAULT_SUBDIR against existing volumes would silently keep syncing the old
  # setup (or download a full second vault copy into the repo). Record what
  # these volumes were set up for and refuse to drift.
  local statefile="$XDG_CONFIG_HOME/bridge-vault" want current
  want="${VAULT_NAME} -> ${VAULT_DIR}"
  if [ -f "$statefile" ]; then
    current="$(cat "$statefile")"
    [ "$current" = "$want" ] || die "vault configuration changed: these volumes were set up for '${current}' but the config now says '${want}'. Changing VAULT_NAME or VAULT_SUBDIR on existing volumes is not supported — start with fresh vault/config volumes, or restore the previous setting."
  fi

  # sync-status is a purely local check (no network): exit 0 = already
  # configured for this path, exit 3 = not configured. Skipping when already
  # configured makes restarts resilient to transient network/auth blips.
  if ob sync-status --path "$VAULT_DIR" >/dev/null 2>&1; then
    log "obsidian sync already configured for $VAULT_DIR"
    [ -f "$statefile" ] || printf '%s\n' "$want" > "$statefile"
    return 0
  fi

  log "configuring obsidian sync for vault '$VAULT_NAME' -> $VAULT_DIR"
  local args=(sync-setup --vault "$VAULT_NAME" --path "$VAULT_DIR")
  # A managed/standard vault ignores --password (server supplies the key); an
  # E2EE vault requires it. So passing it whenever we have it is always safe.
  [ -n "${OBSIDIAN_VAULT_PASSWORD:-}" ] && args+=(--password "$OBSIDIAN_VAULT_PASSWORD")
  [ -n "${OBSIDIAN_CONFIG_DIR:-}" ]     && args+=(--config-dir "$OBSIDIAN_CONFIG_DIR")
  [ -n "${OBSIDIAN_DEVICE_NAME:-}" ]    && args+=(--device-name "$OBSIDIAN_DEVICE_NAME")

  # stdin from /dev/null so an E2EE password prompt (when unset) EOFs instantly
  # to empty and exits 2, instead of hanging.
  set +e
  ob "${args[@]}" </dev/null
  local rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      2)
        if [ -z "${OBSIDIAN_VAULT_PASSWORD:-}" ]; then
          die "sync-setup failed (exit 2): vault '$VAULT_NAME' appears to be end-to-end encrypted. Set OBSIDIAN_VAULT_PASSWORD(_FILE) to its E2EE password."
        else
          die "sync-setup failed (exit 2): the provided OBSIDIAN_VAULT_PASSWORD was rejected for vault '$VAULT_NAME'."
        fi
        ;;
      3) die "sync-setup failed (exit 3): vault '$VAULT_NAME' not found for this account. Check VAULT_NAME (or use the exact vault id) and confirm OBSIDIAN_AUTH_TOKEN belongs to the right account — run 'ob sync-list-remote'." ;;
      1) die "sync-setup failed (exit 1): ambiguous vault name or an auth error. Run 'ob sync-list-remote' to get the exact vault id and set VAULT_NAME to it." ;;
      *) die "sync-setup failed (exit $rc)." ;;
    esac
  fi
  log "obsidian sync configured"
  printf '%s\n' "$want" > "$statefile"
}

write_crontab() {
  # Cap every scheduled cycle (not just the RUN_ON_START one) so a hung step can
  # never wedge the schedule. --kill-after force-kills a cycle that ignores TERM.
  printf '%s timeout --kill-after=30 %s /usr/local/bin/bridge.sh\n' \
    "$CRON_SCHEDULE" "$BRIDGE_CYCLE_TIMEOUT" > "$CRONTAB_FILE"
}

# =============================== main =====================================

log "resolving secrets"
resolve_secret OBSIDIAN_AUTH_TOKEN
resolve_secret OBSIDIAN_VAULT_PASSWORD
resolve_secret ANTHROPIC_API_KEY
resolve_secret LLM_API_KEY

# Required configuration.
: "${VAULT_NAME:?VAULT_NAME is required (the Obsidian Sync remote vault name or id)}"
: "${GIT_REMOTE_URL:?GIT_REMOTE_URL is required (ssh form, e.g. git@github.com:owner/repo.git)}"
[ -n "${OBSIDIAN_AUTH_TOKEN:-}" ] || die "OBSIDIAN_AUTH_TOKEN(_FILE) is required (see README setup step 2 to mint one)."

# Fail fast on malformed scheduling/health config: a bad crontab line would
# otherwise crash-loop supercronic (after wastefully running the initial
# cycle), and a non-integer threshold would silently disable the healthcheck.
case "$CRON_SCHEDULE" in *$'\n'*) die "CRON_SCHEDULE must be a single line" ;; esac
read -r -a cron_fields <<< "$CRON_SCHEDULE"
[ "${#cron_fields[@]}" -eq 5 ] || die "CRON_SCHEDULE must be a standard 5-field cron expression, got: '$CRON_SCHEDULE'"
case "${HEALTH_STALE_SECONDS:-0}" in
  *[!0-9]*) die "HEALTH_STALE_SECONDS must be an integer number of seconds, got: '$HEALTH_STALE_SECONDS'" ;;
esac

# Bound the sync engine and the cycle. obsidian-headless puts no client-side
# timeout on its sync-server connection, so a stalled sync would otherwise hang a
# cycle forever (and, via the inherited flock fd, orphan-hold its lock). Every
# `ob sync` runs under OB_SYNC_TIMEOUT; every cycle (initial AND scheduled) runs
# under BRIDGE_CYCLE_TIMEOUT as an outer safety net.
export OB_SYNC_TIMEOUT="${OB_SYNC_TIMEOUT:-300}"
case "$OB_SYNC_TIMEOUT" in
  ''|*[!0-9]*) die "OB_SYNC_TIMEOUT must be an integer number of seconds, got: '$OB_SYNC_TIMEOUT'" ;;
esac
# Derived to clear two ob syncs (pull + push) plus git/LLM work; override for very
# large vaults, but keep it comfortably above 2x OB_SYNC_TIMEOUT.
BRIDGE_CYCLE_TIMEOUT="${BRIDGE_CYCLE_TIMEOUT:-$(( OB_SYNC_TIMEOUT * 2 + 300 ))}"
case "$BRIDGE_CYCLE_TIMEOUT" in
  ''|*[!0-9]*) die "BRIDGE_CYCLE_TIMEOUT must be an integer number of seconds, got: '$BRIDGE_CYCLE_TIMEOUT'" ;;
esac
if [[ ! "$CRON_SCHEDULE" =~ ^\*/[0-9]+[[:space:]] ]] && [ -z "${HEALTH_STALE_SECONDS:-}" ]; then
  log "WARNING: CRON_SCHEDULE '$CRON_SCHEDULE' is not '*/N ...', so the healthcheck cannot derive a staleness threshold and falls back to 1800s — set HEALTH_STALE_SECONDS to ~2x your interval to avoid false-unhealthy"
fi

# Optional: keep the vault in a subdirectory of the repo (e.g. VAULT_SUBDIR=vault)
# so support files (a Quartz site, automation skills, ...) can live in git
# without being synced to Obsidian devices. Default: the vault IS the repo root.
VAULT_SUBDIR="${VAULT_SUBDIR:-}"
VAULT_SUBDIR="${VAULT_SUBDIR#/}"; VAULT_SUBDIR="${VAULT_SUBDIR%/}"
case "/$VAULT_SUBDIR/" in
  */../*)   die "VAULT_SUBDIR must be a relative path inside the repo (no '..'): $VAULT_SUBDIR" ;;
  */.git/*) die "VAULT_SUBDIR must not contain a .git component: $VAULT_SUBDIR" ;;
esac
export VAULT_DIR="${REPO_DIR}${VAULT_SUBDIR:+/${VAULT_SUBDIR}}"
mkdir -p "$VAULT_DIR"
# A symlink at the subdir path (e.g. smuggled in via a merged PR) could point
# the vault outside the repo; resolve and verify containment.
real_vault="$(realpath "$VAULT_DIR")" || die "cannot resolve VAULT_DIR: $VAULT_DIR"
real_repo="$(realpath "$REPO_DIR")"   || die "cannot resolve REPO_DIR: $REPO_DIR"
case "${real_vault}/" in
  "${real_repo}"/*) ;;
  *) die "VAULT_DIR resolves outside the repo (symlink?): $VAULT_DIR -> $real_vault" ;;
esac

setup_ssh
init_git_repo
setup_sync

if [ "$RUN_ON_START" = "true" ]; then
  log "running an initial bridge cycle (RUN_ON_START=true; ${BRIDGE_CYCLE_TIMEOUT}s cap)"
  timeout --kill-after=30 "$BRIDGE_CYCLE_TIMEOUT" /usr/local/bin/bridge.sh \
    || log "initial cycle did not complete cleanly; supercronic will retry on schedule"
fi

write_crontab
log "starting supercronic on schedule: $CRON_SCHEDULE"
exec supercronic -passthrough-logs "$CRONTAB_FILE"
