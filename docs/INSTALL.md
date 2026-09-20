# Install Valheim server: step by step

This guide takes you from nothing to a running Valheim server your friends can join. You
do not need to have used Docker or a command line before. Plan for about 30 minutes, most
of it waiting for the game to download.

If you already know Docker, the short version is in the [README](../README.md).

## What you need

| | Minimum |
|---|---|
| Memory (RAM) | 4 GB |
| Free disk space | 10 GB |
| Processor | 2 cores |

- A computer that can stay switched on while people play. An old PC or a mini PC is fine.
  It does not need a graphics card or a copy of the game.
- Linux (Ubuntu or Debian recommended) or Windows 10/11.
- A wired network connection if you can. Wi-Fi works but causes lag for everyone.

## Step 1: Install Docker

Docker is a free program that runs the server in a sealed box, so it cannot make a mess
of your computer and is easy to remove.

**On Linux**, open a terminal and run these two commands:

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Then log out and back in. Check it worked:

```sh
docker --version
```

You should see something like `Docker version 27.x`.

**On Windows**, install [Docker Desktop](https://www.docker.com/products/docker-desktop/),
accept the prompt to enable WSL 2, and restart when asked. Open Docker Desktop once so it
finishes setting up. Then open **PowerShell** and run `docker --version` as above.

## Step 2: Make a folder for your server

Everything your server saves (your world, settings, backups) lives in this folder. Back
up this folder and you have backed up your server.

```sh
mkdir valheim-server
cd valheim-server
```

Nothing is printed when this works. Your terminal prompt now ends in `valheim-server`.

## Step 3: Create the settings file

Create a file named `docker-compose.yml` in that folder and paste this in. On Linux,
`nano docker-compose.yml` opens a simple editor (paste, then Ctrl+O, Enter, Ctrl+X to
save and quit). On Windows, use Notepad and make sure the name does not end in `.txt`.

```yaml
services:
  valheim:
    image: fireaimready/absolute-valheim-server:latest
    container_name: valheim-server

    environment:
      # Server settings (change these)
      - SERVER_NAME=My Valheim Server
      - WORLD_NAME=Dedicated
      - SERVER_PASS=changeme123
      - SERVER_PUBLIC=true

      # Update the game every time the server starts
      - UPDATE_ON_START=true

      # Back up the world every hour, keep the newest 72 (three days)
      - BACKUPS_ENABLED=true
      - BACKUPS_CRON=0 * * * *
      - BACKUPS_MAX_COUNT=72

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

Change these lines before you go on. Leave everything else alone for now.

| Line | Change it to |
|---|---|
| `SERVER_NAME=My Valheim Server` | The name players see in the server list |
| `SERVER_PASS=changeme123` | A password of your own, at least 5 characters. The server refuses to start with a shorter one |
| `WORLD_NAME=Dedicated` | A name for your world. Pick it now: changing it later starts a new, empty world |
| `SERVER_PUBLIC=true` | `false` if you do not want the server shown in the public server list. Friends can still join by address |
| `TZ=Etc/UTC` | Your time zone, for example `Europe/London`, so times in the log match your clock |

> Spaces at the start of each line matter in this file. Keep them exactly as shown.

## Step 4: Start the server

```sh
docker compose up -d
```

You should see the image download, then a line ending in `Started`.

The first start downloads the game (about 1 GB), which takes 5 to 15 minutes on a typical
connection. Watch it work:

```sh
docker compose logs -f
```

The server is ready when you see a line containing:

```
Game server connected
```

Press Ctrl+C to stop watching. That does not stop the server.

## Step 5: Join from your own network

Do this before involving your router, so you know the server itself works.

1. Find the server computer's address: `hostname -I` on Linux, `ipconfig` on Windows
   (look for **IPv4 Address**). It looks like `192.168.1.50`.
2. On the computer you play on, launch Valheim.
3. Click **Start Game**, pick a character, and click **Start**.
4. Open the **Join Game** tab.
5. Click **Add Server**.
6. Type the server computer's address, then `:2456`. For example `192.168.1.50:2456`.
7. Click **Connect** and type the password you chose in Step 3.

You should land in your new world. If Valheim runs on the server computer itself, use
`127.0.0.1:2456` instead.

## Step 6: Let friends join from the internet

Friends outside your home cannot connect until your router forwards the game's ports to
the server computer. Follow the
[port forwarding guide](https://github.com/abspwgm/absolute-game-servers/blob/main/docs/port-forwarding.md)
and use this table when it asks for ports:

| Port | Protocol | What it is for | Forward it? |
|---|---|---|---|
| 2456 | UDP | Game traffic | Yes |
| 2457 | UDP | Server list query | Yes |
| 2458 | UDP | Crossplay | Only if you set `CROSSPLAY=true` |

Then give your friends your public address (the port forwarding guide shows how to find
it) followed by `:2456`, for example `203.0.113.25:2456`, and the password. They join
the same way you did in Step 5: **Start Game**, **Join Game**, **Add Server**, enter the
address, **Connect**.

People inside your home keep using the server computer's local address from Step 5. The
public address often does not work from inside the same network.

## Looking after your server

| I want to | Command |
|---|---|
| See if it is running | `docker compose ps` |
| Watch the log | `docker compose logs -f` |
| Stop it (saves the world first) | `docker compose down` |
| Start it again | `docker compose up -d` |
| Update the game right now (this restarts the server) | `docker exec valheim-server /opt/valheim/scripts/valheim-updater` |
| Make a backup right now | `docker exec valheim-server /opt/valheim/scripts/valheim-backup --force` |
| Get our latest fixes | `docker compose pull` then `docker compose up -d` |

**Updates.** The server updates the game each time it starts. To also check on a
schedule, add a line such as `- UPDATE_CRON=30 5 * * *` (every day at 05:30) under
`environment:` and run `docker compose up -d`. Pick an hour when nobody plays: a scheduled
update restarts the server even if people are connected
([#6](https://github.com/abspwgm/absolute-valheim-server/issues/6)).

**Backups.** A backup is made every hour into `data/config/backups` inside your server
folder, as a file named like `valheim_Dedicated_20260101_120000.zip`. With the settings
above the newest 72 are kept and older ones are removed. Copy that folder somewhere else
now and then. A backup on the same disk does not survive the disk failing.

**Restoring a backup.**

1. Stop the server:

   ```sh
   docker compose down
   ```

2. Go into the config folder:

   ```sh
   cd data/config
   ```

3. Unpack the backup you want, using its real file name. On Windows, right-click the zip
   in `data\config\backups` and choose **Extract All** into `data\config` instead.

   ```sh
   unzip backups/valheim_Dedicated_20260101_120000.zip
   ```

   You should see two or three files listed, ending in `.db`, `.fwl` and sometimes
   `.db.old`.

4. Copy the world files over the current ones (use your world name in place of
   `Dedicated`):

   ```sh
   cp valheim_Dedicated_*/Dedicated.* worlds_local/
   ```

5. Go back to the server folder and start the server:

   ```sh
   cd ../..
   docker compose up -d
   ```

## Want mods?

There is a second image with the BepInEx mod loader built in. It is not covered here;
see [BepInEx](../README.md#bepinex-bepinex-variant-only) and
[Image variants](../README.md#image-variants) in the README once your plain server works.

## When something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `docker: command not found` | Docker is not installed, or you have not logged out and in since Step 1 | Redo Step 1 |
| `permission denied` talking to Docker | Your user is not in the `docker` group yet | Log out and back in, or put `sudo` in front |
| `yaml:` error on start | The spacing in `docker-compose.yml` was changed | Paste the file again from Step 3 |
| Log stops at "downloading" for a long time | The first download is large | Wait. It resumes if interrupted |
| `port is already allocated` | Another program is using the game's port | Stop the other server, or change the left-hand number of the port pair |
| I can join, my friends cannot | Port forwarding | Work through the table at the end of the port forwarding guide |
| `Password must be at least 5 characters` in the log | `SERVER_PASS` is too short | Set a longer password in `docker-compose.yml`, then `docker compose up -d` |
| The update step gives up on a slow connection | The download took longer than the 15 minute limit | Add `- UPDATE_TIMEOUT=1800` under `environment:`, then `docker compose up -d` |
| The world is empty after I changed `WORLD_NAME` | The server made a new world with the new name | Put the old name back, or see [World Migration](../README.md#world-migration) |

Still stuck? [Open an issue](https://github.com/abspwgm/absolute-valheim-server/issues/new)
and paste the last 50 lines of `docker compose logs`. Remove your server password first.

## Words used in this guide

- **Container:** the sealed box Docker runs the server in.
- **Image:** the download that a container is started from. Ours is
  `fireaimready/absolute-valheim-server:latest`.
- **Compose file:** `docker-compose.yml`, the one file holding all your server's settings.
- **Volume:** a folder on your computer that the container saves into, so your world
  survives updates and restarts.
- **Port:** a numbered door on a network address. Games listen on specific ones.
- **UDP / TCP:** two ways of sending data. A forwarding rule must use the one the game uses.
