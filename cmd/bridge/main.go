// bridge runs one full Obsidian Sync <-> git bridge cycle. entrypoint.sh
// runs it once on start and then on CRON_SCHEDULE via supercronic.
//
// The ENTIRE cycle runs under a non-blocking flock on a container-local
// lockfile (NOT on the /config volume — advisory locks can be unreliable on
// NFS/CIFS), so a slow cycle can never overlap the next scheduled tick (they
// just skip).
//
// Policy: the vault working tree is authoritative ("vault wins"). Skill and
// automation changes only ever arrive as merged PRs on origin/main. On a
// rebase conflict we resolve IN FAVOUR OF THE VAULT (git rebase -X theirs) so
// a conflicting skill edit can never halt sync: the vault's version of the
// conflicting lines is kept, every non-conflicting skill change still merges
// in, the result is pushed, and we alert so an overridden skill change can be
// re-applied upstream (its version stays in origin/main's history — nothing
// is lost). Only a conflict that even a vault-wins replay can't apply (e.g.
// modify-vs-delete) falls back to abort-and-alert.
//
// Submodules inside the vault (see submodules.go) get the same contract in
// their own repos: each is committed, fetched, rebased vault-wins and pushed
// BEFORE the outer cycle, so the outer commit can record a gitlink the
// submodule remote already has. The gitlink always follows the submodule's
// HEAD; an upstream pointer bump is integrated into the submodule
// (fast-forward, else a vault-wins rebase with an alert) and re-recorded.
//
// Exit code (surfaced by supercronic in `docker logs`):
//
//	0  cycle completed (incl. a conflict auto-resolved in favour of the vault)
//	1  recoverable failure (network / sync engine) — will retry next tick
//	2  a conflict that couldn't be auto-resolved even for the vault — upstream action
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// rc is a step's outcome, numerically identical to the shell script's exit
// codes so the two implementations stay comparable line by line.
type rc int

const (
	rcOK        rc = 0 // done; for a submodule: its HEAD is on its remote
	rcRetry     rc = 1 // transient failure — retry next tick
	rcConflict  rc = 2 // a conflict even a vault-wins replay couldn't apply
	rcLocalOnly rc = 3 // submodule committed locally only (no deploy key)
)

// config is everything the cycle reads from the environment.
type config struct {
	repoDir       string        // git repo working tree (all git commands)
	vaultDir      string        // ob sync target; the repo root or VAULT_SUBDIR within it
	successMarker string        // written on success; read by the healthcheck
	lockfile      string        // container-local flock target
	obSyncTimeout time.Duration // OB_SYNC_TIMEOUT
	home          string        // where deploy keys and ssh config live
}

func configFromEnv() (config, error) {
	c := config{
		repoDir:       envOr("REPO_DIR", "/vault"),
		successMarker: envOr("SUCCESS_MARKER", "/config/.last-success"),
		lockfile:      envOr("BRIDGE_LOCKFILE", "/tmp/obsidian-bridge.lock"),
		obSyncTimeout: 300 * time.Second,
		home:          os.Getenv("HOME"),
	}
	c.vaultDir = envOr("VAULT_DIR", c.repoDir)
	if s := os.Getenv("OB_SYNC_TIMEOUT"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 0 {
			return c, fmt.Errorf("OB_SYNC_TIMEOUT must be an integer number of seconds, got %q", s)
		}
		c.obSyncTimeout = time.Duration(n) * time.Second
	}
	return c, nil
}

func envOr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

// vaultRel is the vault's path relative to the repo root ("" when the vault
// IS the repo root).
func (c config) vaultRel() string {
	rel, err := filepath.Rel(c.repoDir, c.vaultDir)
	if err != nil || rel == "." {
		return ""
	}
	return filepath.ToSlash(rel)
}

func main() {
	// Read the heartbeat config up front so a malformed value is reported
	// before the cycle rather than while reporting its result.
	hb := heartbeatFromEnv()
	start := time.Now()

	// Deliberately NO signal handler. Reporting a SIGTERM on the way out is
	// tempting — it would name a BRIDGE_CYCLE_TIMEOUT kill instead of just
	// going quiet — but nothing here can cancel a cycle mid-flight, so the
	// cycle would keep running (and pushing) after being told to die, the exit
	// would be delayed by up to HEARTBEAT_TIMEOUT with the cycle lock released
	// while git children are still live, and every `docker compose restart`
	// would page whoever is on the other end of the monitor. A killed cycle
	// sends nothing and the monitor notices the gap, which is the whole point
	// of a heartbeat.
	code, ran := run()
	if ran {
		hb.send(statusFor(code), cycleMessage(code), time.Since(start))
	}
	os.Exit(int(code))
}

// run reports the cycle's exit code, and whether a cycle actually ran. A tick
// skipped because the previous one still holds the lock reports nothing:
// nothing synced, and the cycle that IS running will report for itself.
func run() (rc, bool) {
	cfg, err := configFromEnv()
	if err != nil {
		logErr("%v", err)
		return rcRetry, true
	}

	// Serialize cycles: acquire an exclusive, non-blocking lock. If a previous
	// cycle still holds it, skip this tick (not an error). The descriptor is
	// close-on-exec, so no child (git, ob) can ever inherit and hold the lock.
	lock, err := os.OpenFile(cfg.lockfile, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		logErr("cannot open lockfile %s: %v", cfg.lockfile, err)
		return rcRetry, true
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			logInfo("previous cycle still running; skipping this tick")
			return rcOK, false
		}
		logErr("cannot lock %s: %v", cfg.lockfile, err)
		return rcRetry, true
	}

	if st, err := os.Stat(cfg.repoDir); err != nil || !st.IsDir() {
		logErr("repo dir %s is missing", cfg.repoDir)
		return rcRetry, true
	}
	return (&cycle{cfg: cfg, outer: &repo{dir: cfg.repoDir}}).run(), true
}

// cycle carries the per-run state the steps share.
type cycle struct {
	cfg   config
	outer *repo
	subs  []*submodule
}

func (c *cycle) run() rc {
	// Recover from a previous cycle killed mid-operation (docker stop, power
	// loss). The flock guarantees no other git process runs against this repo,
	// so any leftover rebase state or index.lock is stale by definition.
	if !c.outer.recoverInterrupted("") {
		return rcRetry
	}

	// (a) Pull device changes down from Obsidian Sync into the working tree.
	if !obSync(c.cfg, "device pull") {
		return rcRetry
	}

	// (a') Submodules first: commit, fetch, follow the outer pointer, rebase and
	//      push each one in its own repo, so the gitlink the outer commit records
	//      already exists upstream. origin/main is fetched up front so the
	//      pointers the submodules follow are current.
	c.subs = discoverSubmodules(c.cfg)
	if len(c.subs) > 0 {
		if err := configureSubmoduleRouting(c.cfg, c.subs); err != nil {
			// Not fatal — the cycle carries on — so it must not become the
			// reason a later, unrelated failure gets reported with.
			logWarn("could not (re)write submodule ssh routing — pushes may use the wrong key: %v", err)
		}
		if !c.outer.fetchBranch("main", "") {
			return rcRetry
		}
		c.runSubmoduleCycles()
	}

	// (b) Commit local vault changes, if any.
	if !c.outer.commitWorkingTree("", c.unstageUnpushedGitlinks) {
		return rcRetry
	}

	// (c) Bring in merged skill PRs (== git pull --rebase origin main), with the
	//     network step (fetch) split from the merge step (rebase) so a network
	//     error (retry next tick) is never mistaken for a real conflict (alert).
	//     Fetched again after the submodule pre-pass on purpose: a pointer that
	//     moved meanwhile is integrated here rather than as a rejected push.
	if !c.outer.fetchBranch("main", "") {
		return rcRetry
	}

	if !c.outer.headPresent() {
		// Brand-new repo and an empty vault: nothing was committed in (b).
		if c.outer.refPresent("origin/main") {
			// Bootstrap: adopt the seeded remote content; step (e) syncs it out.
			logInfo("local repo is empty; bootstrapping the vault from origin/main")
			if err := c.outer.run("reset", "--hard", "origin/main"); err != nil {
				logErr("bootstrap from origin/main failed — deferring to next tick")
				return rcRetry
			}
		} else {
			// Nothing local, nothing remote — a successful (if empty) cycle.
			logInfo("empty vault and empty remote; nothing to sync yet")
			return c.markSuccess()
		}
	}

	preRebase, _ := c.outer.revParse("HEAD")
	if r := c.outer.rebaseOnto("origin/main", ""); r != rcOK {
		return r
	}

	// (c') Repair folders that origin/main turned into, or out of, submodules,
	//      then re-record every submodule pointer from its submodule's HEAD
	//      (following any pointer origin/main moved since the pre-pass).
	if !c.repairSubmoduleTransitions(preRebase) {
		return rcRetry
	}
	if r := c.refreshSubmodulePointers(); r != rcOK {
		return r
	}

	// (d) Publish to main.
	if r := c.outer.pushBranch("main", "", c.refreshSubmodulePointers); r != rcOK {
		return r
	}

	// (e) Propagate merged skill changes back out to devices.
	if !obSync(c.cfg, "device push") {
		return rcRetry
	}

	if r := c.submoduleExitCode(); r != rcOK {
		return r
	}
	return c.markSuccess()
}

func (c *cycle) markSuccess() rc {
	if err := os.WriteFile(c.cfg.successMarker, []byte(timestamp()+"\n"), 0o644); err != nil {
		logErr("cycle succeeded but writing %s failed (volume permissions?) — the healthcheck will go stale", c.cfg.successMarker)
		return rcRetry
	}
	logInfo("cycle complete")
	return rcOK
}
