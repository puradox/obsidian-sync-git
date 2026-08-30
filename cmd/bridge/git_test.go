package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// git runs a git command in dir and fails the test if it does not succeed.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(cmd.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
	}
	return string(out)
}

func commitFile(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "add", "-A")
	git(t, dir, "commit", "-q", "-m", "add "+name)
}

// The adaptive-polling probe, against a real remote. The property that matters
// most is the last one: the bridge's own push must not look like a change, or
// every push would trigger another cycle a minute later.
func TestRemoteMoved(t *testing.T) {
	root := t.TempDir()
	bare := filepath.Join(root, "origin.git")
	git(t, root, "init", "-q", "--bare", "-b", "main", bare)

	work := filepath.Join(root, "work")
	git(t, root, "clone", "-q", bare, work)
	w := &repo{dir: work}

	// An empty remote is not "moved": there is nothing to pull, and a cycle
	// would have no work to do.
	if moved, err := w.remoteMoved("main", probeTimeout); err != nil || moved {
		t.Fatalf("empty remote: moved = %v, err = %v; want false, nil", moved, err)
	}

	// Seed origin from a second clone — this stands in for a merged pull
	// request: a commit that appears on origin without the bridge doing it.
	other := filepath.Join(root, "other")
	git(t, root, "clone", "-q", bare, other)
	commitFile(t, other, "note.md", "hello\n")
	git(t, other, "push", "-q", "origin", "HEAD:main")

	// Our clone has never fetched it, so there is something new to pull.
	if moved, err := w.remoteMoved("main", probeTimeout); err != nil || !moved {
		t.Fatalf("after an upstream push: moved = %v, err = %v; want true, nil", moved, err)
	}

	// Fetching is what settles it: the tracking ref now matches origin.
	if !w.fetchBranch("main", "") {
		t.Fatal("fetchBranch failed")
	}
	if moved, err := w.remoteMoved("main", probeTimeout); err != nil || moved {
		t.Fatalf("after fetching: moved = %v, err = %v; want false, nil", moved, err)
	}

	// Our OWN push must not read as a change. A successful push advances
	// refs/remotes/origin/main, so the next probe compares equal without the
	// bridge having to remember what it published.
	git(t, work, "reset", "--hard", "-q", "origin/main")
	commitFile(t, work, "vault.md", "from the vault\n")
	if r := w.pushBranch("main", "", nil); r != rcOK {
		t.Fatalf("pushBranch = %v, want rcOK", r)
	}
	if moved, err := w.remoteMoved("main", probeTimeout); err != nil || moved {
		t.Fatalf("after our own push: moved = %v, err = %v; want false, nil", moved, err)
	}
}

// A probe that cannot reach its remote must report an error, never a quiet
// "nothing changed" — the two lead to different decisions on the tick.
func TestRemoteHeadUnreachable(t *testing.T) {
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main", dir)
	git(t, dir, "remote", "add", "origin", filepath.Join(dir, "does-not-exist.git"))

	r := &repo{dir: dir}
	if _, err := r.remoteHead("main", 30*time.Second); err == nil {
		t.Error("remoteHead on a missing remote returned no error")
	}
	if _, err := r.remoteMoved("main", 30*time.Second); err == nil {
		t.Error("remoteMoved on a missing remote returned no error")
	}
}

func TestLastLine(t *testing.T) {
	cases := map[string]string{
		"":                      "",
		"  \n \n":               "",
		"one":                   "one",
		"one\ntwo\n":            "two",
		"fatal: nope\n\n\n":     "fatal: nope",
		"warn\nfatal: really\n": "fatal: really",
	}
	for in, want := range cases {
		if got := lastLine(in); got != want {
			t.Errorf("lastLine(%q) = %q, want %q", in, got, want)
		}
	}
}
