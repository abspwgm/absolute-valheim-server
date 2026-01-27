# Absolute Valheim Server

[![E2E Tests](https://github.com/fireaimready/absolute-valheim-server/actions/workflows/e2e.yml/badge.svg)](https://github.com/fireaimready/absolute-valheim-server/actions/workflows/e2e.yml)
[![Docker Image](https://github.com/fireaimready/absolute-valheim-server/actions/workflows/publish.yml/badge.svg)](https://github.com/fireaimready/absolute-valheim-server/actions/workflows/publish.yml)
[![Docker Pulls](https://img.shields.io/docker/pulls/fireaimready/absolute-valheim-server)](https://hub.docker.com/r/fireaimready/absolute-valheim-server)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A production-ready, containerized Valheim dedicated server with automatic updates, backups, log filtering, and comprehensive end-to-end testing.

## Features

- 🐳 **Docker-based deployment** - Easy setup with Docker Compose
- 🔄 **Auto-updates on startup** - Server files automatically update on container start/restart
- 💾 **Automated backups** - Scheduled world backups with retention policies
- 📝 **Log filtering** - Clean, readable logs with noise filtering
- 🧪 **E2E tested** - Comprehensive automated test suite
- 🔒 **Non-root execution** - Configurable UID/GID for security
- 🖥️ **Systemd support** - Native Linux service for non-Docker deployments
- ⚙️ **Fully configurable** - All settings via environment variables

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (20.10+)
- [Docker Compose](https://docs.docker.com/compose/install/) (v2.0+)
- Minimum 4GB RAM, 2 CPU cores, 10GB disk space

### 1. Clone the Repository

```bash
git clone https://github.com/fireaimready/absolute-valheim-server.git
cd absolute-valheim-server
```

**Or use the pre-built Docker image:**

```bash
# Docker Hub
docker pull fireaimready/absolute-valheim-server:latest

# GitHub Container Registry
docker pull ghcr.io/fireaimready/absolute-valheim-server:latest
```

### 2. Configure Your Server

```bash
# Copy the example configuration
cp .env.example .env

# Edit with your settings
nano .env  # or use your preferred editor
```

**Required settings:**
- `SERVER_NAME` - Your server's display name
- `SERVER_PASS` - Server password (minimum 5 characters)
- `WORLD_NAME` - Name of your world

### 3. Create Data Directories

```bash
mkdir -p data/config data/server
```

### 4. Start the Server

```bash
docker compose up -d
```

### 5. View Logs

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
| 2456 | Game traffic | ✅ Yes |
| 2457 | Steam queries | ✅ Yes |
| 2458 | Crossplay | Only if `CROSSPLAY=true` |

## Configuration Reference

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
| `UPDATE_IF_IDLE` | `true` | Only update when no players |
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
| `BACKUPS_IF_IDLE` | `false` | Only backup when idle |

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
```env
ADMINLIST_IDS=76561198012345678 76561198087654321
BANNEDLIST_IDS=76561198011111111
```

### System Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Etc/UTC` | Container timezone |
| `LOG_FILTER_EMPTY` | `true` | Filter empty log lines |
| `LOG_FILTER_UTF8` | `true` | Filter invalid UTF-8 |
| `LOG_FILTER_CONTAINS` | *(empty)* | Custom filter patterns (pipe-separated) |

## Volume Mounts

| Container Path | Purpose |
|----------------|---------|
| `/config` | Persistent data (worlds, backups, admin lists) |
| `/opt/valheim/server` | Server files (can be cached) |

**Local directory mapping (in docker-compose.yml):**
- `./data/config` → `/config`
- `./data/server` → `/opt/valheim/server`

## World Migration

### Importing an Existing World

1. **Locate your local world files:**
   - **Windows:** `%USERPROFILE%\AppData\LocalLow\IronGate\Valheim\worlds_local\`
   - **Linux:** `~/.config/unity3d/IronGate/Valheim/worlds_local/`
   - **macOS:** `~/Library/Application Support/unity.IronGate.Valheim/worlds_local/`

2. **Copy world files to the container volume:**
   ```bash
   # Replace "MyWorld" with your actual world name
   cp MyWorld.db MyWorld.fwl ./data/config/worlds_local/
   ```

3. **Update `.env` to use your world:**
   ```env
   WORLD_NAME=MyWorld
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

Increase `UPDATE_TIMEOUT` in `.env`:
```env
UPDATE_TIMEOUT=1800  # 30 minutes
```

### High Memory Usage

Valheim servers can use 2-4GB RAM. Set limits in `docker-compose.yml`:
```yaml
deploy:
  resources:
    limits:
      memory: 4G
```

## Running Tests

```bash
# Run all E2E tests
./tests/run_e2e.sh

# Run specific test
./tests/run_e2e.sh server_start
```

## CI/CD Pipeline

This project uses GitHub Actions for continuous integration and deployment:

1. **E2E Tests** ([e2e.yml](.github/workflows/e2e.yml)) - Runs on every push/PR
2. **Publish** ([publish.yml](.github/workflows/publish.yml)) - Builds and publishes Docker image after E2E passes

### Required Secrets for Publishing

To enable Docker Hub publishing, add these secrets to your repository:

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token ([create here](https://hub.docker.com/settings/security)) |

The image is automatically published to:
- **Docker Hub:** `docker.io/fireaimready/absolute-valheim-server`
- **GitHub Container Registry:** `ghcr.io/fireaimready/absolute-valheim-server`

## Future Enhancements

The following features are planned for future releases:

- **Mod Support** - ValheimPlus, BepInEx mod framework integration
- **Web Dashboard** - Browser-based server management
- **Discord Integration** - Player join/leave notifications
- **RCON Support** - Remote server console

Community contributions are welcome! Please open an issue or pull request.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Iron Gate AB](https://irongatestudio.se/) for creating Valheim
- [Valve/Steam](https://store.steampowered.com/) for SteamCMD
- The Valheim dedicated server community

---

**Need help?** Open an [issue](https://github.com/fireaimready/absolute-valheim-server/issues) on GitHub.
