#!/usr/bin/env bash
# One full Obsidian Sync <-> git bridge cycle.
#
# The ENTIRE cycle runs under a non-blocking flock on a container-local lockfile
# (NOT on the /config volume — advisory locks can be unreliable on NFS/CIFS), so
# a slow cycle can never overlap the next scheduled tick (they just skip).
#
# Policy: the vault working tree is authoritative ("vault wins"). Skill/automation
# changes only ever arrive as merged PRs on origin/main. On a rebase conflict we
# resolve IN FAVOUR OF THE VAULT (git rebase -X theirs) so a conflicting skill
# edit can never halt sync: the vault's version of the conflicting lines is kept,
# every non-conflicting skill change still merges in, the result is pushed, and
# we alert so you can re-apply an overridden skill change upstream if you wanted
# it (its version stays in origin/main's history — nothing is lost). Only a
# conflict that even a vault-wins replay can't apply (e.g. modify-vs-delete)
# falls back to abort-and-alert.
#
# Submodules inside the vault (see submodules.sh) get the same contract in their
# own repos: each is committed, fetched, rebased vault-wins and pushed BEFORE the
# outer cycle, so the outer commit can record a gitlink the submodule remote
# already has. The gitlink always follows the submodule's HEAD; an upstream
# pointer bump is integrated into the submodule (fast-forward, else a vault-wins
# rebase with an alert) and the pointer re-recorded.
#
# Exit code of THIS script (surfaced by supercronic in `docker logs`):
#   0  cycle completed (incl. a conflict auto-resolved in favour of the vault)
#   1  recoverable failure (network / sync engine) — will retry next tick
#   2  a conflict that couldn't be auto-resolved even for the vault — upstream action
set -uo pipefail

REPO_DIR="${REPO_DIR:-/vault}"          # git repo working tree (all git commands)
VAULT_DIR="${VAULT_DIR:-$REPO_DIR}"     # ob sync target; the repo root or VAULT_SUBDIR within it
SUCCESS_MARKER="${SUCCESS_MARKER:-/config/.last-success}"
LOCKFILE="${BRIDGE_LOCKFILE:-/tmp/obsidian-bridge.lock}"
BRIDGE_LIB="${BRIDGE_LIB:-/opt/bridge}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=submodules.sh
. "$BRIDGE_LIB/submodules.sh"

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

# Every git helper below acts on the repo in the current directory — the outer
# repo, or a submodule when called from a `( cd "$path" && ... )` subshell.
ref_present()         { git rev-parse --verify --quiet "$1" >/dev/null 2>&1; }
head_present()        { ref_present HEAD; }
git_dir()             { git rev-parse --git-dir 2>/dev/null; }
rebase_in_progress()  { local d; d="$(git_dir)" && { [ -d "$d/rebase-merge" ] || [ -d "$d/rebase-apply" ]; }; }

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
    err "git rebase --abort FAILED — the repo may be left mid-rebase; manual cleanup needed in $PWD"
    return 1
  fi
}

# Recover from a previous cycle killed mid-operation (docker stop, power loss).
# The flock guarantees no other git process runs against this repo, so any
# leftover rebase state or index.lock here is stale by definition. $1 labels
# messages. Runs in the outer repo and inside every submodule.
recover_interrupted() {
  local ctx="$1" d
  d="$(git_dir)" || return 0
  if rebase_in_progress; then
    log "recovering${ctx:+ $ctx}: aborting a rebase left by an interrupted cycle"
    abort_rebase_clean || return 1
  fi
  if [ -f "$d/index.lock" ]; then
    log "recovering${ctx:+ $ctx}: removing a stale index.lock left by an interrupted cycle"
    rm -f "$d/index.lock"
  fi
}

# Fetch origin/$1. $2 labels log messages. Network failure -> return 1 (retry
# next tick). Fetching only that branch skips every other remote branch (PR
# branches), which this script never reads — but that refspec also fails when
# the remote simply has no such branch yet (pre-first-push), so disambiguate
# before failing.
fetch_branch() {
  local branch="$1" ctx="$2" heads
  git fetch --prune origin "$branch" >/dev/null 2>&1 && return 0
  if heads="$(git ls-remote --heads origin "$branch" 2>/dev/null)"; then
    [ -z "$heads" ] && return 0   # empty remote: nothing to fetch; push creates the branch
    err "git fetch failed${ctx:+ on $ctx} although origin has a $branch branch — deferring to next tick"
  else
    err "git fetch failed (network?)${ctx:+ on $ctx} — deferring to next tick"
  fi
  return 1
}

# Commit whatever is in the working tree ("vault wins" starts here). $1 labels
# messages. Returns 1 only on a git failure.
commit_working_tree() {
  local ctx="$1" msg
  if [ -z "$(git status --porcelain)" ]; then
    log "no local ${ctx:-vault} changes to commit"
    return 0
  fi
  if ! git add -A; then
    err "git add failed${ctx:+ in $ctx}"
    return 1
  fi
  # Outer repo: never record a submodule pointer its remote doesn't have yet.
  if [ -z "$ctx" ] && ! unstage_unpushed_gitlinks; then
    err "could not un-stage an unpushed submodule pointer"
    return 1
  fi
  # A dirty submodule (untracked files inside it, or one without a commit yet)
  # shows in status but stages nothing — that's not a commit.
  if git diff --cached --quiet; then
    log "no local ${ctx:-vault} changes to commit"
    return 0
  fi
  msg="$(commit-message 2>/dev/null || true)"
  [ -n "$msg" ] || msg="vault auto-commit ($(ts))"
  if ! git commit -q -m "$msg"; then
    err "git commit failed${ctx:+ in $ctx}"
    return 1
  fi
  log "committed ${ctx:-vault} changes: ${msg%%$'\n'*}"
}

# Merge strategies leave a submodule-pointer (gitlink) conflict unresolved even
# under -X theirs. Resolve every such entry in favour of the commit being
# replayed (stage 3 — the vault's pointer) and continue the rebase; the pointer
# is re-derived from the submodule's HEAD afterwards anyway. Returns 1 if
# nothing was resolved or any non-gitlink conflict remains (a real,
# unresolvable conflict).
resolve_gitlink_conflicts() {
  local entry mode sha stage path resolved=0
  while IFS= read -r -d '' entry; do
    path="${entry#*$'\t'}"
    read -r mode sha stage <<< "${entry%%$'\t'*}"
    [ "$mode" = 160000 ] || return 1
    [ "$stage" = 3 ] || continue
    git update-index --cacheinfo "160000,$sha,$path" || return 1
    resolved=1
  done < <(git ls-files -u -z)
  [ "$resolved" = 1 ]
}

# Integrate upstream ($1, e.g. origin/main) by rebasing our vault commits onto it.
#
# vault-wins & self-healing: a conflict-free rebase keeps every side's changes.
# On a CONFLICT we replay resolving in favour of the vault — `-X theirs` keeps
# the commits being replayed (in a rebase "ours" is upstream and "theirs" is our
# vault commit), so a conflicting skill edit is overridden by your note instead
# of halting the bridge; non-conflicting skill hunks still merge in and the
# skill's overridden version remains in upstream's history. We alert so it's
# visible. Only a conflict that even a vault-wins replay can't apply (e.g.
# modify-vs-delete) aborts and alerts for upstream action.
#
# Returns: 0 integrated (silently, or a conflict auto-resolved for the vault —
# alerted); 1 a non-conflict rebase failure (retry next tick); 2 a conflict that
# can't be auto-resolved even for the vault (abort + alert). $2 labels messages.
rebase_onto() {
  local upstream="$1" ctx="$2" conflicted_files rc
  ref_present "$upstream" || return 0

  # Fast path: a conflict-free rebase integrates both sides untouched.
  git rebase "$upstream" && return 0

  # The rebase failed. With the (default) merge backend a genuine conflict always
  # leaves unmerged index entries; anything else (a rebase that never started, a
  # transient error) is not a conflict — leave the repo clean and retry.
  conflicted_files="$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
  if [ -z "$conflicted_files" ] && ! rebase_in_progress; then
    err "git rebase $upstream failed${ctx:+ on $ctx} for a non-conflict reason — deferring to next tick"
    return 1
  fi

  # A real conflict. Abort the failed attempt, then replay resolving in favour of
  # the vault so sync self-heals instead of stopping.
  if ! abort_rebase_clean; then
    alertlog "rebase conflict${ctx:+ on $ctx} AND the abort failed — repo may be left mid-rebase; run 'git rebase --abort' in $PWD."
    return 2
  fi
  git rebase -X theirs "$upstream"; rc=$?
  if [ "$rc" -ne 0 ] && ! rebase_in_progress; then
    # Never started (index.lock, hook, disk full): nothing was integrated, so
    # this is not a resolved conflict — retry next tick.
    err "git rebase -X theirs $upstream failed${ctx:+ on $ctx} without starting — deferring to next tick"
    return 1
  fi
  # -X theirs cannot resolve submodule-pointer conflicts; do those by hand and
  # continue. Each iteration resolves at least one entry or stops, so the loop
  # is bounded by the number of replayed commits.
  while rebase_in_progress && resolve_gitlink_conflicts; do
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
  done
  if ! rebase_in_progress; then
    alertlog "rebase conflict${ctx:+ on $ctx} pulling $upstream — auto-resolved in favour of the vault (vault wins), so sync continues. A merged upstream change was overridden by your note in: ${conflicted_files:-<unknown>}. The upstream version is still in $upstream's history; re-apply it via a fresh PR if you wanted it. On a FIRST cycle a conflict here instead means upstream's existing history doesn't match the vault — see 'The first sync' in the README."
    return 0
  fi

  # Even a vault-wins replay couldn't apply (e.g. a note edited here but deleted
  # upstream): don't leave a half-done rebase — abort clean and alert.
  if abort_rebase_clean; then
    alertlog "rebase conflict${ctx:+ on $ctx} that could NOT be auto-resolved even in favour of the vault (e.g. a file modified on one side and deleted on the other). Repo left clean, nothing pushed; resolve it upstream. On a FIRST cycle see 'The first sync' in the README."
  else
    alertlog "rebase conflict${ctx:+ on $ctx} AND the abort failed — repo may be left mid-rebase; run 'git rebase --abort' in $PWD."
  fi
  return 2
}

# Publish HEAD to origin/$1 — skipped when the remote branch already points at
# HEAD (the common idle cycle; saves an SSH round trip). If the push is rejected
# (a merge landed between our fetch and our push), fetch + rebase once and
# retry; otherwise defer. $2 labels messages. Returns like rebase_onto.
push_branch() {
  local branch="$1" ctx="$2" rc
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse --verify --quiet "origin/$branch")" ]; then
    log "nothing to push${ctx:+ for $ctx} (origin/$branch is up to date)"
    return 0
  fi
  if ! git push origin "HEAD:$branch"; then
    log "push rejected${ctx:+ for $ctx} (a merge may have raced us) — fetching and retrying once"
    fetch_branch "$branch" "${ctx:+$ctx }push-retry" || return 1
    rebase_onto "origin/$branch" "${ctx:+$ctx }push-retry" || return "$?"
    # The outer repo's pointers may have moved with that rebase.
    [ -z "$ctx" ] && { refresh_submodule_pointers || return "$?"; }
    if ! git push origin "HEAD:$branch"; then
      err "push still failing after retry${ctx:+ for $ctx} — deferring to next tick. If this repeats every cycle, check that the deploy key has WRITE access and that no branch-protection rule blocks direct pushes to $branch."
      return 1
    fi
  fi
  log "pushed${ctx:+ $ctx} to origin/$branch"
}

# Run one one-shot `ob sync`, hard-bounded by a timeout. obsidian-headless has no
# client-side timeout on its sync-server connection: a stalled data socket (seen
# in the wild as a sync.log that stops at "Connecting..." right after "Starting
# sync") hangs the CLI indefinitely. Unbounded, that one hang wedges the whole
# cycle — and, because the flock fd would be inherited by this child, a killed
# cycle could leave an orphaned `ob` still holding the lock. So:
#   - timeout kills a stalled sync (SIGTERM, then SIGKILL after a grace period via
#     --kill-after) so it can never outlive its cycle. 124 (timed out) / 137
#     (SIGKILLed) are treated like any other failure: defer and retry next tick.
#   - 9>&- closes the lock fd for the `ob` child, so even an `ob` that somehow
#     lingers past its parent can never keep the cycle lock held.
# stdin from /dev/null so the CLI can never block on an interactive prompt.
ob_sync() {
  local phase="$1" rc
  log "ob sync ($phase)"
  timeout --kill-after=30 "${OB_SYNC_TIMEOUT:-300}" \
    ob sync --path "$VAULT_DIR" </dev/null 9>&-
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      124) err "ob sync ($phase) timed out after ${OB_SYNC_TIMEOUT:-300}s (stalled sync-server connection?) — killed; deferring to next tick" ;;
      137) err "ob sync ($phase) ignored the timeout and was SIGKILLed after the grace period — deferring to next tick" ;;
      1) err "ob sync ($phase) failed (exit 1): network error / another sync running / sync-engine error" ;;
      2) err "ob sync ($phase) failed (exit 2): encryption key missing — re-run sync-setup" ;;
      3) err "ob sync ($phase) failed (exit 3): no sync configuration for $VAULT_DIR" ;;
      *) err "ob sync ($phase) failed (exit $rc)" ;;
    esac
  fi
  return "$rc"
}

# ============================== submodules =================================
#
# Per-cycle state, indexed like the SUB_* arrays from discover_submodules:
#   SUB_RC[i]  the submodule's result this cycle — submodule_cycle's exit code
#              (0 HEAD is on its remote, 3 committed locally only, 1/2 failed).
#              Only a 0 lets the outer repo record its HEAD as the gitlink;
#              otherwise the gitlink keeps its previous value — the outer push
#              must never reference a commit the submodule remote lacks.
SUB_RC=()

sub_on_remote()   { [ "${SUB_RC[$1]:-1}" = 0 ]; }
# The outer index records PATH as a submodule pointer (mode 160000).
index_is_gitlink() { [ "$(git ls-files -s -- "$1" | cut -d' ' -f1)" = 160000 ]; }

# Turn a live directory (already full of synced notes, or still empty) into a
# submodule checkout WITHOUT touching its files: a git dir under
# .git/modules/<name> like `git submodule` would create, a `.git` file pointing
# at it, the remote wired up — and no HEAD yet. The first commit pass then
# records the directory's content as a root commit that is rebased vault-wins
# onto the remote branch, exactly like the outer repo's first sync (an empty
# directory instead adopts the remote content — see submodule_cycle). We never
# run `git submodule update`: it would check out over files devices may have
# edited since the pointer was recorded. Idempotent: a cycle killed halfway
# through is completed on the next one.
materialize_submodule() {
  local i="$1" name="${SUB_NAME[$1]}" path="${SUB_PATH[$1]}" url="${SUB_URL[$1]}"
  local gitdir="$REPO_DIR/.git/modules/$name"
  if [ ! -e "$path/.git" ]; then
    if [ -d "$gitdir" ]; then
      if git --git-dir="$gitdir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        err "submodule $name: $gitdir has history but $path/.git is missing — refusing to guess; remove one of them"
        return 1
      fi
      rm -rf "$gitdir"   # an init a killed cycle never finished: start over
    fi
    mkdir -p "$path" || return 1
    log "submodule $name: initializing $path as a checkout of $url"
    git init -q -b "${SUB_BRANCH[$i]}" "$path" >/dev/null 2>&1 || { err "submodule $name: git init failed"; return 1; }
    # Move the git dir under .git/modules/<name> with the relative gitdir /
    # core.worktree wiring `git submodule` uses, so it survives the volume
    # being mounted elsewhere.
    git submodule absorbgitdirs -- "$path" >/dev/null 2>&1 || { err "submodule $name: git submodule absorbgitdirs failed"; return 1; }
  fi
  git -C "$path" remote get-url origin >/dev/null 2>&1 || git -C "$path" remote add origin "$url" || return 1
}

# Bring submodule I (the cwd) up to what the outer repo's origin/main points it
# at. The pointer is derived from HEAD, never the other way round:
#   - pointer already in HEAD's history (equal, or an older commit — e.g. our
#     own push hadn't reached the outer repo yet): nothing to do; the submodule
#     never moves backwards;
#   - pointer ahead of HEAD: fast-forward (the tree is clean after the commit);
#   - diverged: rebase our commits onto the pointer, vault wins, with an alert.
# Never `git submodule update` — that would check out over live files.
# $2 labels messages. Returns like rebase_onto.
integrate_submodule_pointer() {
  local i="$1" ctx="$2" path="${SUB_PATH[$1]}" ptr head
  head="$(git rev-parse --verify --quiet HEAD)" || return 0
  ptr="$(git -C "$REPO_DIR" rev-parse --verify --quiet "origin/main:$path" 2>/dev/null)" || return 0
  [ "$ptr" = "$head" ] && return 0
  git merge-base --is-ancestor "$ptr" "$head" 2>/dev/null && return 0
  if ! git cat-file -e "$ptr^{commit}" 2>/dev/null && ! git fetch -q origin "$ptr" 2>/dev/null; then
    alertlog "$ctx: origin/main points it at ${ptr:0:12}, which its remote does not have — keeping the vault's checkout; the pointer is re-recorded from HEAD."
    return 0
  fi
  if [ -n "$(git status --porcelain)" ]; then
    err "$ctx: origin/main moved its pointer but the checkout is dirty — deferring to next tick"
    return 1
  fi
  if git merge-base --is-ancestor "$head" "$ptr"; then
    if git merge -q --ff-only "$ptr" >/dev/null 2>&1; then
      log "$ctx: fast-forwarded to the upstream pointer ${ptr:0:12}"
      return 0
    fi
    err "$ctx: fast-forward to ${ptr:0:12} failed — deferring to next tick"
    return 1
  fi
  alertlog "$ctx: origin/main moved its pointer to ${ptr:0:12} while the vault has its own commits — rebasing the submodule onto it, vault wins on any clash."
  rebase_onto "$ptr" "$ctx (upstream pointer)"
}

# One vault-wins cycle for submodule I, in its own repo: commit -> fetch ->
# follow the outer pointer -> rebase -> push, mirroring the outer cycle's
# (b)-(d) but never failing the outer cycle. Runs in a subshell so cwd and
# helpers stay per-repo. Exit codes:
#   0  HEAD is on the remote (pushed, or already there)
#   3  committed locally only — no deploy key (alerted); HEAD not on the remote
#   1  transient failure     2  unresolvable conflict     (both alerted/logged)
submodule_cycle() (
  local i="$1" name="${SUB_NAME[$1]}" path="${SUB_PATH[$1]}" branch="${SUB_BRANCH[$1]}" ctx
  ctx="submodule $name"
  cd "$path" || { err "$ctx: $path is missing"; exit 1; }
  recover_interrupted "in $ctx" || exit 1
  commit_working_tree "$ctx" || exit 1

  if ! submodule_can_reach_remote "$i"; then
    if submodule_parse_ssh_url "${SUB_URL[$i]}"; then
      alertlog "$ctx: no deploy key — its changes are committed locally and still sync to your devices, but nothing is pushed to ${SUB_URL[$i]}. Set GIT_SUBMODULE_DEPLOY_KEY_FILE_${SUB_ENV[$i]} (or GIT_SUBMODULE_DEPLOY_KEY_${SUB_ENV[$i]}) to a deploy key with write access to that repo and restart."
    else
      alertlog "$ctx: ${SUB_URL[$i]} is not an ssh URL, so no deploy key can reach it — its changes are committed locally and still sync to your devices, but nothing is pushed. Change its url in .gitmodules to git@host:path (or ssh://host/path) and set GIT_SUBMODULE_DEPLOY_KEY_FILE_${SUB_ENV[$i]}."
    fi
    exit 3
  fi
  fetch_branch "$branch" "$ctx" || exit 1
  if ! head_present; then
    if ref_present "origin/$branch"; then
      # Empty folder on the devices, content upstream: adopt it (the tree is
      # empty, so nothing of the vault's can be overwritten). Step (e) then
      # syncs it out to the devices.
      log "$ctx: local checkout is empty; bootstrapping from origin/$branch"
      git reset -q --hard "origin/$branch" || { err "$ctx: bootstrap from origin/$branch failed — deferring to next tick"; exit 1; }
    else
      log "$ctx: empty folder and empty remote; nothing to sync yet"
      exit 0
    fi
  fi
  # Follow the pointer BEFORE pushing, so the push to the submodule's branch
  # stays a fast-forward and the pointed-at commit stays in its history.
  integrate_submodule_pointer "$i" "$ctx" || exit "$?"
  rebase_onto "origin/$branch" "$ctx" || exit "$?"
  push_branch "$branch" "$ctx" || exit "$?"
)

# Pre-pass: run every submodule's own cycle before the outer one.
run_submodule_cycles() {
  local i
  for i in "${!SUB_NAME[@]}"; do
    SUB_RC[i]=3
    # .gitmodules lists it, but the outer index has no gitlink there: its files
    # are plain vault files, and turning them into a submodule would move them
    # out of the outer repo. Leave it alone until the pointer exists upstream.
    if ! index_is_gitlink "${SUB_PATH[$i]}"; then
      alertlog "submodule ${SUB_NAME[$i]}: listed in .gitmodules but ${SUB_PATH[$i]} is not a submodule pointer in the repo — ignoring it. Add it with 'git submodule add' in a clone and merge that."
      continue
    fi
    if ! materialize_submodule "$i"; then SUB_RC[i]=1; continue; fi
    # The submodule's own origin carries the routed (per-key) URL; .gitmodules
    # keeps the canonical one for every other clone.
    git -C "${SUB_PATH[$i]}" remote set-url origin "$(submodule_routed_url "$i")" || { SUB_RC[i]=1; continue; }
    submodule_cycle "$i"; SUB_RC[i]=$?
  done
}

# After `git add -A` in the outer repo: un-stage the gitlink of any submodule
# whose HEAD isn't on its remote, so the outer push never references a commit
# the submodule remote lacks (the pointer just stays where it was). Only real
# gitlinks — a listed path that is still a plain folder must keep its edits.
unstage_unpushed_gitlinks() {
  local i path
  head_present || return 0
  for i in "${!SUB_NAME[@]}"; do
    sub_on_remote "$i" && continue
    path="${SUB_PATH[$i]}"
    if index_is_gitlink "$path" && ref_present "HEAD:$path"; then
      git reset -q -- "$path" >/dev/null 2>&1 || return 1
    fi
  done
}

# Post-pass, after the outer rebase: re-record every gitlink from its
# submodule's HEAD (only for submodules whose HEAD is on their remote) and
# commit the result ("follow submodule HEAD"). Normally the pre-pass already
# integrated origin/main's pointer; if it moved again in between (a merge that
# raced this cycle), integrate it now — the same way — and push before recording.
refresh_submodule_pointers() {
  local i path ptr rc ctx
  head_present || return 0
  for i in "${!SUB_NAME[@]}"; do
    path="${SUB_PATH[$i]}"; ctx="submodule ${SUB_NAME[$i]}"
    sub_on_remote "$i" || continue
    ref_present "HEAD:$path" || continue
    # An empty checkout of an empty remote has no HEAD to record (or push).
    git -C "$path" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || continue
    ptr="$(git rev-parse --verify --quiet "origin/main:$path" 2>/dev/null)" || ptr=""
    if [ -n "$ptr" ] && ! git -C "$path" merge-base --is-ancestor "$ptr" HEAD 2>/dev/null; then
      ( cd "$path" && integrate_submodule_pointer "$i" "$ctx" && push_branch "${SUB_BRANCH[$i]}" "$ctx" ); rc=$?
      if [ "$rc" -ne 0 ]; then SUB_RC[i]="$rc"; continue; fi
    fi
    git add -- "$path" || { err "$ctx: git add of the gitlink failed"; SUB_RC[i]=1; }
  done
  # Per-submodule failures stay in SUB_RC for submodule_exit_code; only a
  # failure to commit the outer repo stops the cycle here.
  if ! git diff --cached --quiet; then
    if git commit -q -m "bridge: follow submodule HEAD"; then
      log "recorded updated submodule pointer(s)"
    else
      err "committing the updated submodule pointer(s) failed"; return 1
    fi
  fi
}

# The cycle's final exit code once the outer work is done: a submodule that
# failed this cycle (not a missing key — that only alerts) is a failed cycle,
# so the healthcheck can see it, even though everything else went through.
submodule_exit_code() {
  local i rc worst=0
  for i in "${!SUB_NAME[@]}"; do
    rc="${SUB_RC[$i]}"
    [ "$rc" = 3 ] && continue
    [ "$rc" -gt "$worst" ] && worst="$rc"
  done
  [ "$worst" -eq 0 ] || err "$worst-class failure in a submodule this cycle (see above) — the outer vault still synced"
  return "$worst"
}

# The outer rebase just checked out origin/main. Two shapes of submodule change
# arriving from upstream need the working tree repaired BEFORE anything is
# synced to devices ($1 = HEAD before the rebase, or empty):
#   - a folder that was plain files in $1 and is a gitlink now (the README's
#     "folder already had notes" conversion): git emptied it on checkout, and
#     the device push would delete those notes everywhere. Put the pre-rebase
#     files back; the next pre-pass materializes the folder and commits them
#     as its root commit, rebased vault-wins onto the folder's repo.
#   - a materialized folder whose gitlink is gone (the submodule was removed
#     upstream): its `.git` file would make the next `git add -A` re-add the
#     pointer or fail outright. Detach it so its notes are plain vault files
#     again (vault wins: nothing on the devices is deleted), and drop its git
#     dir under .git/modules with it — left behind, it would block the same
#     submodule from ever being re-added (materialize_submodule refuses a git
#     dir with history whose checkout has no `.git`).
repair_submodule_transitions() {
  local pre="$1" entry mode path gitfile
  head_present || return 0
  while IFS= read -r -d '' entry; do
    read -r mode _ _ <<< "${entry%%$'\t'*}"; path="${entry#*$'\t'}"
    [ "$mode" = 160000 ] || continue
    in_vault "$path" || continue
    [ -e "$path/.git" ] && continue
    [ -n "$pre" ] && [ "$(git cat-file -t "$pre:$path" 2>/dev/null)" = tree ] || continue
    alertlog "submodule at $path: origin/main turned this folder into a submodule; restoring its notes from the previous commit so nothing is deleted from your devices — they become the folder's first commit next cycle."
    mkdir -p "$path" || return 1
    git archive "$pre" -- "$path" | tar -x -C "$REPO_DIR" || { err "restoring $path from ${pre:0:12} failed"; return 1; }
  done < <(git ls-files -s -z)
  # A materialized folder can only exist once a submodule has been listed and
  # its git dir created, so skip the whole-tree walk for the common vault that
  # has neither.
  [ "${#SUB_NAME[@]}" -gt 0 ] || [ -d "$REPO_DIR/.git/modules" ] || return 0
  while IFS= read -r -d '' gitfile; do
    path="${gitfile#./}"; path="${path%/.git}"
    in_vault "$path" || continue
    index_is_gitlink "$path" && continue
    grep -q '^gitdir: .*\.git/modules/' "$gitfile" 2>/dev/null || continue
    alertlog "submodule at $path: no longer a submodule on origin/main — detaching the folder; its notes stay in the vault as plain files."
    remove_module_gitdir "$gitfile"
    rm -f "$gitfile" || return 1
  done < <(find . -path ./.git -prune -o -type f -name .git -print0 2>/dev/null)
}

# remove_module_gitdir GITFILE: delete the git dir a submodule's `.git` file
# points at, provided it really lives under $REPO_DIR/.git/modules (a `.git`
# file pointing anywhere else is not ours to touch). Failure only logs — the
# detach itself must still go ahead.
remove_module_gitdir() {
  local gitfile="$1" gitdir modules
  gitdir="$(sed -n 's/^gitdir: //p' "$gitfile" 2>/dev/null | head -n1)"
  [ -n "$gitdir" ] || return 0
  case "$gitdir" in /*) ;; *) gitdir="$(dirname "$gitfile")/$gitdir" ;; esac
  gitdir="$(cd "$gitdir" 2>/dev/null && pwd -P)" || return 0
  modules="$(cd "$REPO_DIR/.git/modules" 2>/dev/null && pwd -P)" || return 0
  case "$gitdir/" in "$modules"/?*) ;; *) return 0 ;; esac
  rm -rf "$gitdir" || err "could not remove $gitdir — re-adding this submodule later will need it removed by hand"
}

# ---------------------------------------------------------------------------
# Recover from a previous cycle killed mid-operation (docker stop, power loss).
# ---------------------------------------------------------------------------
recover_interrupted "" || exit 1

# ================================ cycle ====================================

# (a) Pull device changes down from Obsidian Sync into the working tree.
ob_sync "device pull" || exit 1

# (a') Submodules first: commit, fetch, follow the outer pointer, rebase and
#      push each one in its own repo, so the gitlink the outer commit records
#      already exists upstream. origin/main is fetched up front so the pointers
#      the submodules follow are current.
discover_submodules
if [ "${#SUB_NAME[@]}" -gt 0 ]; then
  configure_submodule_routing || err "could not (re)write submodule ssh routing — pushes may use the wrong key"
  fetch_branch main "" || exit 1
  run_submodule_cycles
fi

# (b) Commit local vault changes, if any.
commit_working_tree "" || exit 1

# (c) Bring in merged skill PRs (== git pull --rebase origin main), with the
#     network step (fetch) split from the merge step (rebase) so a network
#     error (retry next tick) is never mistaken for a real conflict (alert).
#     Fetched again after the submodule pre-pass on purpose: a pointer that
#     moved meanwhile is integrated here rather than as a rejected push.
fetch_branch main "" || exit 1

if ! head_present; then
  # Brand-new repo and an empty vault: nothing was committed in (b).
  if ref_present origin/main; then
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

pre_rebase="$(git rev-parse --verify --quiet HEAD)" || pre_rebase=""
rebase_onto origin/main "" || exit "$?"

# (c') Repair folders that origin/main turned into, or out of, submodules, then
#      re-record every submodule pointer from its submodule's HEAD (following
#      any pointer origin/main moved since the pre-pass).
repair_submodule_transitions "$pre_rebase" || exit 1
refresh_submodule_pointers || exit "$?"

# (d) Publish to main.
push_branch main "" || exit "$?"

# (e) Propagate merged skill changes back out to devices.
ob_sync "device push" || exit 1

# ------------------------------- success -----------------------------------
submodule_exit_code || exit "$?"
mark_success || exit 1
