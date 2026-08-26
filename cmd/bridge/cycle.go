package main

import (
	"archive/tar"
	"bytes"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// materialize turns a live directory (already full of synced notes, or still
// empty) into a submodule checkout WITHOUT touching its files: a git dir under
// .git/modules/<name> like `git submodule` would create, a `.git` file
// pointing at it, the remote wired up — and no HEAD yet. The first commit pass
// then records the directory's content as a root commit that is rebased
// vault-wins onto the remote branch, exactly like the outer repo's first sync
// (an empty directory instead adopts the remote content — see submoduleCycle).
// We never run `git submodule update`: it would check out over files devices
// may have edited since the pointer was recorded. Idempotent: a cycle killed
// halfway through is completed on the next one.
func (c *cycle) materialize(s *submodule) bool {
	gitdir := filepath.Join(c.cfg.repoDir, ".git", "modules", filepath.FromSlash(s.name))
	if !exists(filepath.Join(s.repo.dir, ".git")) {
		if isDir(gitdir) {
			if exec.Command("git", "--git-dir="+gitdir, "rev-parse", "--verify", "--quiet", "HEAD").Run() == nil {
				logErr("submodule %s: %s has history but %s/.git is missing — refusing to guess; remove one of them", s.name, gitdir, s.path)
				return false
			}
			os.RemoveAll(gitdir) // an init a killed cycle never finished: start over
		}
		if err := os.MkdirAll(s.repo.dir, 0o755); err != nil {
			return false
		}
		logInfo("submodule %s: initializing %s as a checkout of %s", s.name, s.path, s.url)
		if exec.Command("git", "init", "-q", "-b", s.branch, s.repo.dir).Run() != nil {
			logErr("submodule %s: git init failed", s.name)
			return false
		}
		// Move the git dir under .git/modules/<name> with the relative gitdir /
		// core.worktree wiring `git submodule` uses, so it survives the volume
		// being mounted elsewhere.
		if c.outer.quiet("submodule", "absorbgitdirs", "--", s.path) != nil {
			logErr("submodule %s: git submodule absorbgitdirs failed", s.name)
			return false
		}
	}
	if _, err := s.repo.out("remote", "get-url", "origin"); err != nil {
		if s.repo.quiet("remote", "add", "origin", s.url) != nil {
			return false
		}
	}
	return true
}

// integratePointer brings the submodule up to what the outer repo's
// origin/main points it at. The pointer is derived from HEAD, never the other
// way round:
//   - pointer already in HEAD's history (equal, or an older commit — e.g. our
//     own push hadn't reached the outer repo yet): nothing to do; the
//     submodule never moves backwards;
//   - pointer ahead of HEAD: fast-forward (the tree is clean after the commit);
//   - diverged: rebase our commits onto the pointer, vault wins, with an alert.
//
// Never `git submodule update` — that would check out over live files.
func (c *cycle) integratePointer(s *submodule) rc {
	ctx := s.ctx()
	head, ok := s.repo.revParse("HEAD")
	if !ok {
		return rcOK
	}
	ptr, ok := c.outer.revParse("origin/main:" + s.path)
	if !ok || ptr == head || s.repo.isAncestor(ptr, head) {
		return rcOK
	}
	if !s.repo.hasCommit(ptr) && s.repo.quiet("fetch", "-q", "origin", ptr) != nil {
		logAlert("%s: origin/main points it at %s, which its remote does not have — keeping the vault's checkout; the pointer is re-recorded from HEAD.", ctx, short(ptr))
		return rcOK
	}
	if s.repo.dirty() {
		logErr("%s: origin/main moved its pointer but the checkout is dirty — deferring to next tick", ctx)
		return rcRetry
	}
	if s.repo.isAncestor(head, ptr) {
		if s.repo.quiet("merge", "-q", "--ff-only", ptr) == nil {
			logInfo("%s: fast-forwarded to the upstream pointer %s", ctx, short(ptr))
			return rcOK
		}
		logErr("%s: fast-forward to %s failed — deferring to next tick", ctx, short(ptr))
		return rcRetry
	}
	logAlert("%s: origin/main moved its pointer to %s while the vault has its own commits — rebasing the submodule onto it, vault wins on any clash.", ctx, short(ptr))
	return s.repo.rebaseOnto(ptr, ctx+" (upstream pointer)")
}

// submoduleCycle is one vault-wins cycle for a submodule, in its own repo:
// commit -> fetch -> follow the outer pointer -> rebase -> push, mirroring the
// outer cycle's (b)-(d) but never failing the outer cycle. Returns rcOK (HEAD
// is on the remote), rcLocalOnly (committed locally only — no deploy key,
// alerted), rcRetry or rcConflict (both alerted/logged).
func (c *cycle) submoduleCycle(s *submodule) rc {
	ctx := s.ctx()
	if !isDir(s.repo.dir) {
		logErr("%s: %s is missing", ctx, s.path)
		return rcRetry
	}
	if !s.repo.recoverInterrupted("in " + ctx) {
		return rcRetry
	}
	if !s.repo.commitWorkingTree(ctx, nil) {
		return rcRetry
	}
	if !s.canReachRemote(c.cfg) {
		logAlert("%s: no deploy key — its changes are committed locally and still sync to your devices, but nothing is pushed to %s. Set GIT_SUBMODULE_DEPLOY_KEY_FILE_%s (or GIT_SUBMODULE_DEPLOY_KEY_%s) to a deploy key with write access to that repo and restart.", ctx, s.url, s.env, s.env)
		return rcLocalOnly
	}
	if !s.repo.fetchBranch(s.branch, ctx) {
		return rcRetry
	}
	if !s.repo.headPresent() {
		if s.repo.refPresent("origin/" + s.branch) {
			// Empty folder on the devices, content upstream: adopt it (the tree
			// is empty, so nothing of the vault's can be overwritten). Step (e)
			// then syncs it out to the devices.
			logInfo("%s: local checkout is empty; bootstrapping from origin/%s", ctx, s.branch)
			if s.repo.quiet("reset", "-q", "--hard", "origin/"+s.branch) != nil {
				logErr("%s: bootstrap from origin/%s failed — deferring to next tick", ctx, s.branch)
				return rcRetry
			}
		} else {
			logInfo("%s: empty folder and empty remote; nothing to sync yet", ctx)
			return rcOK
		}
	}
	// Follow the pointer BEFORE pushing, so the push to the submodule's branch
	// stays a fast-forward and the pointed-at commit stays in its history.
	if r := c.integratePointer(s); r != rcOK {
		return r
	}
	if r := s.repo.rebaseOnto("origin/"+s.branch, ctx); r != rcOK {
		return r
	}
	return s.repo.pushBranch(s.branch, ctx, nil)
}

// runSubmoduleCycles is the pre-pass: every submodule's own cycle before the
// outer one.
func (c *cycle) runSubmoduleCycles() {
	for _, s := range c.subs {
		s.rc = rcLocalOnly
		// .gitmodules lists it, but the outer index has no gitlink there: its
		// files are plain vault files, and turning them into a submodule would
		// move them out of the outer repo. Leave it alone until the pointer
		// exists upstream.
		if !c.outer.indexIsGitlink(s.path) {
			logAlert("submodule %s: listed in .gitmodules but %s is not a submodule pointer in the repo — ignoring it. Add it with 'git submodule add' in a clone and merge that.", s.name, s.path)
			continue
		}
		if !c.materialize(s) {
			s.rc = rcRetry
			continue
		}
		// The submodule's own origin carries the routed (per-key) URL;
		// .gitmodules keeps the canonical one for every other clone.
		if s.repo.quiet("remote", "set-url", "origin", s.routedURL(c.cfg)) != nil {
			s.rc = rcRetry
			continue
		}
		s.rc = c.submoduleCycle(s)
	}
}

// unstageUnpushedGitlinks runs after `git add -A` in the outer repo: un-stage
// the gitlink of any submodule whose HEAD isn't on its remote, so the outer
// push never references a commit the submodule remote lacks (the pointer just
// stays where it was). Only real gitlinks — a listed path that is still a
// plain folder must keep its edits.
func (c *cycle) unstageUnpushedGitlinks() bool {
	if !c.outer.headPresent() {
		return true
	}
	for _, s := range c.subs {
		if s.onRemote() {
			continue
		}
		if c.outer.indexIsGitlink(s.path) && c.outer.refPresent("HEAD:"+s.path) {
			if c.outer.quiet("reset", "-q", "--", s.path) != nil {
				return false
			}
		}
	}
	return true
}

// refreshSubmodulePointers is the post-pass, after the outer rebase:
// re-record every gitlink from its submodule's HEAD (only for submodules
// whose HEAD is on their remote) and commit the result ("follow submodule
// HEAD"). Normally the pre-pass already integrated origin/main's pointer; if
// it moved again in between (a merge that raced this cycle), integrate it now
// — the same way — and push before recording.
func (c *cycle) refreshSubmodulePointers() rc {
	if !c.outer.headPresent() {
		return rcOK
	}
	for _, s := range c.subs {
		if !s.onRemote() || !c.outer.refPresent("HEAD:"+s.path) {
			continue
		}
		if ptr, ok := c.outer.revParse("origin/main:" + s.path); ok && !s.repo.isAncestor(ptr, "HEAD") {
			r := c.integratePointer(s)
			if r == rcOK {
				r = s.repo.pushBranch(s.branch, s.ctx(), nil)
			}
			if r != rcOK {
				s.rc = r
				continue
			}
		}
		if c.outer.quiet("add", "--", s.path) != nil {
			logErr("%s: git add of the gitlink failed", s.ctx())
			s.rc = rcRetry
		}
	}
	// Per-submodule failures stay in s.rc for submoduleExitCode; only a
	// failure to commit the outer repo stops the cycle here.
	if c.outer.quiet("diff", "--cached", "--quiet") != nil {
		if c.outer.quiet("commit", "-q", "-m", "bridge: follow submodule HEAD") != nil {
			logErr("committing the updated submodule pointer(s) failed")
			return rcRetry
		}
		logInfo("recorded updated submodule pointer(s)")
	}
	return rcOK
}

// submoduleExitCode is the cycle's final exit code once the outer work is
// done: a submodule that failed this cycle (not a missing key — that only
// alerts) is a failed cycle, so the healthcheck can see it, even though
// everything else went through.
func (c *cycle) submoduleExitCode() rc {
	worst := rcOK
	for _, s := range c.subs {
		if s.rc != rcLocalOnly && s.rc > worst {
			worst = s.rc
		}
	}
	if worst != rcOK {
		logErr("%d-class failure in a submodule this cycle (see above) — the outer vault still synced", worst)
	}
	return worst
}

// repairSubmoduleTransitions runs right after the outer rebase checked out
// origin/main. Two shapes of submodule change arriving from upstream need the
// working tree repaired BEFORE anything is synced to devices (pre = HEAD
// before the rebase, or ""):
//   - a folder that was plain files in pre and is a gitlink now (the README's
//     "folder already had notes" conversion): git emptied it on checkout, and
//     the device push would delete those notes everywhere. Put the pre-rebase
//     files back; the next pre-pass materializes the folder and commits them
//     as its root commit, rebased vault-wins onto the folder's repo.
//   - a materialized folder whose gitlink is gone (the submodule was removed
//     upstream): its `.git` file would make the next `git add -A` re-add the
//     pointer or fail outright. Detach it so its notes are plain vault files
//     again (vault wins: nothing on the devices is deleted).
func (c *cycle) repairSubmoduleTransitions(pre string) bool {
	if !c.outer.headPresent() {
		return true
	}
	vaultRel := c.cfg.vaultRel()
	inVault := func(path string) bool {
		return vaultRel == "" || strings.HasPrefix(path+"/", vaultRel+"/")
	}

	list, err := c.outer.out("ls-files", "-s", "-z")
	if err != nil {
		return false
	}
	for _, entry := range strings.Split(list, "\x00") {
		meta, path, ok := strings.Cut(entry, "\t")
		if !ok || !strings.HasPrefix(meta, "160000 ") || !inVault(path) {
			continue
		}
		dir := filepath.Join(c.cfg.repoDir, filepath.FromSlash(path))
		if exists(filepath.Join(dir, ".git")) {
			continue
		}
		if pre == "" {
			continue
		}
		if t, _ := c.outer.out("cat-file", "-t", pre+":"+path); t != "tree" {
			continue
		}
		logAlert("submodule at %s: origin/main turned this folder into a submodule; restoring its notes from the previous commit so nothing is deleted from your devices — they become the folder's first commit next cycle.", path)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return false
		}
		if err := c.restoreTree(pre, path); err != nil {
			logErr("restoring %s from %s failed: %v", path, short(pre), err)
			return false
		}
	}

	root := c.cfg.repoDir
	return filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if p == filepath.Join(root, ".git") {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() != ".git" {
			return nil
		}
		rel, _ := filepath.Rel(root, filepath.Dir(p))
		path := filepath.ToSlash(rel)
		if !inVault(path) || c.outer.indexIsGitlink(path) {
			return nil
		}
		content, _ := os.ReadFile(p)
		if !strings.HasPrefix(string(content), "gitdir: ") || !strings.Contains(string(content), ".git/modules/") {
			return nil
		}
		logAlert("submodule at %s: no longer a submodule on origin/main — detaching the folder; its notes stay in the vault as plain files.", path)
		if err := os.Remove(p); err != nil {
			return err
		}
		return filepath.SkipDir
	}) == nil
}

// restoreTree writes the files under path as of commit pre back into the
// working tree (the index is left alone — it holds the new gitlink).
func (c *cycle) restoreTree(pre, path string) error {
	cmd := exec.Command("git", "-C", c.cfg.repoDir, "archive", pre, "--", path)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return err
	}
	tr := tar.NewReader(bytes.NewReader(out))
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if unsafePath(strings.TrimSuffix(hdr.Name, "/"), false) {
			continue
		}
		dest := filepath.Join(c.cfg.repoDir, filepath.FromSlash(hdr.Name))
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(dest, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode)&0o777)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
		case tar.TypeSymlink:
			os.Remove(dest)
			if err := os.Symlink(hdr.Linkname, dest); err != nil {
				return err
			}
		}
	}
}
