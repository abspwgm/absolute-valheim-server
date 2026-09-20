# Absolute Valheim Server

[![E2E Tests](https://github.com/abspwgm/absolute-valheim-server/actions/workflows/e2e.yml/badge.svg)](https://github.com/abspwgm/absolute-valheim-server/actions/workflows/e2e.yml)
[![BepInEx Artifact](https://github.com/abspwgm/absolute-valheim-server/actions/workflows/bepinex.yml/badge.svg)](https://github.com/abspwgm/absolute-valheim-server/actions/workflows/bepinex.yml)
[![Docker Image](https://github.com/abspwgm/absolute-valheim-server/actions/workflows/publish.yml/badge.svg)](https://github.com/abspwgm/absolute-valheim-server/actions/workflows/publish.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/fireaimready/absolute-valheim-server)](https://hub.docker.com/r/fireaimready/absolute-valheim-server)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

New to hosting? Start with the [step-by-step install guide](docs/INSTALL.md).

A production-ready, containerized Valheim dedicated server with automatic updates, backups, log filtering, and comprehensive end-to-end testing. Ships as two artifacts: a stock **vanilla** image built for uptime, and a **BepInEx** image with a pinned mod loader and a disaster-response harness for the day a Valheim patch breaks your mods.

## Features

- **Docker-based deployment** - Easy setup with Docker Compose
- **Two artifacts, one source** - `vanilla` (uptime-first) and `bepinex` (modded, DR-armed); see [Image variants](#image-variants)
- **Auto-updates on startup** - Server files automatically update on container start/restart
- **Automated backups** - Scheduled world backups with retention policies
- **Disaster response for modded servers** - Pre-update snapshots, mod-load verification, hold / rollback / safe mode, nightly canary; see [docs/Disaster-Response.md](docs/Disaster-Response.md)
- **Log filtering** - Clean, readable logs with noise filtering
- **E2E tested** - Comprehensive automated test suite, including disaster drills
- **Non-root execution** - Configurable UID/GID for security
- **Systemd support** - Native Linux service for non-Docker deployments
- **Fully configurable** - All settings via environment variables

## Image variants

| Tag | Target | What you get | Pipeline |
|---|---|---|---|
| `latest`, `vanilla`, `1.2.3`, `sha-…` | `vanilla` | Stock dedicated server. Tracks Steam, auto-updates, no third-party runtime. The DR CLI is present but unarmed. | `e2e.yml` gates, `publish.yml` publishes |
| `bepinex`, `latest-bepinex`, `bepinex-5.4.2350`, `steam-<build>-bepinex`, `sha-…-bepinex` | `bepinex` | Vanilla + [BepInExPack_Valheim](https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/) pinned by version **and** sha256, plugins persisted under `/config/bepinex`, DR harness armed (snapshot before updates, mod-load health check, `MOD_FAILURE_POLICY`). | `bepinex.yml` tests, publishes and runs the nightly canary |

The pipelines are independent: a mod-side breakage after a Valheim update can never block a vanilla release. Build locally with `docker build --target bepinex .` or `VALHEIM_VARIANT=bepinex docker compose up -d --build`.

Running both servers on one host? Start from [deploy/proxmox/docker-compose.yml](deploy/proxmox/docker-compose.yml).

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (20.10+)
- [Docker Compose](https://docs.docker.com/compose/install/) (v2.0+)
- Minimum 4GB RAM, 2 CPU cores, 10GB disk space

### 1. Create a docker-compose.yml

Create a new directory for your server and add a `docker-compose.yml` file:

```yaml
services:
  valheim:
    image: fireaimready/absolute-valheim-server:latest
    container_name: valheim-server

    environment:
      # Server settings (customize these)
      - SERVER_NAME=My Valheim Server
      - WORLD_NAME=Dedicated
      - SERVER_PASS=changeme123
      - SERVER_PUBLIC=true

      # Update settings
      - UPDATE_ON_START=true

      # Backup settings
      - BACKUPS_ENABLED=true
      - BACKUPS_CRON=0 * * * *

      # Permissions (match to your host user)
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC

    ports:
      - "2456:2456/udp"
      - "2457:2457/udp"
      - "2458:2458/udp"

    volumes:
      - ./data/config:/config
      - ./data/server:/opt/valheim/server

    stop_grace_period: 2m
    restart: unless-stopped
```

### 2. Configure Your Server

Edit the environment variables in your `docker-compose.yml`:

- `SERVER_NAME` - Your server's display name
- `SERVER_PASS` - Server password (minimum 5 characters)
- `WORLD_NAME` - Name of your world save file

### 3. Start the Server

```bash
docker compose up -d
```

### 4. View Logs

```bash
docker compose logs -f
```

The server will:
1. Download/update Valheim server files via SteamCMD
2. Start the dedicated server
3. Connect to Steam for server browser listing

**First startup may take 5-15 minutes** while downloading server files (~1GB).

## Connecting to Your Server

### In-Game (Join by IP)

1. Launch Valheim
2. Click **Start Game** → **Start**
3. Select a character
4. Click **Join Game** tab
5. Click **Add Server**
6. Enter: `<your-server-ip>:2456`
7. Click **Connect** and enter your password

### Port Forwarding

Ensure these UDP ports are forwarded to your server:

| Port | Purpose | Required |
|------|---------|----------|
| 2456 | Game traffic | Yes |
| 2457 | Steam queries | Yes |
| 2458 | Crossplay | Only if `CROSSPLAY=true` |

## Configuration Reference

All configuration is done via environment variables in `docker-compose.yml`.

### Server Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_NAME` | `My Valheim Server` | Server name in browser |
| `SERVER_PORT` | `2456` | UDP port (uses +1, +2 also) |
| `WORLD_NAME` | `Dedicated` | World filename |
| `SERVER_PASS` | *(empty)* | Password (min 5 chars) |
| `SERVER_PUBLIC` | `true` | Listed in server browser |
| `CROSSPLAY` | `false` | Xbox/MS Store support |
| `SERVER_ARGS` | *(empty)* | Additional CLI arguments |

### Update Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `UPDATE_ON_START` | `true` | Update server on container start |
| `UPDATE_TIMEOUT` | `900` | Max update time (seconds) |
| `UPDATE_CRON` | *(empty)* | Cron schedule for runtime updates |
| `UPDATE_IF_IDLE` | `true` | Only update when no players. **Not working yet, see [#6](https://github.com/abspwgm/absolute-valheim-server/issues/6):** the server is always treated as empty |
| `STEAMCMD_ARGS` | `validate` | Additional SteamCMD args |

### Backup Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUPS_ENABLED` | `true` | Enable automatic backups |
| `BACKUPS_CRON` | `0 * * * *` | Backup schedule (hourly) |
| `BACKUPS_DIRECTORY` | `/config/backups` | Backup storage path |
| `BACKUPS_MAX_AGE` | `3` | Days to keep backups |
| `BACKUPS_MAX_COUNT` | `0` | Max backups (0=unlimited) |
| `BACKUPS_ZIP` | `true` | Compress backups |
| `BACKUPS_IF_IDLE` | `false` | Only backup when idle. Same limitation as `UPDATE_IF_IDLE` |

### Permission Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | User ID for server process |
| `PGID` | `1000` | Group ID for server process |
| `PERMISSIONS_UMASK` | `022` | File creation umask |

### User Management

| Variable | Description |
|----------|-------------|
| `ADMINLIST_IDS` | Space-separated SteamID64s for admins |
| `BANNEDLIST_IDS` | Space-separated SteamID64s for bans |
| `PERMITTEDLIST_IDS` | Space-separated SteamID64s for whitelist |

Find your SteamID64 at [steamid.io](https://steamid.io/).

**Example:**
```yaml
- ADMINLIST_IDS=76561198012345678 76561198087654321
- BANNEDLIST_IDS=76561198011111111
```

### System Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Etc/UTC` | Container timezone |
| `LOG_FILTER_EMPTY` | `true` | Filter empty log lines |
| `LOG_FILTER_UTF8` | `true` | Filter invalid UTF-8 |
| `LOG_FILTER_CONTAINS` | *(empty)* | Custom filter patterns (pipe-separated) |

### Disaster Response (both variants)

Full runbook: [docs/Disaster-Response.md](docs/Disaster-Response.md). Operator CLI: `docker exec <container> /opt/valheim/scripts/valheim-dr status|snapshot|restore|hold|release|safe-mode`.

| Variable | vanilla | bepinex | Description |
|----------|---------|---------|-------------|
| `DR_SNAPSHOT_BEFORE_UPDATE` | `false` | `true` | Snapshot server files + world + BepInEx state before a Steam update that changes the build (Steam is queried first; unchanged builds cost nothing) |
| `DR_KEEP_SNAPSHOTS` | `2` | `2` | Snapshots to keep (~1 GB each, plain tar) |

### BepInEx (bepinex variant only)

Plugins go in `/config/bepinex/plugins`, config in `/config/bepinex/config`, patchers in `/config/bepinex/patchers`; they survive image upgrades and restores.

| Variable | Default | Description |
|----------|---------|-------------|
| `BEPINEX_ENABLED` | `true` | Inject BepInEx. `false` runs the modded image as vanilla without rebuilding |
| `MODCHECK_STRICT` | `true` | Container health check fails when mods did not load |
| `MODCHECK_TIMEOUT` | `300` | Seconds to wait for `Chainloader startup complete` after each start |
| `MODCHECK_EXPECT_PLUGINS` | *(empty)* | Fail when fewer than N plugins load (set to your mod count) |
| `MODCHECK_FAIL_ON_ANY_ERROR` | `false` | Also fail on plugin-level `[Error]`/`[Fatal]` lines (default: loader errors only) |
| `MOD_FAILURE_POLICY` | `hold` | On failure: `hold` (stay up, block updates, go unhealthy), `rollback` (restore latest snapshot), `vanilla` (snapshot, then run without mods) |
| `BEPINEX_VERSION` | *(build arg)* | Pinned pack version baked into the image; bump with its sha256 in the Dockerfile |

## Volume Mounts

| Container Path | Purpose |
|----------------|---------|
| `/config` | Persistent data (worlds, backups, admin lists, `dr/` snapshots + flags, `bepinex/` plugins + config) |
| `/opt/valheim/server` | Server files (can be cached); on the bepinex image also holds the BepInEx overlay |

## World Migration

### Importing an Existing World

1. **Locate your local world files:**
   - **Windows:** `%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local\`
   - **Linux:** `~/.config/unity3d/IronGate/Valheim/worlds_local/`
   - **macOS:** `~/Library/Application Support/unity.IronGate.Valheim/worlds_local/`

2. **Copy world files to the server volume:**
   ```bash
   # Replace "MyWorld" with your actual world name
   cp MyWorld.db MyWorld.fwl ./data/config/worlds_local/
   ```

3. **Update `docker-compose.yml` to use your world:**
   ```yaml
   - WORLD_NAME=MyWorld
   ```

4. **Restart the server:**
   ```bash
   docker compose restart
   ```

### World File Types

| Extension | Description |
|-----------|-------------|
| `.fwl` | World metadata |
| `.db` | World data (main save) |
| `.db.old` | Previous world state |

## Backup and Restore

### Manual Backup

```bash
docker exec valheim-server /opt/valheim/scripts/valheim-backup --force
```

### Restore from Backup

1. **Stop the server:**
   ```bash
   docker compose down
   ```

2. **Extract backup:**
   ```bash
   cd data/config
   unzip backups/valheim_YourWorld_20240101_120000.zip
   ```

3. **Copy world files:**
   ```bash
   cp valheim_YourWorld_*/YourWorld.* worlds_local/
   ```

4. **Start the server:**
   ```bash
   docker compose up -d
   ```

## Server Management

### View Logs

```bash
# Follow logs
docker compose logs -f

# Last 100 lines
docker compose logs --tail 100
```

### Restart Server

```bash
docker compose restart
```

### Stop Server

```bash
docker compose down
```

### Force Update

```bash
docker compose down
docker compose up -d  # Will update on start
```

### Server Console

```bash
docker exec -it valheim-server bash
```

## Troubleshooting

### Server Won't Start

1. **Check logs:**
   ```bash
   docker compose logs --tail 200
   ```

2. **Verify port availability:**
   ```bash
   sudo lsof -i :2456
   sudo lsof -i :2457
   ```

3. **Check disk space:**
   ```bash
   df -h
   ```

### Can't Connect to Server

1. **Verify server is running:**
   ```bash
   docker compose ps
   ```

2. **Check port forwarding** on your router

3. **Verify firewall rules:**
   ```bash
   sudo ufw status
   ```

4. **Test local connection:** Connect using `127.0.0.1:2456` from the same machine

### World Not Loading

1. **Check world file permissions:**
   ```bash
   ls -la data/config/worlds_local/
   ```

2. **Verify `WORLD_NAME` matches** your `.db`/`.fwl` filenames (without extension)

### Update Timeout

Increase `UPDATE_TIMEOUT` in `docker-compose.yml`:
```yaml
- UPDATE_TIMEOUT=1800  # 30 minutes
```

### High Memory Usage

Valheim servers can use 2-4GB RAM. Set limits in `docker-compose.yml`:
```yaml
deploy:
  resources:
    limits:
      memory: 4G
```

---

## Building from Source

If you want to build the image yourself or contribute to development:

### Clone the Repository

```bash
git clone https://github.com/abspwgm/absolute-valheim-server.git
cd absolute-valheim-server
```

### Build and Run

```bash
docker compose up -d --build
```

### Running E2E Tests

The project includes a comprehensive end-to-end test suite. `VALHEIM_VARIANT` selects the artifact under test:

```bash
# Vanilla artifact (default): shared suite
./tests/run_e2e.sh

# BepInEx artifact: shared suite + mod-load check + disaster drills
VALHEIM_VARIANT=bepinex ./tests/run_e2e.sh

# Run a specific test
./tests/run_e2e.sh server_start
VALHEIM_VARIANT=bepinex ./tests/run_e2e.sh bepinex_disaster_drill
```

### Test Requirements

- Docker and Docker Compose v2
- Bash shell (Git Bash on Windows) and `jq` on the host (DR tests parse `valheim-dr status`)
- ~2GB free disk space for server files (~6GB for the bepinex suite, which takes snapshots)
- ~4GB RAM for running the container

### Test Suite

| Test | Variant | Description |
|------|---------|-------------|
| `server_start` | both | Verifies container starts and server binary launches |
| `server_query` | both | Confirms server is listening on UDP ports 2456/2457 |
| `backup` | both | Tests automatic backup creation and verification |
| `graceful_shutdown` | both | Validates SIGINT handling and graceful shutdown |
| `restart_update` | both | Checks server restart and update functionality |
| `dr_snapshot_restore` | both | Snapshot → tamper → restore → update hold set and honoured → release |
| `bepinex_loaded` | bepinex | Doorstop env generated from the pack, plugins persisted to `/config`, chainloader completes, verdict `ok`, strict health passes |
| `bepinex_safe_mode` | bepinex | `safe-mode on` snapshots and restarts without BepInEx (health still passes); `off` brings mods back |
| `bepinex_disaster_drill` | bepinex | Corrupt doorstop → server up but verdict `not_loaded`, health fails, hold set → `restore latest` → healthy again |

### CI/CD Pipeline

This project uses GitHub Actions with two independent pipelines:

1. **E2E Tests** ([e2e.yml](.github/workflows/e2e.yml)) - Lint + vanilla e2e on every push/PR, plus build verification of both targets
2. **Publish** ([publish.yml](.github/workflows/publish.yml)) - Publishes the vanilla image (`latest`, `vanilla`, semver, `sha-…`) after E2E passes
3. **BepInEx Artifact** ([bepinex.yml](.github/workflows/bepinex.yml)) - Bepinex e2e + disaster drills on every push/PR and **nightly** as a canary against current Steam; publishes `bepinex` / `*-bepinex` tags from its own green runs; opens or updates a `mod-canary` issue on failure and closes it on recovery

Images are published to:
- **Docker Hub:** `docker.io/fireaimready/absolute-valheim-server`
- **GitHub Container Registry:** `ghcr.io/abspwgm/absolute-valheim-server`

> Images published before 2026-09-20 remain at `ghcr.io/fireaimready/absolute-valheim-server` but are no longer updated. Use `ghcr.io/abspwgm/absolute-valheim-server` or Docker Hub.

---

## Systemd Installation (Non-Docker)

For bare-metal Linux installations without Docker:

### 1. Install Dependencies

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install lib32gcc-s1 lib32stdc++6 libsdl2-2.0-0 steamcmd

# Create valheim user
sudo useradd -m -s /bin/bash valheim
```

### 2. Install Service

```bash
# Clone repository
git clone https://github.com/abspwgm/absolute-valheim-server.git
cd absolute-valheim-server

# Copy service file
sudo cp systemd/valheim-server.service /etc/systemd/system/

# Copy and configure environment
sudo cp systemd/valheim.env.example /home/valheim/valheim.env
sudo chown valheim:valheim /home/valheim/valheim.env
sudo nano /home/valheim/valheim.env

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable valheim-server
sudo systemctl start valheim-server
```

### 3. Manage Service

```bash
# Status
sudo systemctl status valheim-server

# Logs
sudo journalctl -u valheim-server -f

# Restart
sudo systemctl restart valheim-server
```

---

## Future Enhancements

The following features are planned for future releases:

- **Mod manager sync** - Pull a Thunderstore/r2modman profile into `/config/bepinex/plugins`
- **Web Dashboard** - Browser-based server management
- **Discord Integration** - Player join/leave notifications
- **RCON Support** - Remote server console

Community contributions are welcome! Please open an issue or pull request.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Iron Gate AB](https://irongatestudio.se/) for creating Valheim
- [Valve/Steam](https://store.steampowered.com/) for SteamCMD
- [BepInEx](https://github.com/BepInEx/BepInEx) and [denikson / AzumattDev](https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/) for BepInExPack_Valheim
- The Valheim dedicated server community

---

**Need help?** Open an [issue](https://github.com/abspwgm/absolute-valheim-server/issues) on GitHub.
