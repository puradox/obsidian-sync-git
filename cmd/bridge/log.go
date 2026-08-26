package main

import (
	"fmt"
	"os"
	"time"
)

// Log lines keep bridge.sh's exact shape so `docker logs` consumers and the
// end-to-end test see no difference between the two implementations:
//
//	[bridge <ts>] message              (stdout)
//	[bridge <ts>] !! message           (stderr; a failure to act on)
//	[bridge <ts>] !!!! ALERT: message  (stderr; something the user must see)

func timestamp() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

func logInfo(format string, args ...any) {
	fmt.Fprintf(os.Stdout, "[bridge %s] %s\n", timestamp(), fmt.Sprintf(format, args...))
}

func logErr(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[bridge %s] !! %s\n", timestamp(), fmt.Sprintf(format, args...))
}

func logAlert(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[bridge %s] !!!! ALERT: %s\n", timestamp(), fmt.Sprintf(format, args...))
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
