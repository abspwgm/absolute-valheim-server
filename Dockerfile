# =============================================================================
# Absolute Valheim Server - Dockerfile
# Multi-stage build for containerized Valheim dedicated server
# =============================================================================

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
# Stage 3: Final runtime image
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
    LOG_FILTER_CONTAINS=""

# Expose Valheim ports (UDP)
# 2456 - Game traffic
# 2457 - Steam server queries
# 2458 - Crossplay (PlayFab)
EXPOSE 2456/udp 2457/udp 2458/udp

# Volume mounts
# /config - Persistent data (worlds, backups, admin lists)
# /opt/valheim/server - Server files (can be cached)
VOLUME ["/config", "/opt/valheim/server"]

# Health check - verify server is responding
HEALTHCHECK --interval=60s --timeout=10s --start-period=300s --retries=3 \
    CMD /opt/valheim/scripts/healthcheck || exit 1

# Use tini as init system for proper signal handling
ENTRYPOINT ["/usr/bin/tini", "--"]

# Start bootstrap script
CMD ["/opt/valheim/scripts/bootstrap"]
