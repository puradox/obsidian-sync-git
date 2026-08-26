package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// repo is one git working tree — the outer repo, or a submodule checkout. All
// git commands run with -C dir so nothing depends on the process cwd.
type repo struct {
	dir string
}

// out runs git quietly: stdout captured (trailing newline trimmed), stderr
// discarded. For queries whose failure just means "no".
func (r *repo) out(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", r.dir}, args...)...)
	cmd.Stdin = nil
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	err := cmd.Run()
	return strings.TrimRight(stdout.String(), "\n"), err
}

// run runs git with its output passed through to ours, like the script's
// un-redirected commands (rebase, push, ...), so their diagnostics land in
// `docker logs` next to the bridge's own lines.
func (r *repo) run(args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", r.dir}, args...)...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// quiet runs git with all output discarded; only the exit status matters.
func (r *repo) quiet(args ...string) error {
	_, err := r.out(args...)
	return err
}

func (r *repo) revParse(ref string) (string, bool) {
	sha, err := r.out("rev-parse", "--verify", "--quiet", ref)
	return sha, err == nil && sha != ""
}

func (r *repo) refPresent(ref string) bool { _, ok := r.revParse(ref); return ok }
func (r *repo) headPresent() bool          { return r.refPresent("HEAD") }

func (r *repo) gitDir() (string, bool) {
	d, err := r.out("rev-parse", "--git-dir")
	if err != nil || d == "" {
		return "", false
	}
	if !filepath.IsAbs(d) {
		d = filepath.Join(r.dir, d)
	}
	return d, true
}

func (r *repo) rebaseInProgress() bool {
	d, ok := r.gitDir()
	if !ok {
		return false
	}
	return isDir(filepath.Join(d, "rebase-merge")) || isDir(filepath.Join(d, "rebase-apply"))
}

func (r *repo) isAncestor(a, b string) bool {
	return r.quiet("merge-base", "--is-ancestor", a, b) == nil
}

func (r *repo) hasCommit(sha string) bool {
	return r.quiet("cat-file", "-e", sha+"^{commit}") == nil
}

func (r *repo) dirty() bool {
	s, _ := r.out("status", "--porcelain")
	return s != ""
}

// indexIsGitlink: the index records path as a submodule pointer (mode 160000).
func (r *repo) indexIsGitlink(path string) bool {
	s, err := r.out("ls-files", "-s", "--", path)
	if err != nil || s == "" {
		return false
	}
	return strings.HasPrefix(s, "160000 ")
}

// abortRebaseClean: vault-wins — abort any in-progress rebase, restoring the
// working tree to our own (vault) commit, clean. We never `reset --hard` —
// that would discard the vault commit we are trying to protect. Returns false
// if rebase state survives the abort, so callers never claim a clean repo
// that isn't.
func (r *repo) abortRebaseClean() bool {
	if r.rebaseInProgress() {
		_ = r.quiet("rebase", "--abort")
	}
	if r.rebaseInProgress() {
		logErr("git rebase --abort FAILED — the repo may be left mid-rebase; manual cleanup needed in %s", r.dir)
		return false
	}
	return true
}

// recoverInterrupted cleans up after a cycle killed mid-operation. ctx labels
// messages ("" for the outer repo, "in submodule X" for a submodule).
func (r *repo) recoverInterrupted(ctx string) bool {
	d, ok := r.gitDir()
	if !ok {
		return true
	}
	if r.rebaseInProgress() {
		logInfo("recovering%s: aborting a rebase left by an interrupted cycle", ctxSp(ctx))
		if !r.abortRebaseClean() {
			return false
		}
	}
	lock := filepath.Join(d, "index.lock")
	if isFile(lock) {
		logInfo("recovering%s: removing a stale index.lock left by an interrupted cycle", ctxSp(ctx))
		_ = os.Remove(lock)
	}
	return true
}

// fetchBranch fetches origin/<branch>. Network failure -> false (retry next
// tick). Fetching only that branch skips every other remote branch (PR
// branches), which the bridge never reads — but that refspec also fails when
// the remote simply has no such branch yet (pre-first-push), so disambiguate
// before failing.
func (r *repo) fetchBranch(branch, ctx string) bool {
	if r.quiet("fetch", "--prune", "origin", branch) == nil {
		return true
	}
	heads, err := r.out("ls-remote", "--heads", "origin", branch)
	if err == nil {
		if heads == "" {
			return true // empty remote: nothing to fetch; push creates the branch
		}
		logErr("git fetch failed%s although origin has a %s branch — deferring to next tick", ctxOn(ctx), branch)
	} else {
		logErr("git fetch failed (network?)%s — deferring to next tick", ctxOn(ctx))
	}
	return false
}

// commitWorkingTree commits whatever is in the working tree ("vault wins"
// starts here). afterAdd, if set, runs between `git add -A` and the staged
// check — the outer repo uses it to un-stage unpushed submodule pointers.
// Returns false only on a git failure.
func (r *repo) commitWorkingTree(ctx string, afterAdd func() bool) bool {
	if !r.dirty() {
		logInfo("no local %s changes to commit", ctxOr(ctx))
		return true
	}
	if err := r.quiet("add", "-A"); err != nil {
		logErr("git add failed%s", ctxIn(ctx))
		return false
	}
	if afterAdd != nil && !afterAdd() {
		logErr("could not un-stage an unpushed submodule pointer")
		return false
	}
	// A dirty submodule (untracked files inside it, or one without a commit
	// yet) shows in status but stages nothing — that's not a commit.
	if r.quiet("diff", "--cached", "--quiet") == nil {
		logInfo("no local %s changes to commit", ctxOr(ctx))
		return true
	}
	msg := commitMessage(r.dir)
	if err := r.quiet("commit", "-q", "-m", msg); err != nil {
		logErr("git commit failed%s", ctxIn(ctx))
		return false
	}
	subject, _, _ := strings.Cut(msg, "\n")
	logInfo("committed %s changes: %s", ctxOr(ctx), subject)
	return true
}

// commitMessage asks the commit-message helper (an LLM summary of the staged
// diff, run in the repo) and falls back to a plain label if it prints nothing.
func commitMessage(dir string) string {
	cmd := exec.Command("commit-message")
	cmd.Dir = dir
	out, err := cmd.Output()
	msg := strings.TrimSpace(string(out))
	if err != nil || msg == "" {
		return "vault auto-commit (" + timestamp() + ")"
	}
	return msg
}

// resolveGitlinkConflicts: merge strategies leave a submodule-pointer
// (gitlink) conflict unresolved even under -X theirs. Resolve every such entry
// in favour of the commit being replayed (stage 3 — the vault's pointer) and
// let the caller continue the rebase; the pointer is re-derived from the
// submodule's HEAD afterwards anyway. Returns false if nothing was resolved
// or any non-gitlink conflict remains (a real, unresolvable conflict).
func (r *repo) resolveGitlinkConflicts() bool {
	list, err := r.out("ls-files", "-u", "-z")
	if err != nil {
		return false
	}
	resolved := false
	for _, entry := range strings.Split(list, "\x00") {
		if entry == "" {
			continue
		}
		meta, path, ok := strings.Cut(entry, "\t")
		if !ok {
			return false
		}
		f := strings.Fields(meta) // mode sha stage
		if len(f) != 3 || f[0] != "160000" {
			return false
		}
		if f[2] != "3" {
			continue
		}
		if err := r.quiet("update-index", "--cacheinfo", "160000,"+f[1]+","+path); err != nil {
			return false
		}
		resolved = true
	}
	return resolved
}

// rebaseOnto integrates upstream (e.g. origin/main) by rebasing our vault
// commits onto it.
//
// vault-wins & self-healing: a conflict-free rebase keeps every side's
// changes. On a CONFLICT we replay resolving in favour of the vault — `-X
// theirs` keeps the commits being replayed (in a rebase "ours" is upstream and
// "theirs" is our vault commit), so a conflicting skill edit is overridden by
// your note instead of halting the bridge; non-conflicting skill hunks still
// merge in and the skill's overridden version remains in upstream's history.
// We alert so it's visible. Only a conflict that even a vault-wins replay
// can't apply (e.g. modify-vs-delete) aborts and alerts for upstream action.
//
// Returns rcOK integrated (silently, or a conflict auto-resolved for the vault
// — alerted); rcRetry a non-conflict rebase failure; rcConflict a conflict
// that can't be auto-resolved even for the vault (abort + alert).
func (r *repo) rebaseOnto(upstream, ctx string) rc {
	if !r.refPresent(upstream) {
		return rcOK
	}

	// Fast path: a conflict-free rebase integrates both sides untouched.
	if r.run("rebase", upstream) == nil {
		return rcOK
	}

	// The rebase failed. With the (default) merge backend a genuine conflict
	// always leaves unmerged index entries; anything else (a rebase that never
	// started, a transient error) is not a conflict — leave the repo clean and
	// retry.
	conflicted, _ := r.out("diff", "--name-only", "--diff-filter=U")
	conflicted = strings.ReplaceAll(strings.TrimSpace(conflicted), "\n", " ")
	if conflicted == "" && !r.rebaseInProgress() {
		logErr("git rebase %s failed%s for a non-conflict reason — deferring to next tick", upstream, ctxOn(ctx))
		return rcRetry
	}

	// A real conflict. Abort the failed attempt, then replay resolving in
	// favour of the vault so sync self-heals instead of stopping.
	if !r.abortRebaseClean() {
		logAlert("rebase conflict%s AND the abort failed — repo may be left mid-rebase; run 'git rebase --abort' in %s.", ctxOn(ctx), r.dir)
		return rcConflict
	}
	if err := r.run("rebase", "-X", "theirs", upstream); err != nil && !r.rebaseInProgress() {
		// Never started (index.lock, hook, disk full): nothing was integrated,
		// so this is not a resolved conflict — retry next tick.
		logErr("git rebase -X theirs %s failed%s without starting — deferring to next tick", upstream, ctxOn(ctx))
		return rcRetry
	}
	// -X theirs cannot resolve submodule-pointer conflicts; do those by hand
	// and continue. Each iteration resolves at least one entry or stops, so
	// the loop is bounded by the number of replayed commits.
	for r.rebaseInProgress() && r.resolveGitlinkConflicts() {
		cmd := exec.Command("git", "-C", r.dir, "rebase", "--continue")
		cmd.Env = append(os.Environ(), "GIT_EDITOR=true")
		_ = cmd.Run()
	}
	if !r.rebaseInProgress() {
		if conflicted == "" {
			conflicted = "<unknown>"
		}
		logAlert("rebase conflict%s pulling %s — auto-resolved in favour of the vault (vault wins), so sync continues. A merged upstream change was overridden by your note in: %s . The upstream version is still in %s's history; re-apply it via a fresh PR if you wanted it. On a FIRST cycle a conflict here instead means upstream's existing history doesn't match the vault — see 'The first sync' in the README.", ctxOn(ctx), upstream, conflicted, upstream)
		return rcOK
	}

	// Even a vault-wins replay couldn't apply (e.g. a note edited here but
	// deleted upstream): don't leave a half-done rebase — abort clean and alert.
	if r.abortRebaseClean() {
		logAlert("rebase conflict%s that could NOT be auto-resolved even in favour of the vault (e.g. a file modified on one side and deleted on the other). Repo left clean, nothing pushed; resolve it upstream. On a FIRST cycle see 'The first sync' in the README.", ctxOn(ctx))
	} else {
		logAlert("rebase conflict%s AND the abort failed — repo may be left mid-rebase; run 'git rebase --abort' in %s.", ctxOn(ctx), r.dir)
	}
	return rcConflict
}

// pushBranch publishes HEAD to origin/<branch> — skipped when the remote
// branch already points at HEAD (the common idle cycle; saves an SSH round
// trip). If the push is rejected (a merge landed between our fetch and our
// push), fetch + rebase once and retry; otherwise defer. afterRetryRebase, if
// set, runs after that rebase — the outer repo re-records submodule pointers
// that may have moved with it. Returns like rebaseOnto.
func (r *repo) pushBranch(branch, ctx string, afterRetryRebase func() rc) rc {
	head, _ := r.revParse("HEAD")
	if remote, ok := r.revParse("origin/" + branch); ok && remote == head {
		logInfo("nothing to push%s (origin/%s is up to date)", ctxFor(ctx), branch)
		return rcOK
	}
	if r.run("push", "origin", "HEAD:"+branch) != nil {
		logInfo("push rejected%s (a merge may have raced us) — fetching and retrying once", ctxFor(ctx))
		retryCtx := "push-retry"
		if ctx != "" {
			retryCtx = ctx + " push-retry"
		}
		if !r.fetchBranch(branch, retryCtx) {
			return rcRetry
		}
		if res := r.rebaseOnto("origin/"+branch, retryCtx); res != rcOK {
			return res
		}
		if afterRetryRebase != nil {
			if res := afterRetryRebase(); res != rcOK {
				return res
			}
		}
		if r.run("push", "origin", "HEAD:"+branch) != nil {
			logErr("push still failing after retry%s — deferring to next tick. If this repeats every cycle, check that the deploy key has WRITE access and that no branch-protection rule blocks direct pushes to %s.", ctxFor(ctx), branch)
			return rcRetry
		}
	}
	logInfo("pushed%s to origin/%s", ctxSp(ctx), branch)
	return rcOK
}

func isDir(p string) bool  { st, err := os.Stat(p); return err == nil && st.IsDir() }
func isFile(p string) bool { st, err := os.Stat(p); return err == nil && st.Mode().IsRegular() }
func exists(p string) bool { _, err := os.Lstat(p); return err == nil }
