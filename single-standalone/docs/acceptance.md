# Acceptance run

This is the protocol for the real-host run. A person runs every step on real hosts and fills in the rows. Nothing here records a result: every result cell starts empty. The automated suite cannot prove these steps (real Docker, iptables, Cloudflare, Minecraft clients, itzg images).

Step numbers are the ones in the Task 23 spec. Steps 1 to 17 keep their plan numbers; steps 18 to 22 are new.

## Before you start

Run the read-only preflight on each host first, from the code root. It calls no Docker, firewall, SSH or network tool and writes nothing:

    bash single-standalone/tests/acceptance-preflight.sh

It must exit 0 on the host you run it on. Then record these answers here (in your copy of this file):

| Item | Answer |
|---|---|
| Host A: Ubuntu release (`/etc/os-release`) and `uname -r` | |
| Host A: `docker version` (client and server) | |
| Host A: `docker compose version` | |
| Host B: WSL2 distribution, `uname -r`, Docker Desktop or Engine version | |
| `MCCTL_DOMAIN`: the disposable sub-zone (for example `mc-test.example.com`) | |
| Cloudflare token: DNS edit on that one zone only; mode of `secrets/cloudflare_token` | |
| Mode of `secrets/curseforge_api_key` | |
| Minecraft Java client and version | |
| `chmod +x single-standalone/mcctl` done | |
| Clean tree: `DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/run.sh` (result line) | |
| Clean tree: `bash single-standalone/tests/t_invariants.sh` (result line) | |
| Preflight exit code, host A and host B | |

Both clean-tree commands must report 0 failed. Do not start the run on a red suite. Use a host with nothing else on it. Step 1 changes the firewall: keep a second SSH session open, or use the provider's console.

## Recording

- Each step has one section below with one row. In the row write: date and time (UTC), host (A or B), the commands you ran, the result (PASS, FAIL, or N/A with the reason), and notes (versions, counts, timings, anything surprising).
- A FAIL gets a line in `docs/troubleshooting.md` when the cause is an operator matter. When it is code, file a bug against the owning task. The spec names the owners it knows: step 9 (an empty chroot) is Task 9; step 13 (`clear --remove-installed` not emptying the directory) is Task 20, C5.
- Re-run only the failed steps and the steps that depend on them.
- The run is complete when every row is PASS or N/A with a reason. Use the report template at the end.

## Steps

### Step 1: Fresh host path (host A)

Do: `mcctl doctor`, `init`, `firewall plan`, `firewall apply`, open a **new** SSH session, `firewall confirm`, `up`. Then `ss -ltnp` and `iptables -S DOCKER-USER`, `iptables -S MCCTL-EGRESS`, `iptables -S MCCTL-INGRESS`.

Expect: The stack is healthy. Only 25565 and SSH listen on public addresses (SFTP only on 127.0.0.1). `DOCKER-USER` jumps to both chains; `MCCTL-INGRESS` holds the `GAME_SUBNET` RETURN, the `connlimit` rule and the `hashlimit` rule limited to the router address.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 2: Vanilla end to end (host A)

Do: `create s1 --type PAPER --accept-eula`, `start s1`, wait for healthy, join the hostname **without a port**, `rcon s1 list`, `whitelist add s1 PLAYER`, `backup s1 now`, `backup s1 list`, stop, `backup s1 restore ID`, start, `delete s1`.

Expect: Every command works. The DNS record is gone after `delete`; `trash/` holds `s1-<UTC>.tar.gz` readable with `tar -tzf`; no `mc-s1` container remains.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 3: Two servers at once (host A)

Do: Two servers with different hostnames; each client reaches the right one. Stop one.

Expect: The other keeps working.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 4: Modpack, nested server zip (host A)

Do: Nested server zip: create from CurseForge slug `prominence-2-hasturian-era` pinned to file `9184730` (a server pack that is a zip holding the real zip; the Pterodactyl installer once failed on exactly this).

Expect: itzg installs real mods. Record the number of jars in `data/mods`. If it does not, record the failure and the workaround in `troubleshooting.md`.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 5: Modpack, loader not stated (host A)

Do: Loader not stated: create from CurseForge slug `all-the-mods-10` (a server pack that does not state the NeoForge version; the Pterodactyl installer needed `LOADER_VERSION`).

Expect: It starts, or the docs name the variable that fixes it (`mcctl type NAME set NEOFORGE --loader-version V`).

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 6: Modrinth (host A)

Do: Modrinth: create one server from a Modrinth modpack that has a server side (choose one and record its slug; no slug is promised here).

Expect: It starts.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 7: Egress guard on WSL (host B)

Do: Host B (WSL): repeat step 18 (Spike S1) and check `lsmod`/`modprobe -n -v xt_connlimit xt_hashlimit xt_conntrack` and `command -v systemd-run`.

Expect: The router still reaches game containers; a game container cannot reach the LAN gateway or `169.254.169.254`; the two kernel modules load or are built in; where `systemd-run` is missing, `firewall apply` refuses with exit 3 and says why.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 8: Live views (host A)

Do: Live views: `mcctl top` and `mcctl logs s1 -f` for several minutes in an 80-column terminal and in a wide one; press Ctrl-C each time; repeat `top` under `LANG=C`.

Expect: No flicker, no wrapped box lines, the terminal is restored after Ctrl-C (cursor visible, no alternate screen left), ASCII bars under `LANG=C`.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 9: SFTP (host A)

Do: SFTP: add a key (`mcctl sftp add-key`), connect through an SSH tunnel to `127.0.0.1:2222`, upload and download a file, and confirm that server A's user cannot see server B's files; confirm key-only login (a password attempt fails).

Expect: Works as stated. **Open point from the Task 21 spec:** if the chroot is empty because no mount of `servers/NAME/data` exists in the SFTP container, that is a Task 9 bug: record it as FAIL.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 10: Edit under load (host A)

Do: Edit under load: with a player online, `edit s1 --memory 6G`. Then with `--yes`.

Expect: Refused without `--yes` (exit 4). With `--yes` the server returns with the new limit (`docker stats`, `docker inspect`), the router still routes to it, and `mcctl backup s1 now` works (the sidecar was recreated with the server).

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 11: Worlds (host A)

Do: Worlds: `world s1 backup` while a player is online and check autosave is back on; stop; `world new --seed 123`, `use`, `rename`, `export`, `import --as`, `delete` of a non-active world, `reset`; restore a world archive made on another machine.

Expect: Each refuses on a running server where Task 16 says it must; the safety archive exists before each deletion; the player's inventory in the original world is intact after switching back.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 12: Settings and drift (host A)

Do: Settings and drift: `set s1 MAX_PLAYERS=5`; `status` shows `config: pending`; `apply`; `status` shows `current`; `get s1 MAX_PLAYERS` and the in-game cap agree; set a MOTD with `$`, a double quote and `\n`.

Expect: The MOTD shows correctly in the client's server list.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 13: Mods and plugins (host A)

Do: Mods and plugins: on a Fabric server `modrinth add fabric-api`, `mods add` a real https jar URL, add a local jar, `sync`, `mods installed`; `mods remove` the URL and `sync`; `files put` a jar by hand and `sync`; on a Paper server `plugins add` a URL; `mods clear --remove-installed`.

Expect: The jars appear and disappear as the list says; the hand-placed jar survives `sync`; `clear --remove-installed` really empties the directory (Task 20, C5: if not, record FAIL).

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 14: Version and loader (host A)

Do: Version and loader: `upgrade` a `VERSION=LATEST` server; `version set` an older release (refused); `type set` PAPER to FABRIC with plugins present (refused, with the count); `reinstall` a Forge server.

Expect: Each as the Task 18 spec says; the reinstall flag is gone from `server.env` afterwards and `status` is `current`.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 15: Modpack lifecycle (host A)

Do: Modpack lifecycle: `modpack set`, `update` while pinned (refused), `update --version V`, `update --clean`, `remove --type FORGE`.

Expect: A snapshot is taken first each time; `--clean` empties `mods/` and the pack reinstalls.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 16: Files (host A)

Do: Files: `files put`, `get`, `edit`, `rm`; `get ../../etc/passwd` and a `put` through a symlink pointing outside (both refused); check file ownership on the host (`ls -ln servers/s1/data`) and `docker run … alpine:3.20 tar --help`.

Expect: Both refused; files written through the helper belong to UID 1000; busybox `tar` accepts `--no-same-owner` and `-C`.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 17: Clone, rename, export, import (host A)

Do: Clone, rename, export, import: `clone --with-data` of a running server, `rename` (new host, then the same host), `export`, `delete`, `import`.

Expect: DNS records and routes follow each step with no orphan (check the Cloudflare dashboard); the imported server has a new RCON secret; SFTP follows the rename; the record's comment reads `mcctl name=NEW` after a same-host rename (real `PATCH`).

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 18: Spike S1, router and egress (host A, then host B in step 7)

Do: Spike S1 (host A, then B in step 7): start the stack, create a game container with the label `mc-router.host=probe.<domain>`; from the router container open a TCP connection to the game container's port 25565; from the game container try `169.254.169.254`, the LAN gateway and the host's address.

Expect: Router to game works; the three attempts from the game container fail; the router's connections are not counted by `MCCTL-INGRESS`.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 19: Spike S2, RCON and backup sidecar (host A)

Do: Spike S2: start one `itzg/minecraft-server` and one `itzg/mc-backup` as `create` renders them; check that `rcon-cli` needs no password argument, that the sidecar reads `RCON_PASSWORD_FILE` and reaches RCON at `127.0.0.1`, and that `backup now` writes an archive.

Expect: If the sidecar can read a per-restart password without a shared file, record it (the plan's default of one password per server stands unless this says otherwise).

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 20: Firewall effect and reboot (host A)

Do: Firewall effect: from one source open 12 quick connections to port 25565; a normal client still joins; reboot the host.

Expect: Connections past the limit are cut; after the reboot `MCCTL-INGRESS` and `MCCTL-EGRESS` exist again (the guard rebuilt them) and the firewall state is as before.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 21: Backup methods (host A)

Do: Backup methods: local at a short interval (`--backup local --backup-interval 5m`), check `prune`; optionally restic or rsync if credentials exist.

Expect: Archives appear on schedule; `prune` keeps the configured count, and it removes the oldest names, not the newest: the archive order comes from the names, so run `prune` on the names `itzg/mc-backup` really writes before any `PRUNE_BACKUPS_COUNT` is used in production; the optional methods pass or are marked N/A.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

### Step 22: Cleanup (host A)

Do: Cleanup: `delete` every test server; check Cloudflare for leftover `mcctl name=` records; `mcctl down`; `firewall rollback` if the host is reused.

Expect: No record, container, volume or mcctl iptables chain remains; `trash/` holds one archive per deleted server.

| Date and time (UTC) | Host | Commands run | Result | Notes |
|---|---|---|---|---|
| | | | | |

## Not covered

IPv6; a host behind NAT with no public IP; Bedrock; Velocity (docs only); load testing beyond step 20.

## After the run

- All PASS: close the plan. Replace the words "not yet recorded" in `docs/prerequisites.md` with the real versions.
- Any FAIL: write the cause and the fix in `docs/troubleshooting.md` if it is an operator matter, or file a bug against the owning task if it is code. Re-run only the failed steps and the steps that depend on them.

## Report (template)

Copy this into your report. Fill every field.

    Run date (UTC):
    Host A (OS, uname -r, docker, compose):
    Host B (WSL distribution, uname -r, Docker version):
    MCCTL_DOMAIN:
    Code tree (commit, or "uncommitted copy of the working tree"):
    Preflight: exit code per host, FAIL lines if any
    Clean tree: run.sh and t_invariants.sh result lines
    Totals: PASS n, FAIL n, N/A n
    N/A with reasons:
    FAIL list (step, cause, fix or bug against which task, troubleshooting.md line):
    Open points (for example, step 19's password answer, step 4's jar count, step 21's prune order):
    Complete (every row PASS or N/A with a reason): yes or no
