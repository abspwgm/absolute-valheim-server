# Disaster Response for the Modded (BepInEx) Server

This repo ships two artifacts from one Dockerfile:

| Artifact | Target / tag | Priority | Harness |
|---|---|---|---|
| Vanilla | `--target vanilla` → `:latest`, `:vanilla` | CI/CD and uptime. Tracks Steam, auto-updates, no third-party runtime. | Available (`valheim-dr`) but unarmed. |
| BepInEx | `--target bepinex` → `:bepinex`, `:*-bepinex` | Mods. Expected to break when Iron Gate ships an update BepInEx or the pack cannot survive yet. | Armed: pre-update snapshots, mod-load verification, hold / rollback / safe mode, nightly canary. |

The two pipelines are deliberately independent. `e2e.yml` + `publish.yml` gate and
publish vanilla; `bepinex.yml` tests, publishes and canaries the modded artifact. A
broken mod ecosystem can never block a vanilla release.

## The failure model

Valheim clients auto-update through Steam. A server whose build differs from the
clients' cannot be joined. So when Iron Gate ships a patch, a modded server has two
bad options and one good one:

| Option | Players can join? | World safe? | When |
|---|---|---|---|
| Don't update (`hold`) | No, until clients match | Yes | Buying time while BepInEx / mods catch up. |
| Update and run without mods (`safe-mode`) | Yes | **No** if mods added prefabs/items: they are dropped on the next save. Snapshot first. | Vanilla-compatible mod sets (QoL, admin tools). |
| Update, mods still load (`ok`) | Yes | Yes | The normal case; modcheck proves it. |

A separate, more common failure is operator-caused: a new or updated plugin breaks
the chainloader. For that, `rollback` to the last good snapshot is the right response.

## What the harness does automatically (bepinex image defaults)

| Step | Where | Knob |
|---|---|---|
| Before a Steam update that would change the build, snapshot server files + world + BepInEx state. Steam is asked for the public build id first; an unchanged build costs nothing. | `valheim-updater` | `DR_SNAPSHOT_BEFORE_UPDATE=true`, `DR_KEEP_SNAPSHOTS=2` |
| After every server start, wait for BepInEx's `Chainloader startup complete`, count loader errors and plugins, write a verdict. | `valheim-modcheck` (detached) | `MODCHECK_TIMEOUT=300`, `MODCHECK_EXPECT_PLUGINS`, `MODCHECK_FAIL_ON_ANY_ERROR` |
| On a failed verdict, apply the policy. | `valheim-modcheck` | `MOD_FAILURE_POLICY=hold` (or `rollback`, `vanilla`) |
| Make the container **unhealthy** when the verdict is failed, even though the process is up. | `healthcheck` | `MODCHECK_STRICT=true` |
| Refuse Steam updates while an `UPDATE_HOLD` flag exists (set by policy, restore, or you). | `valheim-updater` | `valheim-dr hold` / `release`, `--ignore-hold` |
| Nightly, rebuild the image against current Steam + pinned pack, run the suite and drills, open/update a `mod-canary` issue on failure and close it on recovery. | `.github/workflows/bepinex.yml` | schedule `0 6 * * *` |

### Verdicts

`valheim-dr status | jq .modcheck`

| `status` | `reason` | Meaning |
|---|---|---|
| `ok` | `loaded` | Chainloader finished, no loader errors, plugin count satisfied. |
| `pending` | `waiting` | Server just started; still inside `MODCHECK_TIMEOUT`. Healthy. |
| `failed` | `not_loaded` | No `Chainloader startup complete`. If `LogOutput.log` is missing entirely, doorstop did not inject (broken/missing `libdoorstop_x64.so`, env not applied, game update changed the loader contract). |
| `failed` | `loader_errors` | BepInEx itself logged `[Error]`/`[Fatal]` (e.g. `Could not load [Plugin] because it has missing dependencies`, `Error loading [Plugin]`). |
| `failed` | `plugin_count` | Fewer than `MODCHECK_EXPECT_PLUGINS` plugins found. |
| `failed` | `plugin_errors` | `MODCHECK_FAIL_ON_ANY_ERROR=true` and some plugin logged an error. |
| `failed` | `server_not_running` | The process died during the check. `action_taken` is `none` when supervisor stopped it on purpose. |
| `disabled` | `safe_mode` / `bepinex_disabled` / `not_bepinex_variant` | BepInEx intentionally not injected. Healthy, with a warning. |

### Policies

| `MOD_FAILURE_POLICY` | Effect | Choose when |
|---|---|---|
| `hold` (default) | Keep whatever is running, set `UPDATE_HOLD`, go unhealthy. Nothing destructive happens without you. | Always a safe default; you have monitoring on container health. |
| `rollback` | Restore the newest snapshot (server files **and** world), set `UPDATE_HOLD`, restart. Skipped when a hold is already active (no loops) or no snapshot exists. | Operator-caused breakage (bad plugin drop) on a server you rarely touch. Note: after a Steam update this leaves you on the old build, which updated clients cannot join. |
| `vanilla` | Snapshot, engage `SAFE_MODE` (start without BepInEx), set `UPDATE_HOLD`, restart. | Your mod set is world-safe and uptime matters more than mods. |

## Operator commands

All run inside the container, e.g. `docker exec valheim-bepinex /opt/valheim/scripts/valheim-dr status`.

```text
valheim-dr status                          # JSON: build ids, BepInEx, hold, modcheck verdict, snapshots
valheim-dr snapshot [label] [--reason T]   # server files + world + /config/bepinex  (~1 GB each)
valheim-dr list
valheim-dr restore <id|latest> [--server-only|--world-only] [--reason T]
valheim-dr hold [reason] | release
valheim-dr safe-mode on|off [--reason T] [--no-snapshot]
valheim-dr restart                         # supervisor restart of the server process
valheim-dr modcheck                        # re-run verification now, without policy
valheim-dr prune [N]

valheim-updater --force --ignore-hold      # one-off update despite a hold
valheim-bepinex status | env               # overlay state and the doorstop launch env
```

Everything `valheim-dr` needs is under `/config/dr/` on the config volume:
`snapshots/<timestamp>_<label>/{manifest.json,server.tar,config.tar}`, the
`UPDATE_HOLD` and `SAFE_MODE` flag files, and `last_restore.json`. Flags survive
restarts and image upgrades on purpose.

## Runbooks

### A Valheim update broke the modded server

Symptoms: container `unhealthy`; `valheim-dr status` shows `modcheck.status=failed`
after `build_id` changed (`previous_build_id` differs); the nightly canary opened a
`mod-canary` issue with the same Steam build id.

1. Confirm: `valheim-dr status | jq '{build_id, previous_build_id, modcheck}'`.
   Look at `/opt/valheim/server/BepInEx/LogOutput.log` if it exists.
2. Decide, using the table above:
   - **Wait for the ecosystem** (typical): leave `hold` in place. Players cannot
     join until clients and server match anyway, so tell them. Watch
     [BepInExPack_Valheim on Thunderstore](https://thunderstore.io/c/valheim/p/denikson/BepInExPack_Valheim/)
     for a release, then bump the pin (below).
   - **Keep players online without mods**: `valheim-dr safe-mode on --reason "patch X"`.
     A snapshot is taken first. Re-enable later with `safe-mode off`.
   - **Go back to the previous build**: `valheim-dr restore latest`. Only useful if
     players can also downgrade, so rarely; but it is the fastest way back to a known
     good server + world pair.
3. When a fixed pack ships: bump `BEPINEX_VERSION` and `BEPINEX_SHA256` in the
   Dockerfile, let `bepinex.yml` prove it (or run it via *workflow_dispatch* with the
   override inputs first), pull the new `:bepinex` image, then `valheim-dr release`.

### A plugin I added broke the server

1. `valheim-dr status | jq .modcheck` → usually `loader_errors`.
2. Remove or fix the plugin under `/config/bepinex/plugins`, then `valheim-dr restart`;
   or `valheim-dr restore latest` if you snapshotted before the change (do that:
   `valheim-dr snapshot before-modpack-x`).
3. `valheim-dr release` once `modcheck.status=ok`.

### The nightly canary failed but production is fine

The canary runs the pinned pack against whatever Steam serves *today*. If Steam moved
and production has not restarted yet, production is still on the old build and will
break on its next update-on-start. Options: set `hold` now on production
(`valheim-dr hold "canary red on build X"`), or flip the production compose to
`UPDATE_ON_START=false` until the pack is fixed.

### Drills

The e2e suite rehearses all of this on every push to keep the harness honest:

| Test | Variant | Proves |
|---|---|---|
| `dr_snapshot_restore` | both | snapshot → tamper → restore → hold set → updater refuses → release |
| `bepinex_loaded` | bepinex | doorstop env generated from the pack, plugins persisted to `/config`, `Chainloader startup complete`, verdict `ok`, strict health passes |
| `bepinex_safe_mode` | bepinex | `safe-mode on` snapshots, restarts vanilla (no BepInEx log), health passes; `off` brings mods back |
| `bepinex_disaster_drill` | bepinex | corrupt `libdoorstop_x64.so` → server up but verdict `not_loaded`, health **fails**, hold set → `restore latest` → verdict `ok`, healthy |

Run them locally: `VALHEIM_VARIANT=bepinex ./tests/run_e2e.sh` (needs `jq` on the host).

## Bumping BepInEx

```bash
V=5.4.2350   # new version from Thunderstore
curl -sSL -o /tmp/pack.zip "https://thunderstore.io/package/download/denikson/BepInExPack_Valheim/${V}/"
sha256sum /tmp/pack.zip
```

Update `ARG BEPINEX_VERSION` and `ARG BEPINEX_SHA256` in the Dockerfile (both, in one
commit). The build fails if the hash does not match, so a moved or tampered upstream
zip cannot ship. The overlay installer reads the doorstop `export` lines from the
pack's own `start_server_bepinex.sh`, so upstream renaming doorstop variables again
does not require a code change here.

## Design notes

- BepInEx files live *in* `/opt/valheim/server` because doorstop resolves paths
  relative to the game binary. `BepInEx/{plugins,config,patchers}` are symlinks into
  `/config/bepinex` so operator state survives image upgrades, Steam validates, and
  server-file restores.
- The doorstop environment is applied with `env` in front of the game binary only.
  Exporting `LD_PRELOAD=libdoorstop_x64.so` into the shell would preload it into
  bash, `pgrep`, and the log filter.
- `BepInEx/LogOutput.log` is deleted before every start; BepInEx only recreates it
  when it actually injects, so its absence is the most reliable "doorstop did not
  load" signal and immune to stale logs.
- Snapshots are plain `tar` (no compression) so a 1 GB server directory snapshots and
  restores in seconds; `DR_KEEP_SNAPSHOTS` bounds disk.
- The verifier runs in its own session (`setsid`) so that a supervisor restart of the
  server group, which it may itself have requested, cannot kill it mid-response.
- `hold` is the default policy because the other two policies take actions with
  player-visible consequences; an unhealthy container that keeps serving is the safest
  thing to hand an on-call human.
