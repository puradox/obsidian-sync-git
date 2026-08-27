package main

import (
	"fmt"
	"os"
	"time"
)

// Log line shapes (the end-to-end test greps for them; `docker logs`
// consumers may too):
//
//	[bridge <ts>] message              (stdout)
//	[bridge <ts>] !! message           (stderr; a failure to act on)
//	[bridge <ts>] !!!! ALERT: message  (stderr; something the user must see)

func timestamp() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

// What the cycle logged, kept so the heartbeat can report WHY it ended the way
// it did rather than only that it did (see heartbeat.go). Written and read from
// the single goroutine that runs the cycle.
var (
	lastProblem  string   // most recent logErr
	alerts       []string // every logAlert this cycle, in order
	lastConflict string   // the alert for a conflict that ended the cycle
	lastCommit   string   // subject of the commit the outer repo made, if any
)

func logInfo(format string, args ...any) {
	fmt.Fprintf(os.Stdout, "[bridge %s] %s\n", timestamp(), fmt.Sprintf(format, args...))
}

func logErr(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	lastProblem = msg
	fmt.Fprintf(os.Stderr, "[bridge %s] !! %s\n", timestamp(), msg)
}

// logWarn is logErr's non-capturing sibling: a problem worth printing that is
// NOT a candidate explanation for how the cycle ended — a summary of failures
// already logged individually above, or a warning the cycle then carried on
// past. Keeping these out of lastProblem is what stops the heartbeat reporting
// a placeholder like "see above" in place of the actual cause.
func logWarn(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[bridge %s] !! %s\n", timestamp(), fmt.Sprintf(format, args...))
}

// logAlert is something the user must see. Every alert is kept, not just the
// last: a cycle routinely raises several (an auto-resolved conflict in the
// vault AND a submodule with no deploy key), and dropping all but one would
// silently discard the very thing the notification exists to carry.
func logAlert(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	alerts = append(alerts, msg)
	fmt.Fprintf(os.Stderr, "[bridge %s] !!!! ALERT: %s\n", timestamp(), msg)
}

// logConflictAlert is logAlert for a conflict that ENDS the cycle (rcConflict).
// Recorded apart from the rest so a milder alert logged afterwards — a
// submodule with no deploy key, say — can never become the body of the
// notification that pages someone, saying sync carried on when it did not.
func logConflictAlert(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	lastConflict = msg
	logAlert("%s", msg)
}

// ctxOn renders a step label the way the script's `${ctx:+ on $ctx}` did, so
// messages read "git fetch failed on submodule X" or just "git fetch failed".
func ctxOn(ctx string) string  { return ctxWith(" on ", ctx) }
func ctxIn(ctx string) string  { return ctxWith(" in ", ctx) }
func ctxFor(ctx string) string { return ctxWith(" for ", ctx) }
func ctxSp(ctx string) string  { return ctxWith(" ", ctx) }

func ctxWith(sep, ctx string) string {
	if ctx == "" {
		return ""
	}
	return sep + ctx
}

// ctxOr is `${ctx:-vault}`.
func ctxOr(ctx string) string {
	if ctx == "" {
		return "vault"
	}
	return ctx
}

func short(sha string) string {
	if len(sha) > 12 {
		return sha[:12]
	}
	return sha
}
