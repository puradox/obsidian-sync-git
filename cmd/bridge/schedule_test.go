package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A tick decides once, cheaply, whether to pay for a full cycle. These are the
// cases that decide it — including the two that exist only to stop a failing
// bridge from cycling once a minute forever.
func TestDecideCycle(t *testing.T) {
	const floor = 15 * time.Minute
	now := time.Date(2026, 8, 30, 12, 0, 0, 0, time.UTC)
	ago := func(d time.Duration) time.Time { return now.Add(-d) }

	// probe results, and a sentinel for "the probe must not be reached".
	moved := func() (cycleTrigger, error) { return triggerRemote, nil }
	subMoved := func() (cycleTrigger, error) { return "submodule Shared: origin/main moved", nil }
	unmoved := func() (cycleTrigger, error) { return triggerNone, nil }
	broken := func() (cycleTrigger, error) { return triggerNone, errors.New("ssh: connect timed out") }
	never := func() (cycleTrigger, error) {
		t.Helper()
		t.Error("probe called although the decision was already settled without it")
		return triggerNone, nil
	}

	cases := []struct {
		name        string
		lastAttempt time.Time
		lastSuccess time.Time
		floor       time.Duration
		force       bool
		probe       func() (cycleTrigger, error)
		want        cycleTrigger
	}{
		{
			name:        "--now cycles even mid-interval with nothing new",
			lastAttempt: ago(time.Minute), lastSuccess: ago(50 * time.Second),
			floor: floor, force: true, probe: never, want: triggerForced,
		},
		{
			name:        "adaptive polling off: every tick is a cycle",
			lastAttempt: ago(time.Minute), lastSuccess: ago(50 * time.Second),
			floor: 0, probe: never, want: triggerScheduled,
		},
		{
			name:  "no attempt marker yet (fresh volume)",
			floor: floor, probe: never, want: triggerFirst,
		},
		{
			name:        "floor elapsed: cycle without probing",
			lastAttempt: ago(15 * time.Minute), lastSuccess: ago(15 * time.Minute),
			floor: floor, probe: never, want: triggerScheduled,
		},
		{
			name:        "mid-interval, origin/main moved",
			lastAttempt: ago(time.Minute), lastSuccess: ago(50 * time.Second),
			floor: floor, probe: moved, want: triggerRemote,
		},
		{
			// The probe's answer names what moved, and that is what gets
			// logged: a merge into a shared folder's repo must not read as
			// a move of the vault's own origin.
			name:        "mid-interval, a submodule's remote moved",
			lastAttempt: ago(time.Minute), lastSuccess: ago(50 * time.Second),
			floor: floor, probe: subMoved, want: "submodule Shared: origin/main moved",
		},
		{
			name:        "mid-interval, nothing new: the cheap common case",
			lastAttempt: ago(time.Minute), lastSuccess: ago(50 * time.Second),
			floor: floor, probe: unmoved, want: triggerNone,
		},
		{
			name:        "probe failed: wait for the floor rather than cycle blind",
			lastAttempt: ago(time.Minute), lastSuccess: ago(50 * time.Second),
			floor: floor, probe: broken, want: triggerNone,
		},
		{
			// The failed cycle may never have reached the fetch that advances
			// origin/main, so the probe would answer "moved" every tick.
			name:        "last cycle failed: only the floor may retry",
			lastAttempt: ago(time.Minute), lastSuccess: ago(30 * time.Minute),
			floor: floor, probe: never, want: triggerNone,
		},
		{
			// mtime carries sub-second precision so this is vanishingly rare,
			// but equal markers must read as success, not failure: the other
			// way round a healthy bridge would stop responding to merges.
			name:        "attempt and success at the same instant counts as success",
			lastAttempt: ago(time.Minute), lastSuccess: ago(time.Minute),
			floor: floor, probe: moved, want: triggerRemote,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := decideCycle(now, tc.lastAttempt, tc.lastSuccess, tc.floor, tc.force, tc.probe)
			if got != tc.want {
				t.Errorf("decideCycle = %q, want %q", got, tc.want)
			}
		})
	}
}

// The probe reaches into every shared folder: a pull request merged into a
// submodule's own repository must start a cycle as promptly as one merged
// into the vault's — that repository is where such a merge lands, and the
// vault's origin/main never moves for it.
func TestProbeRemotesSubmodule(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(home, ".ssh"), 0o700); err != nil {
		t.Fatal(err)
	}

	// The vault's repository and the shared folder's, each with its own origin.
	vaultBare := filepath.Join(root, "vault.git")
	sharedBare := filepath.Join(root, "shared.git")
	git(t, root, "init", "-q", "--bare", "-b", "main", vaultBare)
	git(t, root, "init", "-q", "--bare", "-b", "main", sharedBare)

	// Seed the shared repository so the submodule has a commit to point at.
	// This clone later stands in for a merged pull request there.
	shared := filepath.Join(root, "shared")
	git(t, root, "clone", "-q", sharedBare, shared)
	commitFile(t, shared, "shared.md", "v1\n")
	git(t, shared, "push", "-q", "origin", "HEAD:main")

	// The bridge's checkout of the vault, with the folder shared the way the
	// README says: added as a submodule and merged to main. A local path is a
	// remote that needs no key, so the submodule is reachable without any.
	work := filepath.Join(root, "work")
	git(t, root, "clone", "-q", vaultBare, work)
	git(t, work, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sharedBare, "Shared")
	git(t, work, "commit", "-q", "-m", "share a folder")
	git(t, work, "push", "-q", "origin", "HEAD:main")

	cfg := config{repoDir: work, vaultDir: work, home: home}
	outer := &repo{dir: work}
	probe := func() cycleTrigger {
		t.Helper()
		got, err := probeRemotes(cfg, outer)
		if err != nil {
			t.Fatalf("probeRemotes: %v", err)
		}
		return got
	}

	if got := probe(); got != triggerNone {
		t.Fatalf("nothing merged anywhere: probe = %q, want none", got)
	}

	// A pull request merged into the shared repository: a commit that appears
	// on its origin without the bridge doing it, and without the vault's
	// origin/main moving at all.
	commitFile(t, shared, "shared.md", "v2\n")
	git(t, shared, "push", "-q", "origin", "HEAD:main")
	if got, want := probe(), cycleTrigger("submodule Shared: origin/main moved"); got != want {
		t.Fatalf("after a merge into the shared repo: probe = %q, want %q", got, want)
	}

	// The submodule's fetch — what its cycle does — is what settles it.
	sub := &repo{dir: filepath.Join(work, "Shared")}
	if !sub.fetchBranch("main", "") {
		t.Fatal("fetchBranch in the submodule failed")
	}
	if got := probe(); got != triggerNone {
		t.Fatalf("after the submodule fetched: probe = %q, want none", got)
	}

	// The vault's own origin is still asked first, and still answers for
	// itself.
	other := filepath.Join(root, "other")
	git(t, root, "clone", "-q", vaultBare, other)
	commitFile(t, other, "note.md", "hello\n")
	git(t, other, "push", "-q", "origin", "HEAD:main")
	if got := probe(); got != triggerRemote {
		t.Fatalf("after a merge into the vault repo: probe = %q, want %q", got, triggerRemote)
	}
}

func TestMarkerTime(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "nope")
	if got := markerTime(missing); !got.IsZero() {
		t.Errorf("markerTime(absent) = %v, want the zero time", got)
	}

	marker := filepath.Join(dir, ".last-attempt")
	if err := os.WriteFile(marker, []byte("whenever\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Read from the filesystem, not from the file's contents: a marker written
	// by an older image (or truncated) must still be a usable timer.
	if got := markerTime(marker); got.IsZero() {
		t.Error("markerTime(present) = zero time, want its mtime")
	}
}

func TestParseArgs(t *testing.T) {
	for _, tc := range []struct {
		args              []string
		wantForce, wantOK bool
	}{
		{nil, false, true},
		{[]string{"--now"}, true, true},
		{[]string{"--force"}, false, false},
		{[]string{"--now", "extra"}, false, false},
	} {
		force, ok := parseArgs(tc.args)
		if force != tc.wantForce || ok != tc.wantOK {
			t.Errorf("parseArgs(%q) = (%v, %v), want (%v, %v)", tc.args, force, ok, tc.wantForce, tc.wantOK)
		}
	}
}
