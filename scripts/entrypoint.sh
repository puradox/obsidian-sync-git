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
# ANTHROPIC_MODEL is not consumed here — it flows from compose to commit-message
# (which defaults it), so entrypoint doesn't re-plumb it. SUCCESS_MARKER is a
# Dockerfile ENV (the healthcheck must see it too, and HEALTHCHECK never sees
# entrypoint exports).
CRONTAB_FILE="${CRONTAB_FILE:-/tmp/obsidian-bridge.crontab}"
RUN_ON_START="${RUN_ON_START:-true}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[entrypoint %s] %s\n' "$(ts)" "$*"; }
die() { printf '[entrypoint %s] FATAL: %s\n' "$(ts)" "$*" >&2; exit 1; }

# --- show_path VALUE: VALUE as it may be printed in a "not a readable path"
# message. A path is one short line; anything else (the secret itself pasted
# into the _FILE variant by mistake) must never reach the logs.
show_path() {
  case "$1" in
    *$'\n'*|*"PRIVATE KEY"*) printf '<redacted: looks like key material, not a path>' ;;
    *) printf '%.200s' "$1" ;;
  esac
}

# --- resolve VAR from VAR or VAR_FILE (compose-secret style). Never logs values.
# $(...) strips the trailing newline a secret file usually carries.
resolve_secret() {
  local name="$1" file_var val
  file_var="${name}_FILE"
  if [ -n "${!file_var:-}" ]; then
    [ -r "${!file_var}" ] || die "${file_var} points to unreadable path: $(show_path "${!file_var}")"
    val="$(cat "${!file_var}")"
    export "${name}=${val}"
  fi
}

# --- install_key CONTENTS_VAR FILE_VAR DEST: install a private key given as an
# env var (the contents) or a mounted file (a path — the more secret-safe
# option) at DEST, mode 600. Normalizes to exactly one trailing newline
# (OpenSSH rejects a key whose final newline was stripped, e.g. by a secret
# store). The contents var is dropped from the environment so child processes
# (cron/git/ob) and /proc/<pid>/environ don't carry it; git reaches the key via
# ssh's config. Returns 1 if neither variable is set, 2 if what was given is
# unusable (an unreadable path, or an empty key) — the caller decides whether
# that is fatal. Never logs values.
install_key() {
  local name="$1" file_var="$2" dest="$3" val
  if [ -n "${!name:-}" ]; then
    val="${!name}"
    unset "$name"
  elif [ -n "${!file_var:-}" ]; then
    if [ ! -r "${!file_var}" ] || [ -d "${!file_var}" ]; then
      log "WARNING: $file_var does not point to a readable file: $(show_path "${!file_var}")"
      return 2
    fi
    val="$(cat "${!file_var}")"
    [ -n "$val" ] || { log "WARNING: the SSH key file $file_var points to is empty"; return 2; }
  else
    return 1
  fi
  [ -n "$val" ] || { log "WARNING: the SSH key in $name is empty"; return 2; }
  ( umask 077; printf '%s\n' "${val%$'\n'}" > "$dest" )
  chmod 600 "$dest"
}

setup_ssh() {
  local dest="$HOME/.ssh/id_deploy" rc=0
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  install_key GIT_DEPLOY_KEY GIT_DEPLOY_KEY_FILE "$dest" || rc=$?
  case "$rc" in
    0) ;;
    1) die "No SSH deploy key provided. Set GIT_DEPLOY_KEY (the private key contents) or GIT_DEPLOY_KEY_FILE (a mounted path). It must be passphrase-less and have write access to the repo." ;;
    *) die "The SSH deploy key in GIT_DEPLOY_KEY / GIT_DEPLOY_KEY_FILE is unusable (see above)." ;;
  esac

  cp "$BRIDGE_LIB/github_known_hosts" "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"

  # Identities live in ssh's config, not on the command line: a `-i` would be
  # offered to EVERY host, and GitHub authenticates whichever key it recognises
  # first — so the outer deploy key would win the handshake to a submodule's
  # repo and then be denied. The outer key applies to every host except the
  # per-submodule aliases (bridge-submodule-*), which the Included file maps to
  # their own keys (written by the bridge from .gitmodules each cycle).
  : > "$HOME/.ssh/bridge_submodules.conf"
  chmod 600 "$HOME/.ssh/bridge_submodules.conf"
  {
    printf 'Include %s/.ssh/bridge_submodules.conf\n\n' "$HOME"
    printf 'Host !bridge-submodule-* *\n  IdentityFile %s\n' "$dest"
  } > "$HOME/.ssh/config"
  chmod 600 "$HOME/.ssh/config"

  # Pinned host key (ed25519 only), no passwords, no prompts. Connect/keepalive
  # timeouts so a blackholed connection can't hang a cycle (and its flock) forever.
  export GIT_SSH_COMMAND="ssh -F $HOME/.ssh/config -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o PasswordAuthentication=no -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
  # Also persist it in git config: the bridge reaches the key via the export
  # above, but a `docker exec` shell inherits none of the entrypoint's exports,
  # so `git fetch/push` there would fall back to keyless ssh and be denied.
  # core.sshCommand makes any git in the repo use the deploy key for manual
  # recovery. (The export still wins for the bridge; both point at the same key.)
  git config --global core.sshCommand "$GIT_SSH_COMMAND"
  log "ssh configured (pinned github.com ed25519 host key)"
}

# Per-submodule deploy keys: GIT_SUBMODULE_DEPLOY_KEY_<NAME> (contents) or
# GIT_SUBMODULE_DEPLOY_KEY_FILE_<NAME> (a mounted path), <NAME> being the
# .gitmodules name upper-cased with every non-alphanumeric character replaced
# by "_" (vault/Cove QMS -> VAULT_COVE_QMS; see cmd/bridge/submodules.go). Each
# is installed as ~/.ssh/id_submodule_<NAME>; the bridge routes it to the
# matching submodule when it reads .gitmodules (which may not exist yet on
# first start).
# A key removed from the environment is removed from disk too, so a submodule
# can't keep pushing with a key you revoked. These keys are optional, so one
# that is set but unusable (a typo'd mount, an empty value) is skipped with a
# warning rather than stopping the whole vault from syncing: the bridge then
# treats that submodule as keyless (alerted every cycle, committed locally).
setup_submodule_keys() {
  local var name dest kept=()
  for var in $(compgen -A variable | grep -E '^GIT_SUBMODULE_DEPLOY_KEY(_FILE)?_[A-Z0-9_]+$' || true); do
    # A name that itself starts with FILE_ is ambiguous here; the _FILE_ form
    # wins, matching the README's derivation for the documented setting.
    if [[ "$var" == GIT_SUBMODULE_DEPLOY_KEY_FILE_* ]]; then
      name="${var#GIT_SUBMODULE_DEPLOY_KEY_FILE_}"
    else
      name="${var#GIT_SUBMODULE_DEPLOY_KEY_}"
    fi
    dest="$HOME/.ssh/id_submodule_$name"   # the path cmd/bridge looks for
    case " ${kept[*]:-} " in *" $dest "*) continue ;; esac   # both variants set: installed once
    if ! install_key "GIT_SUBMODULE_DEPLOY_KEY_$name" "GIT_SUBMODULE_DEPLOY_KEY_FILE_$name" "$dest"; then
      log "WARNING: $var is set but unusable — skipping this submodule key; the folder still syncs to your devices and is committed locally, and each cycle will log an ALERT until it is fixed"
      continue
    fi
    kept+=("$dest")
    log "installed submodule deploy key for $name"
  done
  for dest in "$HOME"/.ssh/id_submodule_*; do
    [ -e "$dest" ] || continue
    case " ${kept[*]:-} " in *" $dest "*) ;; *) rm -f "$dest"; log "removed stale submodule key $(basename "$dest")" ;; esac
  done
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
  printf '%s timeout --kill-after=30 %s /usr/local/bin/bridge\n' \
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
setup_submodule_keys
init_git_repo
setup_sync

if [ "$RUN_ON_START" = "true" ]; then
  log "running an initial bridge cycle (RUN_ON_START=true; ${BRIDGE_CYCLE_TIMEOUT}s cap)"
  timeout --kill-after=30 "$BRIDGE_CYCLE_TIMEOUT" /usr/local/bin/bridge \
    || log "initial cycle did not complete cleanly; supercronic will retry on schedule"
fi

write_crontab
log "starting supercronic on schedule: $CRON_SCHEDULE"
exec supercronic -passthrough-logs "$CRONTAB_FILE"
