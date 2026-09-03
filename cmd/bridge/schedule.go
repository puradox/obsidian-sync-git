package main

import (
	"os"
	"time"
)

// Adaptive polling.
//
// A full cycle is expensive — two `ob sync` round trips, a fetch, an LLM
// commit message — so it cannot be paid every minute just in case a pull
// request was merged. But asking origin whether anything HAS been merged is
// cheap: `git ls-remote` is one ssh handshake that transfers no objects. So
// supercronic ticks every POLL_INTERVAL minutes, and most ticks do nothing but
// that probe and exit. A cycle runs only when the floor interval (SYNC_INTERVAL,
// == CRON_SCHEDULE) has elapsed, or origin/main has actually moved.
//
// What this buys is latency on the GitHub -> vault leg: a merged pull request
// used to wait out CRON_SCHEDULE before reaching your devices, and now waits
// out POLL_INTERVAL. The vault -> GitHub leg is unchanged and cannot be helped
// this way — Obsidian Sync has no way to tell us a device edited a note, so
// `ob sync` IS the probe there, and it stays on the floor interval.
//
// SYNC_INTERVAL <= 0 disables all of this: every tick runs a full cycle, which
// is exactly the behaviour before adaptive polling existed.

// probeTimeout bounds the ls-remote probe. GIT_SSH_COMMAND already sets
// ConnectTimeout, but a connection that opens and then stalls has no deadline
// of its own, and a hung probe would hold the cycle lock — and this tick —
// indefinitely. Not configurable: it is one handshake, and anything close to a
// minute is already a failure worth reporting.
const probeTimeout = 60 * time.Second

// cycleTrigger is why a tick decided to run a full cycle — triggerNone when it
// decided not to. The value is the phrase logged when the cycle starts.
type cycleTrigger string

const (
	triggerNone      cycleTrigger = ""
	triggerFirst     cycleTrigger = "no previous cycle recorded"
	triggerForced    cycleTrigger = "forced with --now"
	triggerScheduled cycleTrigger = "scheduled"
	triggerRemote    cycleTrigger = "origin/main moved"
)

// decideCycle reports whether this tick should run a full cycle.
//
// Both paths key off lastAttempt, never lastSuccess. The success marker is
// only written by a cycle that succeeded, so gating the floor on it would make
// every tick after a failure read "overdue" and start another cycle: a retry
// storm at POLL_INTERVAL, each attempt burning up to two OB_SYNC_TIMEOUTs and
// pushing another `down` beat at the uptime monitor. Gating on the attempt
// reproduces exactly the pre-adaptive cadence — one try per floor interval,
// pass or fail.
//
// The remote-moved path additionally requires the previous cycle to have
// SUCCEEDED. A failed cycle may never have reached the fetch that advances
// refs/remotes/origin/main, so the probe would keep answering "moved" and
// re-trigger every tick for as long as the failure lasts. While the last cycle
// is failing, only the floor may start the next one.
func decideCycle(now, lastAttempt, lastSuccess time.Time, floor time.Duration, forced bool, probe func() (bool, error)) cycleTrigger {
	if forced {
		return triggerForced
	}
	if floor <= 0 {
		return triggerScheduled // adaptive polling off: every tick is a cycle
	}
	if lastAttempt.IsZero() {
		return triggerFirst
	}
	if now.Sub(lastAttempt) >= floor {
		return triggerScheduled
	}
	if lastSuccess.Before(lastAttempt) {
		return triggerNone
	}
	moved, err := probe()
	if err != nil {
		// Don't know, so don't act: the floor is the backstop, and a cycle
		// started on a failing probe would only fail slower and far more
		// expensively (two OB_SYNC_TIMEOUTs rather than one handshake).
		//
		// This can repeat every tick, but only while the probe fails and
		// cycles still succeed — a failure that breaks both stops the probing
		// at the lastSuccess check above after the first bad cycle.
		logWarn("could not ask origin for new commits: %v — waiting for the next tick", err)
		return triggerNone
	}
	if moved {
		return triggerRemote
	}
	return triggerNone
}

// markerTime is a marker file's modification time, or the zero time if it is
// absent. mtime rather than the ISO-8601 timestamp written inside it: nothing
// to parse, it is what healthcheck.sh already reads, and it carries sub-second
// precision — so a cycle that starts and succeeds within the same second still
// leaves lastSuccess strictly after lastAttempt.
func markerTime(path string) time.Time {
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
}
