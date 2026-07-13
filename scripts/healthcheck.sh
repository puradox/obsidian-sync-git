#!/usr/bin/env bash
# Container healthcheck: healthy iff the bridge completed a full cycle recently.
#
# bridge.sh writes an ISO-8601 timestamp to $SUCCESS_MARKER at the end of every
# successful cycle. We go unhealthy if that marker is older than the staleness
# threshold, which defaults to 2x the CRON_SCHEDULE interval (per spec).
#
# Threshold resolution:
#   1. HEALTH_STALE_SECONDS, if set.
#   2. Else, for the common "*/N * * * *" schedule, 2 * N minutes.
#   3. Else, a 1800s (30 min) default.
set -uo pipefail

SUCCESS_MARKER="${SUCCESS_MARKER:-/config/.last-success}"
CRON_SCHEDULE="${CRON_SCHEDULE:-*/15 * * * *}"

if [ -n "${HEALTH_STALE_SECONDS:-}" ]; then
  # Fail CLOSED on a malformed threshold — a non-integer would make the -gt
  # test below error out as false and report healthy forever.
  case "$HEALTH_STALE_SECONDS" in
    *[!0-9]*) echo "unhealthy: HEALTH_STALE_SECONDS must be an integer number of seconds, got '$HEALTH_STALE_SECONDS'"; exit 1 ;;
  esac
  threshold="$HEALTH_STALE_SECONDS"
elif [[ "$CRON_SCHEDULE" =~ ^\*/([0-9]+)[[:space:]] ]]; then
  threshold=$(( BASH_REMATCH[1] * 60 * 2 ))
else
  threshold=1800
fi

if [ ! -f "$SUCCESS_MARKER" ]; then
  # The HEALTHCHECK start-period (sized to the default BRIDGE_CYCLE_TIMEOUT plus
  # its kill grace) covers the pre-first-cycle window; raising the timeouts
  # requires extending start_period in compose to match.
  echo "no successful cycle yet (marker $SUCCESS_MARKER absent)"
  exit 1
fi

mtime="$(stat -c %Y "$SUCCESS_MARKER" 2>/dev/null || echo 0)"
age=$(( $(date +%s) - mtime ))

if [ "$age" -gt "$threshold" ]; then
  echo "unhealthy: last successful cycle ${age}s ago (> ${threshold}s threshold)"
  exit 1
fi

echo "healthy: last successful cycle ${age}s ago (<= ${threshold}s threshold)"
exit 0
