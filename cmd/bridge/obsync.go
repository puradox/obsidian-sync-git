package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// obSync runs one one-shot `ob sync`, hard-bounded by a timeout.
// obsidian-headless has no client-side timeout on its sync-server connection:
// a stalled data socket (seen in the wild as a sync.log that stops at
// "Connecting..." right after "Starting sync") hangs the CLI indefinitely.
// Unbounded, that one hang would wedge the whole cycle, so a stalled sync is
// sent SIGTERM at the deadline and SIGKILL after a grace period, and treated
// like any other failure: defer and retry next tick. The lock descriptor is
// close-on-exec, so even an `ob` that lingers past its parent can never keep
// the cycle lock held. stdin is /dev/null so the CLI can never block on an
// interactive prompt.
func obSync(cfg config, phase string) bool {
	logInfo("ob sync (%s)", phase)
	ctx, cancel := context.WithTimeout(context.Background(), cfg.obSyncTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ob", "sync", "--path", cfg.vaultDir)
	cmd.Stdin = nil
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = 30 * time.Second
	err := cmd.Run()
	if err == nil {
		return true
	}
	secs := int(cfg.obSyncTimeout / time.Second)
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		if cmd.ProcessState != nil && cmd.ProcessState.Sys().(syscall.WaitStatus).Signal() == syscall.SIGKILL {
			logErr("ob sync (%s) ignored the timeout and was SIGKILLed after the grace period — deferring to next tick", phase)
		} else {
			logErr("ob sync (%s) timed out after %ds (stalled sync-server connection?) — killed; deferring to next tick", phase, secs)
		}
		return false
	}
	var exitErr *exec.ExitError
	code := -1
	if errors.As(err, &exitErr) {
		code = exitErr.ExitCode()
	}
	switch code {
	case 1:
		logErr("ob sync (%s) failed (exit 1): network error / another sync running / sync-engine error", phase)
	case 2:
		logErr("ob sync (%s) failed (exit 2): encryption key missing — re-run sync-setup", phase)
	case 3:
		logErr("ob sync (%s) failed (exit 3): no sync configuration for %s", phase, cfg.vaultDir)
	case -1:
		logErr("ob sync (%s) failed: %v", phase, err)
	default:
		logErr("ob sync (%s) failed (exit %d)", phase, code)
	}
	return false
}
