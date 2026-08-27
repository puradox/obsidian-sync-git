package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// Heartbeat pushes to an external uptime monitor: Uptime Kuma's "Push" monitor
// type, and anything else shaped like it (a URL fetched to mean "still
// alive", with status/msg/ping query parameters).
//
// Why push actively instead of only going quiet: a monitor that infers trouble
// from missing beats can tell you the bridge stopped, never WHY. Pushing
// status=down with the real error means the notification it forwards names the
// failure ("ob sync (device pull) timed out after 300s ...") instead of just
// turning red. Kuma renders it as "[<monitor>] [🔴 Down] <msg>".
//
// The monitor — not the bridge — owns alerting policy: its Retries setting is
// the failure threshold, its Resend Interval the reminder cadence, its
// notification list the delivery. So this file has no thresholds of its own.
//
// THE URL IS A SECRET: for Kuma the push token is the last path segment. It is
// never logged, never followed across a redirect, and no response body is
// echoed — see safeHost, heartbeatClient and the status handling in send.
//
// Best-effort by construction: every failure here is logged and swallowed. A
// monitoring problem must never turn a good sync cycle into a failed one.
const (
	// Pushover caps a notification body at 1024 characters, and Kuma spends
	// some of that on its "[name] [status] " prefix and a trailing time line.
	// Counted in BYTES, after escaping — see truncateBytes.
	heartbeatMaxMsg = 900

	heartbeatDefaultTimeout = 10 * time.Second
)

// heartbeatClient refuses to follow redirects. The push URL's path IS the
// token, and a redirect — an SSO proxy bouncing an unauthenticated request to
// a login host with the original URL in its query, say — would hand that token
// to a different server entirely. A monitor endpoint has no reason to redirect,
// so this is a misconfiguration to report rather than something to follow.
var heartbeatClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

type heartbeat struct {
	url     string
	timeout time.Duration
}

// heartbeatFromEnv reads the configuration once, at startup, so a malformed
// value is reported before the cycle rather than in the middle of reporting
// its result.
func heartbeatFromEnv() heartbeat {
	h := heartbeat{url: os.Getenv("HEARTBEAT_URL"), timeout: heartbeatDefaultTimeout}
	if h.url == "" {
		return h
	}
	if s := os.Getenv("HEARTBEAT_TIMEOUT"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n <= 0 {
			// logWarn, not logErr: this happens before the cycle starts, so it
			// must not become the reason a later failure is reported with.
			logWarn("HEARTBEAT_TIMEOUT must be a positive integer number of seconds, got %q — using %s", s, heartbeatDefaultTimeout)
		} else {
			h.timeout = time.Duration(n) * time.Second
		}
	}
	return h
}

func (h heartbeat) enabled() bool { return h.url != "" }

// send reports one finished cycle. status is "up" or "down" — Uptime Kuma
// treats anything that is not exactly "up" as down. ping is the cycle
// duration, which the monitor graphs as its response time, giving a sync
// duration chart for free.
func (h heartbeat) send(status, msg string, dur time.Duration) {
	if !h.enabled() {
		return
	}

	u, err := url.Parse(h.url)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		// The URL itself is never logged: for Kuma the push token is IN it.
		logWarn("HEARTBEAT_URL is not a valid http(s) URL with a host — no heartbeat sent")
		return
	}
	// Append rather than re-encode the whole query: url.Values.Encode() drops
	// anything it cannot round-trip (a ';' separator, a valueless flag, a stray
	// '%'), and those belong to whoever configured the URL, not to us.
	ours := url.Values{}
	ours.Set("status", status)
	ours.Set("msg", msg)
	ours.Set("ping", strconv.FormatInt(dur.Milliseconds(), 10))
	if u.RawQuery == "" {
		u.RawQuery = ours.Encode()
	} else {
		u.RawQuery += "&" + ours.Encode()
	}

	ctx, cancel := context.WithTimeout(context.Background(), h.timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		logWarn("could not build the heartbeat request — no heartbeat sent")
		return
	}

	resp, err := heartbeatClient.Do(req)
	if err != nil {
		logWarn("heartbeat to %s failed: %v", safeHost(u), redactURLError(err))
		return
	}
	defer resp.Body.Close()

	// The response body is never logged. A misrouted request can land on a
	// server that echoes the path back ("Cannot GET /api/push/<token>"), which
	// would put the token straight into `docker logs`.
	switch {
	case resp.StatusCode == http.StatusOK:
		logInfo("heartbeat: %s (%s)", status, safeHost(u))
	case resp.StatusCode == http.StatusNotFound:
		// Kuma's answer for an unknown, deleted, or PAUSED monitor. Worth
		// naming: a paused monitor looks exactly like a healthy silent one.
		logWarn("heartbeat rejected by %s (HTTP 404) — check the push URL, and that the monitor exists and is not paused", safeHost(u))
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		logWarn("heartbeat to %s was redirected (HTTP %d) and NOT followed, because the push URL carries its token — point HEARTBEAT_URL straight at the monitor", safeHost(u), resp.StatusCode)
	default:
		logWarn("heartbeat to %s failed (HTTP %d)", safeHost(u), resp.StatusCode)
	}
}

// safeHost is the most of a heartbeat URL that may ever reach the logs: the
// path holds the push token, and userinfo would hold a password, so scheme and
// host are where it stops.
func safeHost(u *url.URL) string { return u.Scheme + "://" + u.Host }

// redactURLError strips the URL net/http embeds in its errors ("Get
// \"https://kuma/api/push/TOKEN\": dial tcp ..."), which would otherwise leak
// the push token into the logs on every failed beat.
func redactURLError(err error) error {
	var uerr *url.Error
	if errors.As(err, &uerr) {
		return uerr.Err
	}
	return err
}

// statusFor maps a cycle's exit code to the two states a push monitor has.
// Only a cycle that completed is "up": a conflict needing a human (rcConflict)
// and a transient failure (rcRetry) both mean the vault and the repo are no
// longer converging, which is what we want to be told about.
func statusFor(code rc) string {
	if code == rcOK {
		return "up"
	}
	return "down"
}

// cycleMessage is the line the monitor stores and forwards into its own
// notification, built from what the cycle logged as it ran. Everything
// relevant is included, most important first, because truncation cuts the
// tail: a message that pages someone must not open with reassuring text.
func cycleMessage(code rc) string {
	var parts []string
	switch code {
	case rcOK:
		// A submodule with no deploy key, or a conflict auto-resolved in the
		// vault's favour, both leave the cycle successful but are worth
		// carrying: they show in the monitor's history even though an up beat
		// following an up beat sends no notification.
		parts = append(parts, "cycle complete")
		if lastCommit != "" {
			parts = append(parts, lastCommit)
		}
		parts = append(parts, alerts...)
	case rcConflict:
		// Lead with the conflict that actually stopped the cycle.
		if lastConflict != "" {
			parts = append(parts, lastConflict)
		}
		for _, a := range alerts {
			if a != lastConflict {
				parts = append(parts, a)
			}
		}
		if len(parts) == 0 {
			parts = append(parts, "a conflict needs resolving upstream — sync is stopped until it is")
		}
	default:
		// Whatever failed logged the reason; anything merely worth knowing was
		// logged with logWarn and deliberately isn't a candidate here.
		if lastProblem != "" {
			parts = append(parts, lastProblem)
		}
		parts = append(parts, alerts...)
		if len(parts) == 0 {
			parts = append(parts, fmt.Sprintf("cycle failed (exit %d) — see the container logs", code))
		}
	}
	return sanitizeMsg(strings.Join(parts, " · "))
}

// sanitizeMsg makes log lines safe to hand a notification service: one line,
// escaped, and bounded. Kuma sends Pushover notifications with html=1, so a
// raw "<" in a conflicted filename could mangle or drop the alert.
//
// Escaping runs BEFORE the cut so the cap covers the escaped size — "&" grows
// five-fold, and measuring first would let an escape-heavy message sail past
// the service's limit and be rejected, which is the failure escaping exists to
// prevent.
func sanitizeMsg(s string) string {
	return truncateBytes(htmlEscaper.Replace(strings.Join(strings.Fields(s), " ")), heartbeatMaxMsg)
}

var htmlEscaper = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")

// truncateBytes cuts s to at most max BYTES — the unit notification services
// budget in — without splitting a UTF-8 rune or an HTML entity, preferring a
// word boundary. The returned string, ellipsis included, never exceeds max.
func truncateBytes(s string, max int) string {
	const ellipsis = "…"
	if max <= 0 {
		return ""
	}
	if len(s) <= max {
		return s
	}
	if max <= len(ellipsis) {
		return ""
	}
	cut := s[:max-len(ellipsis)]
	// Never end mid-rune.
	for len(cut) > 0 && !utf8.ValidString(cut) {
		cut = cut[:len(cut)-1]
	}
	// Never end inside an entity: one opened after the last ';' is unclosed,
	// and would render as literal "&amp" text.
	if amp := strings.LastIndexByte(cut, '&'); amp > strings.LastIndexByte(cut, ';') {
		cut = cut[:amp]
	}
	// Prefer a word boundary. Cutting earlier is always safe: a space can
	// never sit inside a rune or an entity.
	if sp := strings.LastIndexByte(cut, ' '); sp > len(cut)/2 {
		cut = cut[:sp]
	}
	return strings.TrimRight(cut, " ") + ellipsis
}
