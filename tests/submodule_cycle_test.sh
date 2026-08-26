#!/usr/bin/env bash
# End-to-end test of bridge.sh's submodule support against LOCAL bare remotes,
# with `ob` (Obsidian Sync) and `commit-message` stubbed on PATH. No network,
# no Docker. Run from anywhere: tests/submodule_cycle_test.sh
#
# The bridge under test is scripts/bridge.sh by default; set BRIDGE_BIN to a
# command (e.g. a built cmd/bridge binary) to run the same scenarios against
# it — every implementation must pass this file unchanged.
#
# Scenarios (one bridge cycle each):
#   1. bootstrap an empty bridge from the outer remote (.gitmodules arrives)
#   2. device edits inside the submodule land on ITS remote; the outer gitlink
#      matches; a submodule with no deploy key commits locally, is not pushed,
#      alerts, and does not fail the cycle; a submodule outside the vault and
#      the .git file are left alone / never leave the bridge
#   3. an upstream pointer bump to a commit off the submodule's branch is
#      fast-forwarded into the submodule (after a stale index.lock recovery)
#   4. an upstream pointer bump to an OLDER commit does not move the submodule
#      backwards; the pointer is re-recorded from HEAD
#   5. a conflicting upstream edit (and a conflicting outer pointer bump)
#      resolves vault-wins, with the non-conflicting upstream change merged in
#   9. a .gitmodules entry without a gitlink is ignored but its edits still commit
#  10. a folder of existing notes converted to a submodule keeps its notes
#  11. a submodule removed upstream is detached, its notes kept as plain files
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/bridge-submodule-test.XXXXXX")"
if [ -n "${KEEP_TMP:-}" ]; then echo "keeping $T"; else trap 'rm -rf "$T"' EXIT; fi

export HOME="$T/home"
mkdir -p "$HOME/.ssh" "$T/bin"
chmod 700 "$HOME/.ssh"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1

# --- stubs ------------------------------------------------------------------
cat > "$T/bin/ob" <<'EOF'
#!/bin/sh
echo "ob $*" >> "${OB_LOG:?}"
exit 0
EOF
cat > "$T/bin/commit-message" <<'EOF'
#!/bin/sh
exit 1
EOF
# macOS has neither flock nor GNU timeout; the bridge only needs them to exist.
command -v flock >/dev/null || printf '#!/bin/sh\nexit 0\n' > "$T/bin/flock"
command -v timeout >/dev/null || cat > "$T/bin/timeout" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
shift   # the duration
exec "$@"
EOF
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH"
export OB_LOG="$T/ob.log"

# --- remotes ----------------------------------------------------------------
SUB_REMOTE="$T/remotes/notes.git"
OUTER_REMOTE="$T/remotes/vault.git"
NOKEY_URL="git@github.com:example/nokey.git"
mkdir -p "$T/remotes"
git init -q --bare -b main "$SUB_REMOTE"
git init -q --bare -b main "$OUTER_REMOTE"

# The collaborator's clone of the shared submodule repo.
git clone -q "$SUB_REMOTE" "$T/collab-sub" 2>/dev/null
( cd "$T/collab-sub" && git checkout -q -b main && echo "upstream a" > a.md && git add -A \
  && git commit -qm "upstream: a.md" && git push -q origin main )
SUB_SEED="$(git -C "$T/collab-sub" rev-parse HEAD)"

# The owner's clone of the outer repo: vault/, a real submodule at
# vault/Cove QMS, a keyless submodule at vault/NoKey, and one outside the vault.
git clone -q "$OUTER_REMOTE" "$T/collab-outer" 2>/dev/null
(
  cd "$T/collab-outer" && git checkout -q -b main
  mkdir -p vault && echo "note" > vault/n.md
  git -c protocol.file.allow=always submodule add -q "$SUB_REMOTE" "vault/Cove QMS"
  git config -f .gitmodules submodule.vault/NoKey.path vault/NoKey
  git config -f .gitmodules submodule.vault/NoKey.url "$NOKEY_URL"
  git update-index --add --cacheinfo "160000,$SUB_SEED,vault/NoKey"
  git config -f .gitmodules submodule.tools/ext.path tools/ext
  git config -f .gitmodules submodule.tools/ext.url "$NOKEY_URL"
  git update-index --add --cacheinfo "160000,$SUB_SEED,tools/ext"
  git add vault/n.md .gitmodules && git commit -qm "vault + submodules" && git push -q origin main
)
for p in 'vault/Cove QMS' vault/NoKey tools/ext; do
  [ "$(git -C "$OUTER_REMOTE" ls-tree main "$p" | cut -d' ' -f1)" = 160000 ] || { echo "seed: $p is not a gitlink"; exit 1; }
done

# --- the bridge -------------------------------------------------------------
export REPO_DIR="$T/bridge" VAULT_DIR="$T/bridge/vault"
export SUCCESS_MARKER="$T/last-success" BRIDGE_LOCKFILE="$T/lock" BRIDGE_LIB="$SCRIPTS"
export OB_SYNC_TIMEOUT=5
git init -q -b main "$REPO_DIR"
git -C "$REPO_DIR" remote add origin "$OUTER_REMOTE"
mkdir -p "$VAULT_DIR"

SUB="$VAULT_DIR/Cove QMS"
fails=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
sub_remote_tip() { git -C "$SUB_REMOTE" rev-parse main; }
outer_ptr()      { git -C "$OUTER_REMOTE" rev-parse "main:$1"; }
sub_head()       { git -C "$SUB" rev-parse HEAD; }
# The keyless submodule's HEAD is never recorded (by design), so the outer
# repo permanently reports it modified; "clean" means everything else is.
outer_clean()    { test -z "$(git -C "$REPO_DIR" status --porcelain -- . ':!vault/NoKey')"; }

cycles=0
run_cycle() {
  local label="$1" want_rc="${2:-0}" rc=0
  cycles=$((cycles + 1))
  printf '\n== cycle %d: %s\n' "$cycles" "$label"
  rm -f "$SUCCESS_MARKER"; : > "$OB_LOG"
  "${BRIDGE_BIN:-$SCRIPTS/bridge.sh}" > "$T/cycle.log" 2>&1 || rc=$?
  [ -z "${KEEP_TMP:-}" ] || cp "$T/cycle.log" "$T/cycle-$cycles.log"
  if [ "$rc" -ne "$want_rc" ]; then
    fail "exit code $rc (wanted $want_rc)"; sed 's/^/    | /' "$T/cycle.log"
  else
    pass "exit code $rc"
  fi
  if [ "$want_rc" -eq 0 ]; then check "success marker written" test -f "$SUCCESS_MARKER"; fi
}
logged() { grep -q -- "$1" "$T/cycle.log"; }

# 1 ---------------------------------------------------------------------------
run_cycle "bootstrap from an empty bridge"
check "vault adopted from origin/main" test -f "$VAULT_DIR/n.md"
check ".gitmodules present"           test -f "$REPO_DIR/.gitmodules"

# 2 ---------------------------------------------------------------------------
echo "device note" > "$SUB/note.md"              # a device created this
mkdir -p "$VAULT_DIR/NoKey" && echo "k" > "$VAULT_DIR/NoKey/k.md"
run_cycle "submodule commit lands upstream; missing key degrades gracefully"
check "submodule .git is a file with a relative gitdir" \
  grep -q '^gitdir: \.\./\.\./\.git/modules/vault/Cove QMS$' "$SUB/.git"
check "submodule commit landed on its remote" \
  git -C "$SUB_REMOTE" cat-file -e "main:note.md"
check "upstream a.md kept (root commit rebased onto upstream)" test -f "$SUB/a.md"
check "upstream seed is an ancestor of the new tip" \
  git -C "$SUB_REMOTE" merge-base --is-ancestor "$SUB_SEED" main
check "outer gitlink matches the submodule remote tip" \
  test "$(outer_ptr 'vault/Cove QMS')" = "$(sub_remote_tip)"
check "outer gitlink matches the submodule HEAD" \
  test "$(outer_ptr 'vault/Cove QMS')" = "$(sub_head)"
check "keyless submodule committed locally" \
  git -C "$VAULT_DIR/NoKey" cat-file -e "HEAD:k.md"
check "keyless submodule alerted" logged "ALERT: submodule vault/NoKey: no deploy key"
check "keyless submodule names its env var" logged "GIT_SUBMODULE_DEPLOY_KEY_FILE_VAULT_NOKEY"
check "keyless submodule pointer NOT moved to an unpushed commit" \
  test "$(outer_ptr vault/NoKey)" = "$SUB_SEED"
check "submodule outside the vault untouched" test ! -e "$REPO_DIR/tools/ext/.git"
check "outer repo never saw the submodule's files" \
  test -z "$(git -C "$OUTER_REMOTE" ls-tree -r main --name-only | grep -E '^vault/(Cove QMS|NoKey)/')"
check "ob sync ran twice (pull, push)" test "$(grep -c '^ob sync' "$OB_LOG")" -eq 2

# 3 ---------------------------------------------------------------------------
( cd "$T/collab-sub" && git pull -q --rebase origin main && git checkout -q -b feature \
  && echo "d" > d.md && git add -A && git commit -qm "collab: d.md (feature branch)" \
  && git push -q origin feature && git checkout -q main )
D="$(git -C "$T/collab-sub" rev-parse feature)"
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git update-index --cacheinfo "160000,$D,vault/Cove QMS" \
  && git commit -qm "bump Cove QMS to feature" && git push -q origin main )
touch "$REPO_DIR/.git/modules/vault/Cove QMS/index.lock"   # an interrupted cycle
run_cycle "upstream pointer bump (off-branch commit) fast-forwards the submodule"
check "stale submodule index.lock recovered" logged "recovering in submodule vault/Cove QMS: removing a stale index.lock"
check "submodule fast-forwarded to the pointer" test "$(sub_head)" = "$D"
check "the pointed-at file is in the vault"    test -f "$SUB/d.md"
check "outer gitlink still matches HEAD"       test "$(outer_ptr 'vault/Cove QMS')" = "$D"

# 4 ---------------------------------------------------------------------------
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git update-index --cacheinfo "160000,$SUB_SEED,vault/Cove QMS" \
  && git commit -qm "bump Cove QMS BACK to the seed" && git push -q origin main )
run_cycle "upstream pointer bump backwards does not move the submodule"
check "submodule HEAD unchanged"                 test "$(sub_head)" = "$D"
check "d.md still in the vault"                  test -f "$SUB/d.md"
check "outer gitlink re-recorded from HEAD"      test "$(outer_ptr 'vault/Cove QMS')" = "$D"
check "follow-HEAD commit made"                  logged "recorded updated submodule pointer"

# 5 ---------------------------------------------------------------------------
( cd "$T/collab-sub" && git pull -q --rebase origin main && echo "upstream text" > note.md \
  && echo "z" > z.md && git add -A && git commit -qm "collab: edit note.md, add z.md" \
  && git push -q origin main )
U="$(git -C "$T/collab-sub" rev-parse HEAD)"
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git update-index --cacheinfo "160000,$U,vault/Cove QMS" \
  && git commit -qm "bump Cove QMS to the collab edit" && git push -q origin main )
echo "vault text" > "$SUB/note.md"               # a device edited the same note
run_cycle "conflicting upstream edit resolves vault-wins"
check "vault's version of note.md won"        test "$(cat "$SUB/note.md")" = "vault text"
check "non-conflicting upstream z.md merged"  test -f "$SUB/z.md"
check "vault-wins alert logged for the submodule" \
  logged "ALERT: rebase conflict on submodule vault/Cove QMS (upstream pointer) pulling $U — auto-resolved in favour of the vault"
check "upstream commit is in the pushed history" git -C "$SUB_REMOTE" merge-base --is-ancestor "$U" main
check "submodule remote has the vault's note"  test "$(git -C "$SUB_REMOTE" show main:note.md)" = "vault text"
check "outer gitlink matches the submodule tip" test "$(outer_ptr 'vault/Cove QMS')" = "$(sub_remote_tip)"
check "outer gitlink matches the submodule HEAD" test "$(outer_ptr 'vault/Cove QMS')" = "$(sub_head)"
check "submodule tree clean after the cycle"     test -z "$(git -C "$SUB" status --porcelain)"
check "outer tree clean after the cycle"         outer_clean

# 6 ---------------------------------------------------------------------------
# The collaborator points the outer repo at a commit on ANOTHER branch of the
# submodule while the vault has a new commit of its own: the pointers diverge,
# so the submodule is rebased onto the pointer (vault wins) before it pushes.
( cd "$T/collab-sub" && git pull -q --rebase origin main && git checkout -q -b feature2 \
  && echo "e" > e.md && echo "upstream again" > note.md && git add -A \
  && git commit -qm "collab: e.md + note.md (feature2)" && git push -q origin feature2 \
  && git checkout -q main )
E="$(git -C "$T/collab-sub" rev-parse feature2)"
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git update-index --cacheinfo "160000,$E,vault/Cove QMS" \
  && git commit -qm "bump Cove QMS to feature2" && git push -q origin main )
echo "vault again" > "$SUB/note.md"; echo "w" > "$SUB/w.md"
run_cycle "diverged upstream pointer: vault-wins rebase of the submodule"
check "submodule rebased onto the diverged pointer (alerted)" logged "ALERT: submodule vault/Cove QMS: origin/main moved its pointer"
check "pointer commit is now in the submodule's history" git -C "$SUB" merge-base --is-ancestor "$E" HEAD
check "vault's note.md won again"                test "$(cat "$SUB/note.md")" = "vault again"
check "both sides' files present"                test -f "$SUB/e.md" -a -f "$SUB/w.md"
check "no outer gitlink conflict (pointer already integrated)" \
  test "$(grep -c 'ALERT: rebase conflict pulling origin/main' "$T/cycle.log")" -eq 0
check "result pushed to the submodule remote"    test "$(sub_remote_tip)" = "$(sub_head)"
check "outer gitlink follows the submodule HEAD" test "$(outer_ptr 'vault/Cove QMS')" = "$(sub_head)"
check "outer repo pushed"                        test "$(git -C "$OUTER_REMOTE" rev-parse main)" = "$(git -C "$REPO_DIR" rev-parse HEAD)"
check "submodule tree clean after the cycle"     test -z "$(git -C "$SUB" status --porcelain)"
check "outer tree clean after the cycle"         outer_clean
check "keyless pointer still never moved"        test "$(outer_ptr vault/NoKey)" = "$SUB_SEED"

# 7 ---------------------------------------------------------------------------
# The race: origin/main moves the pointer AFTER the pre-pass read it (simulated
# by a pre-push hook in the submodule that bumps the outer repo to an
# off-branch commit while the submodule is pushing its own new commit). The
# outer rebase then hits a gitlink conflict that -X theirs can't resolve; the
# bridge resolves it for the vault, integrates the pointer in the post-pass,
# and pushes both repos consistent.
( cd "$T/collab-sub" && git pull -q --rebase origin main && git checkout -q -b feature3 \
  && echo "f" > f.md && git add -A && git commit -qm "collab: f.md (feature3)" \
  && git push -q origin feature3 && git checkout -q main )
F="$(git -C "$T/collab-sub" rev-parse feature3)"
HOOK="$REPO_DIR/.git/modules/vault/Cove QMS/hooks/pre-push"
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<EOF
#!/bin/sh
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
cd "$T/collab-outer" && git pull -q --rebase origin main \\
  && git update-index --cacheinfo "160000,$F,vault/Cove QMS" \\
  && git commit -qm "race: bump Cove QMS to feature3" && git push -q origin main
rm -f "\$0"
EOF
chmod +x "$HOOK"
echo "g" > "$SUB/g.md"
run_cycle "pointer moved mid-cycle: outer gitlink conflict + post-pass integration"
check "the race hook fired"                       test ! -e "$HOOK"
check "outer gitlink conflict resolved for the vault" logged "ALERT: rebase conflict pulling origin/main"
check "post-pass integrated the moved pointer"    logged "ALERT: submodule vault/Cove QMS: origin/main moved its pointer to ${F:0:12}"
check "pointed-at file is in the vault"           test -f "$SUB/f.md" -a -f "$SUB/g.md"
check "result pushed to the submodule remote"     test "$(sub_remote_tip)" = "$(sub_head)"
check "outer gitlink follows the submodule HEAD"  test "$(outer_ptr 'vault/Cove QMS')" = "$(sub_head)"
check "outer repo pushed"                         test "$(git -C "$OUTER_REMOTE" rev-parse main)" = "$(git -C "$REPO_DIR" rev-parse HEAD)"
check "submodule tree clean after the cycle"      test -z "$(git -C "$SUB" status --porcelain)"
check "outer tree clean after the cycle"          outer_clean

# 8 ---------------------------------------------------------------------------
run_cycle "idle cycle"
check "nothing pushed on an idle cycle" logged "nothing to push (origin/main is up to date)"
check "nothing pushed for the submodule" logged "nothing to push for submodule vault/Cove QMS"
check "keyless submodule alerts exactly once per cycle" test "$(grep -c 'ALERT: submodule vault/NoKey' "$T/cycle.log")" -eq 1

# 9 ---------------------------------------------------------------------------
# .gitmodules lists a folder that is still plain files (hand-edited): it is
# ignored, and — crucially — device edits under it keep being committed.
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && mkdir -p vault/Plain && echo "p" > vault/Plain/p.md \
  && git config -f .gitmodules submodule.vault/Plain.path vault/Plain \
  && git config -f .gitmodules submodule.vault/Plain.url "$NOKEY_URL" \
  && git add -A && git commit -qm "list vault/Plain without a gitlink" && git push -q origin main )
run_cycle "listed folder that is not a gitlink arrives"
check "plain folder synced to the vault" test -f "$VAULT_DIR/Plain/p.md"
echo "edited on a device" > "$VAULT_DIR/Plain/p.md"
run_cycle "device edit under the listed plain folder is still committed"
check "plain folder alerted"            logged "ALERT: submodule vault/Plain: listed in .gitmodules but vault/Plain is not a submodule pointer"
check "edit under the plain folder pushed" \
  test "$(git -C "$OUTER_REMOTE" show main:vault/Plain/p.md)" = "edited on a device"
check "plain folder never materialized" test ! -e "$VAULT_DIR/Plain/.git"

# 10 --------------------------------------------------------------------------
# A folder that already has notes on the devices is turned into a submodule by
# a merged PR. The notes must survive (they become the folder's first commit,
# rebased onto the folder's repo), never be deleted from the devices.
LEGACY_REMOTE="$T/remotes/legacy.git"
git init -q --bare -b main "$LEGACY_REMOTE"
git clone -q "$LEGACY_REMOTE" "$T/collab-legacy" 2>/dev/null
( cd "$T/collab-legacy" && git checkout -q -b main && echo "seed" > seed.md && git add -A \
  && git commit -qm "legacy: seed" && git push -q origin main )
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && mkdir -p vault/Legacy && echo "old note" > vault/Legacy/l.md \
  && git add -A && git commit -qm "plain Legacy folder" && git push -q origin main )
run_cycle "plain Legacy folder arrives"
check "legacy note in the vault" test -f "$VAULT_DIR/Legacy/l.md"
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git rm -q -r --cached vault/Legacy && rm -rf vault/Legacy \
  && git -c protocol.file.allow=always submodule add -q "$LEGACY_REMOTE" vault/Legacy \
  && git commit -qm "share Legacy as a submodule" && git push -q origin main )
run_cycle "folder converted to a submodule keeps its notes"
check "conversion alerted"                       logged "ALERT: submodule at vault/Legacy: origin/main turned this folder into a submodule; restoring"
check "note NOT deleted from the vault"          test "$(cat "$VAULT_DIR/Legacy/l.md")" = "old note"
check "outer gitlink recorded for Legacy"        test "$(git -C "$REPO_DIR" ls-files -s vault/Legacy | cut -d' ' -f1)" = 160000
run_cycle "converted folder's notes become its first commit"
check "note pushed to the folder's repo"         test "$(git -C "$LEGACY_REMOTE" show main:l.md)" = "old note"
check "folder's seed merged in"                  test -f "$VAULT_DIR/Legacy/seed.md"
check "outer gitlink follows the folder's HEAD" \
  test "$(outer_ptr vault/Legacy)" = "$(git -C "$VAULT_DIR/Legacy" rev-parse HEAD)"
check "outer tree clean after the cycle"         outer_clean

# 11 --------------------------------------------------------------------------
# The submodule is removed again by a merged PR: the folder is detached, its
# notes stay, and the outer cycle keeps working (no half-submodule left over).
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git -c protocol.file.allow=always submodule update -q --init vault/Legacy \
  && git rm -q vault/Legacy && git commit -qm "unshare Legacy" && git push -q origin main )
run_cycle "submodule removed upstream is detached"
check "removal alerted"                          logged "ALERT: submodule at vault/Legacy: no longer a submodule on origin/main — detaching"
check "notes still in the vault"                 test -f "$VAULT_DIR/Legacy/l.md" -a -f "$VAULT_DIR/Legacy/seed.md"
check "folder no longer a git checkout"          test ! -e "$VAULT_DIR/Legacy/.git"
check "its git dir is gone too"                  test ! -e "$REPO_DIR/.git/modules/vault/Legacy"
run_cycle "detached folder is committed as plain files"
check "notes now plain files on the outer remote" \
  test "$(git -C "$OUTER_REMOTE" show main:vault/Legacy/l.md)" = "old note"
check "outer tree clean after the cycle"         outer_clean

# 11b -------------------------------------------------------------------------
# The same folder is shared again later: a stale git dir left by the detach
# must not block the folder from being materialized a second time.
( cd "$T/collab-outer" && git pull -q --rebase origin main \
  && git rm -q -r --cached vault/Legacy && rm -rf vault/Legacy \
  && git -c protocol.file.allow=always submodule add -q --force "$LEGACY_REMOTE" vault/Legacy \
  && git commit -qm "share Legacy again" && git push -q origin main )
run_cycle "re-shared folder keeps its notes"
check "re-conversion alerted"                    logged "ALERT: submodule at vault/Legacy: origin/main turned this folder into a submodule; restoring"
check "note NOT deleted from the vault"          test "$(cat "$VAULT_DIR/Legacy/l.md")" = "old note"
run_cycle "re-shared folder is materialized again"
check "not refused"                              test "$(grep -c 'refusing to guess' "$T/cycle.log")" = 0
check "folder is a git checkout again"           test -e "$VAULT_DIR/Legacy/.git"
check "outer gitlink follows the folder's HEAD" \
  test "$(outer_ptr vault/Legacy)" = "$(git -C "$VAULT_DIR/Legacy" rev-parse HEAD)"
check "outer tree clean after the cycle"         outer_clean

# --- unit-level: the env-var name transform -----------------------------------
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=submodules.sh
. "$SCRIPTS/submodules.sh"
check "env name transform: vault/Cove QMS -> VAULT_COVE_QMS" \
  test "$(submodule_env_name 'vault/Cove QMS')" = VAULT_COVE_QMS
check "env name transform: notes-2.0 -> NOTES_2_0" \
  test "$(submodule_env_name 'notes-2.0')" = NOTES_2_0
check "ssh alias: VAULT_COVE_QMS -> bridge-submodule-vault-cove-qms" \
  test "$(submodule_ssh_alias VAULT_COVE_QMS)" = bridge-submodule-vault-cove-qms
submodule_parse_ssh_url "git@github.com:coveqms/notes.git"
check "scp url aliased" test "$(submodule_alias_url x)" = "git@x:coveqms/notes.git"
submodule_parse_ssh_url "ssh://git@github.com:22/coveqms/notes.git"
check "ssh:// url aliased" test "$(submodule_alias_url x)" = "ssh://git@x:22/coveqms/notes.git"
check "https url is not routed" test "$(submodule_parse_ssh_url https://github.com/a/b.git; echo $?)" = 1
check "local path is not routed" test "$(submodule_parse_ssh_url "$SUB_REMOTE"; echo $?)" = 1
check "local path needs no key"  submodule_needs_no_key "$SUB_REMOTE"
check "file:// needs no key"     submodule_needs_no_key "file://$SUB_REMOTE"
check "https needs a key it can't have" test "$(submodule_needs_no_key https://github.com/a/b.git; echo $?)" = 1

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo "ALL PASSED" || echo "$fails FAILED")"
[ "$fails" -eq 0 ]
