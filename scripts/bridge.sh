#!/usr/bin/env bash
# One full Obsidian Sync <-> git bridge cycle.
#
# The ENTIRE cycle runs under a non-blocking flock on a container-local lockfile
# (NOT on the /config volume — advisory locks can be unreliable on NFS/CIFS), so
# a slow cycle can never overlap the next scheduled tick (they just skip).
#
# Policy: the vault working tree is authoritative ("vault wins"). Skill/automation
# changes only ever arrive as merged PRs on origin/main. We NEVER auto-resolve a
# conflict — on a rebase conflict we abort, leave the repo clean, and alert; the
# stale skill PR must be rebased/closed upstream.
#
# Exit code of THIS script (surfaced by supercronic in `docker logs`):
#   0  cycle completed (or a harmless overlap skip)
#   1  recoverable failure (network / sync engine) — will retry next tick
#   2  rebase conflict — vault-wins alert; needs upstream action
set -uo pipefail

REPO_DIR="${REPO_DIR:-/vault}"          # git repo working tree (all git commands)
VAULT_DIR="${VAULT_DIR:-$REPO_DIR}"     # ob sync target; the repo root or VAULT_SUBDIR within it
SUCCESS_MARKER="${SUCCESS_MARKER:-/config/.last-success}"
LOCKFILE="${BRIDGE_LOCKFILE:-/tmp/obsidian-bridge.lock}"

ts()       { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()      { printf '[bridge %s] %s\n'          "$(ts)" "$*"; }
err()      { printf '[bridge %s] !! %s\n'       "$(ts)" "$*" >&2; }
alertlog() { printf '[bridge %s] !!!! ALERT: %s\n' "$(ts)" "$*" >&2; }

# ---------------------------------------------------------------------------
# Serialize cycles: acquire an exclusive, non-blocking lock. If a previous
# cycle still holds it, skip this tick (not an error).
# ---------------------------------------------------------------------------
exec 9>"$LOCKFILE" || { err "cannot open lockfile $LOCKFILE"; exit 1; }
if ! flock -n 9; then
  log "previous cycle still running; skipping this tick"
  exit 0
fi

cd "$REPO_DIR" || { err "repo dir $REPO_DIR is missing"; exit 1; }

remote_main_present() { git rev-parse --verify --quiet origin/main >/dev/null 2>&1; }
head_present()        { git rev-parse --verify --quiet HEAD        >/dev/null 2>&1; }
rebase_in_progress()  { [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; }

mark_success() {
  if ! ts > "$SUCCESS_MARKER"; then
    err "cycle succeeded but writing $SUCCESS_MARKER failed (volume permissions?) — the healthcheck will go stale"
    return 1
  fi
  log "cycle complete"
}

# vault-wins: abort any in-progress rebase, restoring the working tree to our
# own (vault) commit, clean. We never `reset --hard` — that would discard the
# vault commit we are trying to protect. Fails (non-zero) if rebase state
# survives the abort, so callers never claim a clean repo that isn't.
abort_rebase_clean() {
  if rebase_in_progress; then
    git rebase --abort >/dev/null 2>&1 || true
  fi
  if rebase_in_progress; then
    err "git rebase --abort FAILED — the repo may be left mid-rebase; manual cleanup needed in $REPO_DIR"
    return 1
  fi
}

# Fetch origin/main. $1 labels log messages. Network failure -> return 1 (retry
# next tick). Fetching only main skips every other remote branch (PR branches),
# which this script never reads — but that refspec also fails when the remote
# simply has no main yet (pre-first-push), so disambiguate before failing.
fetch_main() {
  local ctx="$1" heads
  git fetch --prune origin main >/dev/null 2>&1 && return 0
  if heads="$(git ls-remote --heads origin main 2>/dev/null)"; then
    [ -z "$heads" ] && return 0   # empty remote: nothing to fetch; push creates main
    err "git fetch failed${ctx:+ on $ctx} although origin has a main branch — deferring to next tick"
  else
    err "git fetch failed (network?)${ctx:+ on $ctx} — deferring to next tick"
  fi
  return 1
}

# Rebase onto origin/main, distinguishing a real content conflict (alert,
# return 2 — vault-wins, needs upstream action) from any other rebase failure
# (return 1 — retry next tick). $1 labels log messages.
rebase_onto_main() {
  local ctx="$1"
  remote_main_present || return 0
  git rebase origin/main && return 0
  if [ -n "$(git ls-files -u)" ] || rebase_in_progress; then
    if abort_rebase_clean; then
      alertlog "rebase conflict${ctx:+ on $ctx} pulling origin/main. vault-wins: rebase aborted, repo left clean, skill changes NOT applied and NOT pushed. A merged skill PR that conflicts with a vault edit must be rebased onto the current vault and re-merged (or closed) upstream. On a FIRST cycle this instead means main's existing history doesn't match the vault — see 'The first sync' in the README."
    else
      alertlog "rebase conflict${ctx:+ on $ctx} AND the abort failed — repo may be left mid-rebase; run 'git rebase --abort' in the vault volume."
    fi
    return 2
  fi
  err "git rebase origin/main failed${ctx:+ on $ctx} for a non-conflict reason — deferring to next tick"
  return 1
}

# Run one one-shot `ob sync`. stdin from /dev/null so the CLI can never block on
# an interactive prompt. Returns the CLI's exit code.
ob_sync() {
  local phase="$1" rc
  log "ob sync ($phase)"
  ob sync --path "$VAULT_DIR" </dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      1) err "ob sync ($phase) failed (exit 1): network error / another sync running / sync-engine error" ;;
      2) err "ob sync ($phase) failed (exit 2): encryption key missing — re-run sync-setup" ;;
      3) err "ob sync ($phase) failed (exit 3): no sync configuration for $VAULT_DIR" ;;
      *) err "ob sync ($phase) failed (exit $rc)" ;;
    esac
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Recover from a previous cycle killed mid-operation (docker stop, power loss).
# The flock guarantees no other git process runs against this repo, so any
# leftover rebase state or index.lock here is stale by definition.
# ---------------------------------------------------------------------------
if rebase_in_progress; then
  log "recovering: aborting a rebase left by an interrupted cycle"
  abort_rebase_clean || exit 1
fi
if [ -f .git/index.lock ]; then
  log "recovering: removing a stale .git/index.lock left by an interrupted cycle"
  rm -f .git/index.lock
fi

# ================================ cycle ====================================

# (a) Pull device changes down from Obsidian Sync into the working tree.
ob_sync "device pull" || exit 1

# (b) Commit local vault changes, if any.
if [ -n "$(git status --porcelain)" ]; then
  if ! git add -A; then
    err "git add failed"
    exit 1
  fi
  msg="$(commit-message.sh 2>/dev/null || true)"
  [ -n "$msg" ] || msg="vault auto-commit ($(ts))"
  if ! git commit -q -m "$msg"; then
    err "git commit failed"
    exit 1
  fi
  log "committed vault changes: ${msg%%$'\n'*}"
else
  log "no local vault changes to commit"
fi

# (c) Bring in merged skill PRs (== git pull --rebase origin main), with the
#     network step (fetch) split from the merge step (rebase) so a network
#     error (retry next tick) is never mistaken for a real conflict (alert).
fetch_main "" || exit 1

if ! head_present; then
  # Brand-new repo and an empty vault: nothing was committed in (b).
  if remote_main_present; then
    # Bootstrap: adopt the seeded remote content; step (e) syncs it to devices.
    log "local repo is empty; bootstrapping the vault from origin/main"
    if ! git reset --hard origin/main; then
      err "bootstrap from origin/main failed — deferring to next tick"
      exit 1
    fi
  else
    # Nothing local, nothing remote — a successful (if empty) cycle.
    log "empty vault and empty remote; nothing to sync yet"
    mark_success || exit 1
    exit 0
  fi
fi

rebase_onto_main "" || exit "$?"

# (d) Publish to main — skipped when origin/main already points at HEAD (the
#     common idle cycle; saves an SSH round trip). If the push is rejected (a
#     merge landed between our fetch and our push), fetch + rebase once and
#     retry; otherwise defer.
if [ "$(git rev-parse HEAD)" = "$(git rev-parse --verify --quiet origin/main)" ]; then
  log "nothing to push (origin/main is up to date)"
else
  if ! git push origin HEAD:main; then
    log "push rejected (a merge may have raced us) — fetching and retrying once"
    fetch_main "push-retry" || exit 1
    rebase_onto_main "push-retry" || exit "$?"
    if ! git push origin HEAD:main; then
      err "push still failing after retry — deferring to next tick. If this repeats every cycle, check that the deploy key has WRITE access and that no branch-protection rule blocks direct pushes to main."
      exit 1
    fi
  fi
  log "pushed to origin/main"
fi

# (e) Propagate merged skill changes back out to devices.
ob_sync "device push" || exit 1

# ------------------------------- success -----------------------------------
mark_success || exit 1
