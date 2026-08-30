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
	moved := func() (bool, error) { return true, nil }
	unmoved := func() (bool, error) { return false, nil }
	broken := func() (bool, error) { return false, errors.New("ssh: connect timed out") }
	never := func() (bool, error) {
		t.Helper()
		t.Error("probe called although the decision was already settled without it")
		return false, nil
	}

	cases := []struct {
		name        string
		lastAttempt time.Time
		lastSuccess time.Time
		floor       time.Duration
		force       bool
		probe       func() (bool, error)
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
