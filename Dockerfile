# =============================================================================
# Absolute Valheim Server - Dockerfile
# Multi-stage build producing two artifacts from one source tree:
#
#   --target vanilla   (default)  Stock dedicated server. Uptime-first: tracks
#                                 Steam, auto-updates, no third-party runtime.
#   --target bepinex              Same image plus a pinned BepInExPack_Valheim
#                                 overlay and the disaster-response (DR) harness
#                                 armed by default (pre-update snapshots, mod
#                                 load verification, hold / rollback / safe mode).
#
# `vanilla` is the LAST stage so a bare `docker build .` still yields it.
# =============================================================================

# BepInExPack_Valheim release pinned by version AND sha256 of the Thunderstore
# zip. Bump both together (see docs/Disaster-Response.md "Bumping BepInEx").
ARG BEPINEX_VERSION=5.4.2350
ARG BEPINEX_SHA256=37a91c000b4e88f2ed7a4bd7d812239852d2e36cbf0ff0a9f5faacfba46b105f

# -----------------------------------------------------------------------------
# Stage 1: Base image with dependencies
# -----------------------------------------------------------------------------
FROM debian:bookworm-slim AS base

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    lib32gcc-s1 \
    lib32stdc++6 \
    libsdl2-2.0-0 \
    ca-certificates \
    curl \
    wget \
    procps \
    jq \
    zip \
    unzip \
    cron \
    tini \
    supervisor \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Stage 2: SteamCMD installation
# -----------------------------------------------------------------------------
FROM base AS steamcmd

# Create steamcmd directory and install
RUN mkdir -p /opt/steamcmd \
    && cd /opt/steamcmd \
    && curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" | tar zxvf - \
    && chmod +x /opt/steamcmd/steamcmd.sh \
    && /opt/steamcmd/steamcmd.sh +quit || true

# -----------------------------------------------------------------------------
# Stage 3: BepInExPack_Valheim download (bepinex target only)
# Verified against the pinned sha256 so the modded artifact is reproducible and
# a tampered/moved upstream zip fails the build instead of shipping.
# -----------------------------------------------------------------------------
FROM base AS bepinex-pack

ARG BEPINEX_VERSION
ARG BEPINEX_SHA256

RUN set -eu \
    && mkdir -p /tmp/bepinex \
    && curl -fsSL -o /tmp/bepinex/pack.zip \
        "https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/${BEPINEX_VERSION}/" \
    && echo "${BEPINEX_SHA256}  /tmp/bepinex/pack.zip" | sha256sum -c - \
    && unzip -q /tmp/bepinex/pack.zip -d /tmp/bepinex/unpacked \
    && mkdir -p /opt/valheim/bepinex \
    && cp -a /tmp/bepinex/unpacked/BepInExPack_Valheim/. /opt/valheim/bepinex/ \
    && test -f /opt/valheim/bepinex/BepInEx/core/BepInEx.Preloader.dll \
    && test -f /opt/valheim/bepinex/doorstop_libs/libdoorstop_x64.so \
    && test -f /opt/valheim/bepinex/start_server_bepinex.sh \
    && echo "${BEPINEX_VERSION}" > /opt/valheim/bepinex/.pack_version \
    && rm -rf /tmp/bepinex

# -----------------------------------------------------------------------------
# Stage 4: Shared runtime image (everything except the BepInEx overlay)
# -----------------------------------------------------------------------------
FROM base AS runtime

# Copy steamcmd from builder stage
COPY --from=steamcmd /opt/steamcmd /opt/steamcmd
COPY --from=steamcmd /root/Steam /root/Steam

# Create valheim user for running the server
RUN groupadd -g 1000 valheim \
    && useradd -u 1000 -g valheim -m -s /bin/bash valheim

# Create required directories
RUN mkdir -p /opt/valheim/server \
    && mkdir -p /config/worlds_local \
    && mkdir -p /config/backups \
    && mkdir -p /config/dr/snapshots \
    && mkdir -p /var/log/valheim \
    && mkdir -p /var/run/valheim \
    && chown -R valheim:valheim /opt/valheim \
    && chown -R valheim:valheim /config \
    && chown -R valheim:valheim /var/log/valheim \
    && chown -R valheim:valheim /var/run/valheim

# Copy scripts
COPY scripts/ /opt/valheim/scripts/

# Fix line endings (in case of Windows CRLF) and set permissions
RUN find /opt/valheim/scripts -type f -exec sed -i 's/\r$//' {} \; \
    && chmod +x /opt/valheim/scripts/*

# Copy supervisor configuration
COPY config/supervisord.conf /etc/supervisor/conf.d/valheim.conf
RUN sed -i 's/\r$//' /etc/supervisor/conf.d/valheim.conf

# Environment variables with defaults
ENV SERVER_NAME="My Valheim Server" \
    SERVER_PORT=2456 \
    WORLD_NAME="Dedicated" \
    SERVER_PASS="" \
    SERVER_PUBLIC=true \
    SERVER_ARGS="" \
    CROSSPLAY=false \
    # Update settings
    UPDATE_ON_START=true \
    UPDATE_TIMEOUT=900 \
    UPDATE_CRON="" \
    UPDATE_IF_IDLE=true \
    STEAMCMD_ARGS="validate" \
    # Backup settings
    BACKUPS_ENABLED=true \
    BACKUPS_CRON="0 * * * *" \
    BACKUPS_DIRECTORY=/config/backups \
    BACKUPS_MAX_AGE=3 \
    BACKUPS_MAX_COUNT=0 \
    BACKUPS_ZIP=true \
    BACKUPS_IF_IDLE=false \
    # Permission settings
    PUID=1000 \
    PGID=1000 \
    PERMISSIONS_UMASK=022 \
    # User management
    ADMINLIST_IDS="" \
    BANNEDLIST_IDS="" \
    PERMITTEDLIST_IDS="" \
    # System
    TZ=Etc/UTC \
    # Log filtering
    LOG_FILTER_EMPTY=true \
    LOG_FILTER_UTF8=true \
    LOG_FILTER_CONTAINS="" \
    # Disaster response (see docs/Disaster-Response.md). Vanilla keeps the
    # harness available (valheim-dr) but unarmed: no pre-update snapshots.
    VALHEIM_VARIANT=vanilla \
    DR_SNAPSHOT_BEFORE_UPDATE=false \
    DR_KEEP_SNAPSHOTS=2 \
    # BepInEx knobs are inert on vanilla; defined here so both variants share
    # one documented contract.
    BEPINEX_ENABLED=false \
    MODCHECK_STRICT=false \
    MODCHECK_TIMEOUT=300 \
    MODCHECK_EXPECT_PLUGINS="" \
    MODCHECK_FAIL_ON_ANY_ERROR=false \
    MOD_FAILURE_POLICY=hold

# Expose Valheim ports (UDP)
# 2456 - Game traffic
# 2457 - Steam server queries
# 2458 - Crossplay (PlayFab)
EXPOSE 2456/udp 2457/udp 2458/udp

# Volume mounts
# /config - Persistent data (worlds, backups, admin lists, DR snapshots, BepInEx plugins/config)
# /opt/valheim/server - Server files (can be cached)
VOLUME ["/config", "/opt/valheim/server"]

# Health check - verify server is running (and, on bepinex with MODCHECK_STRICT, that mods loaded)
HEALTHCHECK --interval=60s --timeout=10s --start-period=300s --retries=3 \
    CMD /opt/valheim/scripts/healthcheck || exit 1

# Use tini as init system for proper signal handling
ENTRYPOINT ["/usr/bin/tini", "--"]

# Start bootstrap script
CMD ["/opt/valheim/scripts/bootstrap"]

# -----------------------------------------------------------------------------
# Stage 5: bepinex artifact - runtime + pinned BepInEx overlay, DR harness armed
# -----------------------------------------------------------------------------
FROM runtime AS bepinex

ARG BEPINEX_VERSION

COPY --from=bepinex-pack --chown=valheim:valheim /opt/valheim/bepinex /opt/valheim/bepinex

RUN mkdir -p /config/bepinex/plugins /config/bepinex/config /config/bepinex/patchers \
    && chown -R valheim:valheim /config/bepinex

ENV VALHEIM_VARIANT=bepinex \
    BEPINEX_VERSION=${BEPINEX_VERSION} \
    BEPINEX_ENABLED=true \
    DR_SNAPSHOT_BEFORE_UPDATE=true \
    MODCHECK_STRICT=true

LABEL org.opencontainers.image.variant="bepinex" \
      io.absolutepower.valheim.bepinex.version="${BEPINEX_VERSION}"

# -----------------------------------------------------------------------------
# Stage 6: vanilla artifact (default target - must stay last)
# -----------------------------------------------------------------------------
FROM runtime AS vanilla

LABEL org.opencontainers.image.variant="vanilla"
