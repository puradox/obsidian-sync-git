package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

const testToken = "AbCdEf1234SUPERSECRET"

// resetCycleLog clears the state cycleMessage reads, so one test's logging
// can't leak into the next.
func resetCycleLog(t *testing.T) {
	t.Helper()
	clear := func() { lastProblem, lastConflict, lastCommit, alerts = "", "", "", nil }
	clear()
	t.Cleanup(clear)
}

// captureLogs runs fn with the bridge's log destinations redirected, and
// returns everything it printed. The log functions write to os.Stdout/os.Stderr
// directly, so the files themselves are swapped.
func captureLogs(t *testing.T, fn func()) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "log")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	outOrig, errOrig := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = f, f
	defer func() { os.Stdout, os.Stderr = outOrig, errOrig }()
	fn()
	b, err := os.ReadFile(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// monitor is a stub uptime monitor. It records the beats it receives, and
// replies with whatever the test needs.
type monitor struct {
	srv   *httptest.Server
	beats []url.Values
	raw   []string // the query exactly as it arrived; re-encoding is lossy
	reqs  int
}

func newMonitor(t *testing.T, handle func(w http.ResponseWriter, r *http.Request)) *monitor {
	t.Helper()
	m := &monitor{}
	m.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.reqs++
		m.beats = append(m.beats, r.URL.Query())
		m.raw = append(m.raw, r.URL.RawQuery)
		if handle != nil {
			handle(w, r)
			return
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"ok":true}`)
	}))
	t.Cleanup(m.srv.Close)
	return m
}

func (m *monitor) pushURL() string { return m.srv.URL + "/api/push/" + testToken }

func (m *monitor) last(t *testing.T) url.Values {
	t.Helper()
	if len(m.beats) == 0 {
		t.Fatal("no beat reached the monitor")
	}
	return m.beats[len(m.beats)-1]
}

// --- sending -----------------------------------------------------------------

func TestHeartbeatDisabledSendsNothing(t *testing.T) {
	resetCycleLog(t)
	m := newMonitor(t, nil)
	var h heartbeat // no URL: the bridge must behave exactly as it did before
	if h.enabled() {
		t.Fatal("a heartbeat with no URL reports itself enabled")
	}
	out := captureLogs(t, func() { h.send("up", "cycle complete", time.Second) })
	if m.reqs != 0 {
		t.Errorf("a disabled heartbeat made %d request(s)", m.reqs)
	}
	if out != "" {
		t.Errorf("a disabled heartbeat logged %q", out)
	}
}

func TestHeartbeatSendsStatusMsgAndPing(t *testing.T) {
	resetCycleLog(t)
	m := newMonitor(t, nil)
	h := heartbeat{url: m.pushURL(), timeout: 5 * time.Second}
	captureLogs(t, func() { h.send("up", "cycle complete", 1500*time.Millisecond) })

	q := m.last(t)
	if got := q.Get("status"); got != "up" {
		t.Errorf("status = %q, want up", got)
	}
	if got := q.Get("msg"); got != "cycle complete" {
		t.Errorf("msg = %q", got)
	}
	// Kuma graphs ping as the monitor's response time, so it must be the
	// cycle duration in milliseconds.
	if got := q.Get("ping"); got != "1500" {
		t.Errorf("ping = %q, want 1500", got)
	}
}

func TestHeartbeatKeepsExistingQueryParams(t *testing.T) {
	resetCycleLog(t)
	// url.Values.Encode() silently drops these; appending preserves them.
	for _, existing := range []string{"token=abc", "a=1;b=2", "flag", "%zz=1&ok=2"} {
		t.Run(existing, func(t *testing.T) {
			m := newMonitor(t, nil)
			h := heartbeat{url: m.pushURL() + "?" + existing, timeout: 5 * time.Second}
			captureLogs(t, func() { h.send("down", "boom", time.Second) })

			if got := m.last(t).Get("status"); got != "down" {
				t.Errorf("status = %q, want down", got)
			}
			// The caller's own parameters must still be on the wire, verbatim.
			raw := m.raw[len(m.raw)-1]
			if !strings.Contains(raw, existing) {
				t.Errorf("configured query %q was lost; got %q", existing, raw)
			}
		})
	}
}

// A monitor that is unreachable, or rejects the beat, must never fail the
// cycle — these are the paths that would otherwise turn a monitoring outage
// into a sync outage. Each case must also stay silent about the token.
func TestHeartbeatSwallowsFailuresWithoutLeaking(t *testing.T) {
	cases := map[string]heartbeat{
		"unreachable host": {url: "http://127.0.0.1:1/api/push/" + testToken, timeout: time.Second},
		"not an http url":  {url: "file:///etc/" + testToken, timeout: time.Second},
		"unparseable url":  {url: "://nope/" + testToken, timeout: time.Second},
		"no host":          {url: "http:///" + testToken, timeout: time.Second},
	}
	for name, h := range cases {
		t.Run(name, func(t *testing.T) {
			resetCycleLog(t)
			out := captureLogs(t, func() { h.send("up", "cycle complete", time.Second) })
			if out == "" {
				t.Error("failure was silent; it should be logged")
			}
			if strings.Contains(out, testToken) {
				t.Errorf("the push token leaked into the logs: %q", out)
			}
			// A failed beat must not become the cycle's reported cause.
			if lastProblem != "" {
				t.Errorf("a heartbeat failure was captured as the cycle's cause: %q", lastProblem)
			}
		})
	}
}

// The 404 body Kuma returns is not echoed, and neither is anything else: a
// misrouted request can land on a server that prints the path back.
func TestHeartbeatNeverEchoesTheResponseBody(t *testing.T) {
	for _, code := range []int{http.StatusNotFound, http.StatusInternalServerError} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			resetCycleLog(t)
			m := newMonitor(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(code)
				// What Express, Flask and Django-with-DEBUG all do.
				fmt.Fprintf(w, "Cannot GET %s", r.URL.Path)
			})
			h := heartbeat{url: m.pushURL(), timeout: 5 * time.Second}
			out := captureLogs(t, func() { h.send("up", "cycle complete", time.Second) })
			if strings.Contains(out, testToken) {
				t.Errorf("the response body leaked the push token: %q", out)
			}
			if !strings.Contains(out, fmt.Sprint(code)) {
				t.Errorf("the status code should still be reported: %q", out)
			}
		})
	}
}

// A redirect must not be followed: it would hand the token to another host.
func TestHeartbeatRefusesRedirects(t *testing.T) {
	resetCycleLog(t)
	elsewhere := newMonitor(t, nil)
	m := newMonitor(t, func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.srv.URL+r.URL.Path, http.StatusFound)
	})
	h := heartbeat{url: m.pushURL(), timeout: 5 * time.Second}
	out := captureLogs(t, func() { h.send("up", "cycle complete", time.Second) })

	if elsewhere.reqs != 0 {
		t.Errorf("the redirect was followed: the token reached a second host %d time(s)", elsewhere.reqs)
	}
	if !strings.Contains(out, "redirected") {
		t.Errorf("a refused redirect should be reported: %q", out)
	}
	if strings.Contains(out, testToken) {
		t.Errorf("token leaked: %q", out)
	}
}

// --- redaction ---------------------------------------------------------------

// Built by hand rather than by provoking net/http, so the assertion can never
// silently turn into a skip if Go changes its error text.
func TestRedactURLErrorStripsTheURL(t *testing.T) {
	err := &url.Error{
		Op:  "Get",
		URL: "https://kuma.example.com/api/push/" + testToken,
		Err: fmt.Errorf("dial tcp 10.0.0.1:443: connect: connection refused"),
	}
	if !strings.Contains(err.Error(), testToken) {
		t.Fatal("test is not exercising redaction: the token is not in the error")
	}
	if got := redactURLError(err).Error(); strings.Contains(got, testToken) {
		t.Errorf("redactURLError leaked the token: %q", got)
	}
}

func TestSafeHostDropsPathQueryAndUserinfo(t *testing.T) {
	u, err := url.Parse("https://user:hunter2@kuma.example.com/api/push/" + testToken + "?status=up")
	if err != nil {
		t.Fatal(err)
	}
	got := safeHost(u)
	if got != "https://kuma.example.com" {
		t.Errorf("safeHost = %q", got)
	}
	for _, secret := range []string{testToken, "hunter2", "user"} {
		if strings.Contains(got, secret) {
			t.Errorf("safeHost leaked %q: %q", secret, got)
		}
	}
}

// --- outcome -> beat ----------------------------------------------------------

func TestStatusFor(t *testing.T) {
	// Only a completed cycle is up: a conflict needing a human and a transient
	// failure both mean the vault and the repo are no longer converging.
	for code, want := range map[rc]string{rcOK: "up", rcRetry: "down", rcConflict: "down"} {
		if got := statusFor(code); got != want {
			t.Errorf("statusFor(%d) = %q, want %q", code, got, want)
		}
	}
}

func TestCycleMessage(t *testing.T) {
	t.Run("success carries the commit subject", func(t *testing.T) {
		resetCycleLog(t)
		lastCommit = "Add Q3 planning notes"
		if got := cycleMessage(rcOK); got != "cycle complete · Add Q3 planning notes" {
			t.Errorf("got %q", got)
		}
	})

	t.Run("every alert survives, not just the last", func(t *testing.T) {
		resetCycleLog(t)
		// A cycle routinely raises several; reporting one silently discarded
		// the rest, including the one the README promises.
		logAlert("conflict auto-resolved: your note in a.md overrode a merged change")
		logAlert("submodule skills: no deploy key")
		got := cycleMessage(rcOK)
		for _, want := range []string{"a.md", "no deploy key"} {
			if !strings.Contains(got, want) {
				t.Errorf("alert mentioning %q was dropped: %q", want, got)
			}
		}
	})

	t.Run("failure names the last problem", func(t *testing.T) {
		resetCycleLog(t)
		logErr("ob sync (device pull) timed out after 300s")
		if got := cycleMessage(rcRetry); !strings.HasPrefix(got, "ob sync (device pull) timed out") {
			t.Errorf("got %q", got)
		}
	})

	t.Run("logWarn is never reported as the cause", func(t *testing.T) {
		resetCycleLog(t)
		logErr("git fetch failed (network?) — deferring to next tick")
		// A summary of what was already logged, emitted after the real error.
		logWarn("1-class failure in submodule skills this cycle (see above)")
		got := cycleMessage(rcRetry)
		if strings.Contains(got, "see above") {
			t.Errorf("a summary masked the real cause: %q", got)
		}
		if !strings.Contains(got, "git fetch failed") {
			t.Errorf("the real cause was lost: %q", got)
		}
	})

	t.Run("a down beat never opens with reassuring text", func(t *testing.T) {
		resetCycleLog(t)
		// Order matters: the conflict that stopped the cycle is logged first,
		// then a milder alert from a different submodule.
		logConflictAlert("submodule A: rebase conflict that could NOT be auto-resolved")
		logAlert("submodule B: conflict auto-resolved in favour of the vault, so sync continues")
		got := cycleMessage(rcConflict)
		if !strings.HasPrefix(got, "submodule A: rebase conflict that could NOT") {
			t.Errorf("the page did not lead with the conflict that stopped the cycle: %q", got)
		}
	})

	t.Run("a silent failure still says something", func(t *testing.T) {
		resetCycleLog(t)
		if got := cycleMessage(rcRetry); !strings.Contains(got, "exit 1") {
			t.Errorf("got %q", got)
		}
	})
}

// --- sanitizing ---------------------------------------------------------------

func TestSanitizeMsg(t *testing.T) {
	t.Run("collapses to one line", func(t *testing.T) {
		if got := sanitizeMsg("two\nlines   spaced"); got != "two lines spaced" {
			t.Errorf("got %q", got)
		}
	})

	t.Run("escapes what an html parser would act on", func(t *testing.T) {
		// Kuma sends Pushover notifications with html=1, so a conflicted file
		// named with angle brackets could otherwise mangle or drop the alert.
		got := sanitizeMsg(`conflict in <draft> & "notes"`)
		if strings.ContainsAny(got, "<>") {
			t.Errorf("unescaped angle bracket survived: %q", got)
		}
		if !strings.Contains(got, "&amp;") || !strings.Contains(got, "&lt;draft&gt;") {
			t.Errorf("got %q", got)
		}
		// Quotes are left alone: they need no escaping in a body, and entities
		// would just make filenames unreadable.
		if !strings.Contains(got, `"notes"`) {
			t.Errorf("quotes were escaped unnecessarily: %q", got)
		}
	})

	// The cap must hold AFTER escaping: "&" grows five-fold, so measuring
	// before it let an escape-heavy message sail past the service's limit.
	t.Run("the cap holds for input that escaping inflates", func(t *testing.T) {
		for name, in := range map[string]string{
			"plain":       strings.Repeat("alpha ", 400),
			"ampersands":  strings.Repeat("&", 2000),
			"angles":      strings.Repeat("<x> ", 500),
			"cjk":         strings.Repeat("計画", 500),
			"mixed":       strings.Repeat("a&b<c> ", 300),
			"no spaces":   strings.Repeat("x", 3000),
			"all spaces":  strings.Repeat(" ", 3000),
			"exactly cap": strings.Repeat("y", heartbeatMaxMsg),
		} {
			got := sanitizeMsg(in)
			if len(got) > heartbeatMaxMsg {
				t.Errorf("%s: %d bytes exceeds the %d-byte cap", name, len(got), heartbeatMaxMsg)
			}
		}
	})

	t.Run("truncation never splits a rune or an entity", func(t *testing.T) {
		for name, in := range map[string]string{
			"ampersands": strings.Repeat("&", 2000),
			"cjk":        strings.Repeat("計画", 500),
			"mixed":      strings.Repeat("a&b<c> ", 300),
		} {
			got := strings.TrimSuffix(sanitizeMsg(in), "…")
			if !utf8.ValidString(got) {
				t.Errorf("%s: truncation split a rune: %q", name, got)
			}
			// Every fragment after an '&' must close its entity with a ';'.
			for i, frag := range strings.Split(got, "&")[1:] {
				if !strings.Contains(frag, ";") {
					t.Errorf("%s: entity %d left unterminated by the cut: %q", name, i, frag)
				}
			}
		}
	})

	t.Run("a cut is marked", func(t *testing.T) {
		if got := sanitizeMsg(strings.Repeat("alpha ", 400)); !strings.HasSuffix(got, "…") {
			t.Errorf("truncated message is not marked as cut: %q", got)
		}
	})
}

func TestTruncateBytesEdgeCases(t *testing.T) {
	for _, max := range []int{-1, 0, 1, 2, 3} {
		got := truncateBytes("some long string here", max)
		if len(got) > max && max > 0 {
			t.Errorf("max=%d produced %d bytes: %q", max, len(got), got)
		}
	}
	if got := truncateBytes("short", 100); got != "short" {
		t.Errorf("an under-cap string was altered: %q", got)
	}
}

// --- config -------------------------------------------------------------------

func TestHeartbeatFromEnv(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		t.Setenv("HEARTBEAT_URL", "https://kuma.example.com/api/push/tok")
		t.Setenv("HEARTBEAT_TIMEOUT", "")
		if got := heartbeatFromEnv(); got.timeout != heartbeatDefaultTimeout {
			t.Errorf("timeout = %s", got.timeout)
		}
	})

	t.Run("a bad timeout warns and falls back", func(t *testing.T) {
		// Must agree with entrypoint.sh, which rejects the same values.
		for _, bad := range []string{"not-a-number", "0", "00", "-5", "5s", ""} {
			resetCycleLog(t)
			t.Setenv("HEARTBEAT_URL", "https://kuma.example.com/api/push/tok")
			t.Setenv("HEARTBEAT_TIMEOUT", bad)
			var h heartbeat
			captureLogs(t, func() { h = heartbeatFromEnv() })
			if h.timeout != heartbeatDefaultTimeout {
				t.Errorf("%q: timeout = %s, want the default", bad, h.timeout)
			}
			// A startup warning must not become a cycle's reported cause.
			if lastProblem != "" {
				t.Errorf("%q: startup warning captured as a cause: %q", bad, lastProblem)
			}
		}
	})

	t.Run("a good timeout is used", func(t *testing.T) {
		t.Setenv("HEARTBEAT_URL", "https://kuma.example.com/api/push/tok")
		t.Setenv("HEARTBEAT_TIMEOUT", "25")
		if got := heartbeatFromEnv(); got.timeout != 25*time.Second {
			t.Errorf("timeout = %s", got.timeout)
		}
	})

	t.Run("no url means disabled", func(t *testing.T) {
		t.Setenv("HEARTBEAT_URL", "")
		if heartbeatFromEnv().enabled() {
			t.Error("enabled with no URL")
		}
	})
}
