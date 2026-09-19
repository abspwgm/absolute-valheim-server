# Hosting on Proxmox behind UniFi

Two Valheim servers (vanilla + BepInEx) on one Docker host in the **Game Server
VLAN**, exposed to the internet only on the UDP ports Valheim needs, and unable to
reach the rest of the LAN. Compose file: `deploy/proxmox/docker-compose.yml`.

## Layout

```text
Internet ──UDP 2456-2457──▶ UniFi WAN ──port-forward──▶ 10.30.0.20:2456-2457 (valheim-vanilla)
Internet ──UDP 2466-2467──▶ UniFi WAN ──port-forward──▶ 10.30.0.20:2466-2467 (valheim-bepinex)

VLAN 30 "Game Servers" 10.30.0.0/24
  └─ Proxmox VM  valheim-host  10.30.0.20  (Debian/Ubuntu + Docker)
       ├─ container valheim-vanilla   host ports 2456-2457/udp
       └─ container valheim-bepinex   host ports 2466-2467/udp
```

Replace `10.30.0.0/24` / VLAN 30 with your Game Server VLAN. Everything below assumes
the VM gets a **fixed IP** (DHCP reservation in UniFi under *Client Devices → the VM →
Settings → Fixed IP*), because port forwards target an address.

### Ports

| Server | Game | Query | Crossplay (PlayFab) |
|---|---|---|---|
| vanilla | 2456/udp | 2457/udp | 2458/udp, only with `CROSSPLAY=true` |
| bepinex | 2466/udp | 2467/udp | 2468/udp, only with `CROSSPLAY=true` |

Valheim uses `SERVER_PORT` and `SERVER_PORT+1`; `+2` is only for crossplay. Keep
crossplay off unless you need Xbox/Microsoft Store players (BepInEx does not work with
crossplay clients anyway), and do not forward the `+2` port otherwise. Nothing TCP is
exposed.

## Proxmox

- **One VM, not an LXC.** Docker in unprivileged LXC needs nesting/keyctl workarounds
  and `cap_add: SYS_NICE` is unavailable; a small VM avoids all of it. 4 vCPU, 8 GB
  RAM (two servers at ~2-3 GB each, headroom for SteamCMD), 60 GB disk (two server
  installs + DR snapshots at ~1 GB each + backups).
- **Network device**: bridge `vmbr0`, **VLAN Tag = 30** (or whichever your Game
  Server VLAN is). The VM then sits in that VLAN with no trunking to worry about
  inside the guest. Enable the Proxmox firewall on the NIC only if you also maintain
  those rules; the UniFi firewall below is the boundary that matters.
- **Backups**: Proxmox Backup Server / vzdump of the VM is coarse; the in-container
  world backups (`/config/backups`, hourly) and DR snapshots are the fine-grained
  layer. Put `/var/lib/docker/volumes` on a disk you back up.
- Use the same Docker Compose project directory for both containers so `docker
  compose ps` shows both.

## UniFi

### 1. Network

*Settings → Networks → New*: name `Game Servers`, VLAN ID 30, subnet `10.30.0.0/24`,
DHCP on. Isolation: **do not** tick "Network Isolation" blindly; it blocks the LAN
from reaching the VM too. Use explicit firewall rules instead (below) so your admin
workstation can still SSH in.

### 2. Port forwarding

*Settings → Firewall & Security → Port Forwarding → Create*. One rule per port range:

| Name | From | Port | Forward IP | Forward Port | Protocol |
|---|---|---|---|---|---|
| valheim-vanilla | Any | 2456-2457 | 10.30.0.20 | 2456-2457 | UDP |
| valheim-bepinex | Any | 2466-2467 | 10.30.0.20 | 2466-2467 | UDP |

- **UDP only.** Do not select "Both".
- If you have a **friends-only** server and static-ish friends, restrict *From* to
  their IPs or a UniFi IP Group instead of Any. Combined with `SERVER_PASS` this is
  the strongest cheap control you have.
- Do **not** enable UPnP on the UniFi gateway; the forwards above are explicit.
- Docker publishes the same ports on the VM, so no extra rule inside the guest is
  needed. Note that Docker bypasses `ufw` on the host; the UniFi firewall is the
  control point, not host `ufw`.

### 3. Firewall rules (LAN In / Internet In)

Goal: the Game Server VLAN is treated like a DMZ. It can go **out** (Steam CDN,
Thunderstore for image builds, time, DNS) and accept the forwarded game ports **in**,
but it cannot initiate anything toward your other VLANs.

*Settings → Firewall & Security → Firewall Rules → LAN In*, in this order:

| # | Rule | Action | Source | Destination | Notes |
|---|---|---|---|---|---|
| 1 | Allow established/related | Accept | Any | Any | Stateful return traffic. Usually already present. |
| 2 | Allow admin → game VLAN SSH | Accept | Your admin VLAN or IP group | Game Servers, TCP 22 | So you can manage the VM. |
| 3 | Allow LAN → game ports (optional) | Accept | LAN / trusted VLANs | Game Servers, UDP 2456-2457, 2466-2467 | Lets household players join over LAN instead of hairpinning through WAN. |
| 4 | Block game VLAN → RFC1918 | Drop | Game Servers | IP group `RFC1918` (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) | The DMZ rule. Placed after the allows. |
| 5 | Block game VLAN → gateway services | Drop | Game Servers | Gateway addresses, all but DNS/NTP | Prevents the VM from reaching the UniFi controller UI. Allow UDP 53 / 123 to the gateway *above* this rule if you use it for DNS/NTP. |

*Internet In* needs nothing beyond the port forwards; UniFi creates the matching
accept rules automatically.

Sanity checks from the VM:

```bash
nc -zvu 8.8.8.8 53            # out to internet: works
curl -sI https://thunderstore.io | head -1   # HTTPS out: works
nc -zv 192.168.1.1 443        # into your LAN: must time out
```

### 4. Verify from outside

```bash
# From a phone hotspot or a VPS; Valheim's query port answers A2S_INFO
python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);s.sendto(b'\xff\xff\xff\xffTSource Engine Query\x00',('YOUR.WAN.IP',2457));print(s.recv(1400)[:60])"
```

Or simply add `YOUR.WAN.IP:2456` in Valheim's *Join Game → Add server*. With
`SERVER_PUBLIC=false` the server is joinable by IP but does not appear in the browser
list; that is the recommended setting for a private group.

## Running the two servers

```bash
git clone https://github.com/fireaimready/absolute-valheim-server.git
cd absolute-valheim-server/deploy/proxmox
cp .env.example .env && $EDITOR .env      # passwords, world names, admin SteamIDs
docker compose pull
docker compose up -d
docker compose logs -f valheim-bepinex
```

Modded server plugins go into the config volume:

```bash
docker exec valheim-bepinex /opt/valheim/scripts/valheim-dr snapshot before-mods
docker cp MyMod.dll valheim-bepinex:/config/bepinex/plugins/
docker exec valheim-bepinex /opt/valheim/scripts/valheim-dr restart
docker exec valheim-bepinex /opt/valheim/scripts/valheim-dr status | jq .modcheck
```

Set `BEPINEX_EXPECT_PLUGINS` in `.env` to your plugin count once you are happy, so a
future update that silently drops a plugin fails the health check.

## Monitoring

- `docker ps` shows `(healthy)` / `(unhealthy)`; the bepinex container turns unhealthy
  when mods fail to load (see `docs/Disaster-Response.md`). Wire that into whatever
  watches your Proxmox host (Uptime Kuma's Docker monitor, or a cron that greps
  `docker inspect -f '{{.State.Health.Status}}'`).
- The nightly `BepInEx Artifact` workflow in GitHub is your early warning that a
  Valheim update broke injection, usually before your server restarts into it.

## Security summary

| Control | Where |
|---|---|
| Only UDP game/query ports exposed, per server, explicit forwards, no UPnP | UniFi port forwarding |
| Game VLAN cannot initiate into other VLANs or the controller | UniFi LAN In drop rules |
| Optional source-IP allow-list for friends-only servers | UniFi port forward *From* / IP group |
| Server password (`SERVER_PASS`, min 5 chars), `SERVER_PUBLIC=false`, admin allow-list by SteamID64 | Compose `.env` |
| No secrets in the repo; `.env` is git-ignored | `deploy/proxmox/.env` |
| Container runs the game as UID 1000, minimal caps (`SYS_NICE`), no Docker socket mounted | Image / compose |
| Modded server is health-gated and snapshotted before updates | DR harness |
