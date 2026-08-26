# syntax=docker/dockerfile:1
#
# Obsidian Sync <-> GitHub bridge.
#
# Single scheduled process: supercronic runs the bridge script on CRON_SCHEDULE.
# No continuous sync, no other long-running processes.

# --- bridge + commit-message (Go) --------------------------------------------
# Cross-compiled on the build platform so multi-arch release builds don't run
# the Go toolchain under QEMU emulation. One static binary per cmd/ directory.
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS gobuild
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags='-s -w' -o /out/ ./cmd/...

# --- runtime -----------------------------------------------------------------
FROM node:22-slim

# Non-root user; UID/GID overridable so the container can own bind-mounted volumes.
ARG UID=1000
ARG GID=1000

# obsidian-headless version is pinned for reproducibility.
ARG OB_HEADLESS_VERSION=0.0.12

# supercronic (a crontab runner that behaves in containers). Pinned version +
# per-arch SHA1 of the release assets, verified fail-closed. If you bump
# SUPERCRONIC_VERSION, update both hashes (or the build fails, which is safe).
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA1_AMD64=71b0d58cc53f6bd72cf2f293e09e294b79c666d8
ARG SUPERCRONIC_SHA1_ARM64=e0f0c06ebc5627e43b25475711e694450489ab00

# Build-time only (ARG, not ENV — it shouldn't leak into the runtime env).
ARG DEBIAN_FRONTEND=noninteractive

ENV HOME=/home/obsidian \
    NODE_ENV=production

# --- system packages, supercronic, obsidian-headless -----------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      git ca-certificates openssh-client curl jq bash util-linux coreutils procps tini; \
    \
    # supercronic
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sc_arch=amd64; sc_sha1="${SUPERCRONIC_SHA1_AMD64}" ;; \
      arm64) sc_arch=arm64; sc_sha1="${SUPERCRONIC_SHA1_ARM64}" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    sc_file="supercronic-linux-${sc_arch}"; \
    curl -fsSL --retry 3 -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/${sc_file}"; \
    echo "${sc_sha1}  /usr/local/bin/supercronic" | sha1sum -c -; \
    chmod +x /usr/local/bin/supercronic; \
    supercronic -version; \
    \
    # obsidian-headless (has a native dep, better-sqlite3). Install a build
    # toolchain so it compiles if no prebuilt binary is available, then purge it.
    apt-get install -y --no-install-recommends python3 make g++; \
    npm install -g "obsidian-headless@${OB_HEADLESS_VERSION}"; \
    # Fail-closed smoke test: a binding that installs but cannot load (e.g.
    # better-sqlite3 under QEMU) must break the build, not ship.
    ob --version; \
    apt-get purge -y --auto-remove python3 make g++; \
    \
    # non-root user. node:22-slim ships a node user at 1000:1000; free that slot
    # for the default case. Then create the obsidian user at the requested
    # UID/GID, tolerating collisions so the build works for ANY host-matched
    # UID/GID: reuse an existing group if the GID is taken, and allow a
    # non-unique UID (-o) if the UID is already assigned to a base-image account.
    userdel -r node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    getent group "${GID}" >/dev/null || groupadd -g "${GID}" obsidian; \
    useradd -o -u "${UID}" -g "${GID}" -m -d "${HOME}" -s /bin/bash obsidian; \
    \
    mkdir -p /vault /config /opt/bridge; \
    chown -R "${UID}:${GID}" /vault /config "${HOME}"; \
    \
    npm cache clean --force; \
    rm -rf /var/lib/apt/lists/* /tmp/*

# --- bridge scripts + static assets ----------------------------------------
COPY --chmod=0755 scripts/entrypoint.sh      /usr/local/bin/entrypoint.sh
COPY --from=gobuild --chmod=0755 /out/bridge         /usr/local/bin/bridge
COPY --from=gobuild --chmod=0755 /out/commit-message /usr/local/bin/commit-message
COPY --chmod=0755 scripts/healthcheck.sh     /usr/local/bin/healthcheck.sh
COPY scripts/vault.gitignore                 /opt/bridge/vault.gitignore
COPY github_known_hosts                      /opt/bridge/github_known_hosts

# Shared runtime env. Set here (not just exported by the entrypoint) so that
# `docker exec` shells and the HEALTHCHECK — which never see entrypoint
# exports — resolve the same state paths and schedule as the bridge itself.
ENV XDG_CONFIG_HOME=/config \
    SUCCESS_MARKER=/config/.last-success \
    CRON_SCHEDULE="*/15 * * * *"

USER obsidian
WORKDIR /vault

VOLUME ["/vault", "/config"]

# Unhealthy if no bridge cycle has succeeded within the staleness threshold
# (2x the cron interval for */N schedules, else 1800s, or HEALTH_STALE_SECONDS).
# start-period must cover the RUN_ON_START initial cycle, which may run for the
# default BRIDGE_CYCLE_TIMEOUT (900s) plus the 30s kill grace; anyone raising
# OB_SYNC_TIMEOUT/BRIDGE_CYCLE_TIMEOUT should extend start_period in compose too.
HEALTHCHECK --interval=5m --timeout=10s --start-period=16m --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

# tini reaps the git/ob child processes supercronic spawns.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
