# Task 23 spec: acceptance run on real Docker (manual, produces a report)

Status: written, not dispatched. This task is run by a person on real hosts. No subagent runs it, and the sandbox cannot. Its output is `single-standalone/docs/acceptance.md` filled in. Verified against the specs of Tasks 5 to 22 on 2026-10-24.
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 23").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`. The template of the report is written by Task 22; this spec is its source.

## 1. Purpose

Everything the automated suite cannot prove: real Docker, real iptables, real Cloudflare, real Minecraft clients, real itzg images. Each automated task listed "not provable in the sandbox" items; this run closes them. A failing check is a bug in an earlier task, never a reason to loosen the list.

## 2. How the plan text changes

Steps 1 to 17 keep their numbers, because other specs refer to them (Task 10: step 10; Task 11: steps 1 and 7; Task 12: step 8; Task 15: step 16; Task 16: steps 11 and 16; Task 21: step 17). They gain the checks below. Steps 18 to 22 are new.

## 3. Preconditions (record the answers at the top of the report)

- Host A: Ubuntu 22.04 or 24.04 VPS with a public IPv4, root, Docker Engine and Compose plugin (record `docker version` and `docker compose version`), systemd. Host B: WSL2 Ubuntu with Docker Desktop (or Docker Engine in WSL). Record the WSL kernel (`uname -r`).
- A Cloudflare zone you can spend, a disposable sub-zone name for `MCCTL_DOMAIN` (for example `mc-test.example.com`), and an API token with **DNS edit on that one zone only**. Put it in `secrets/cloudflare_token`, mode 600.
- A CurseForge API key in `secrets/curseforge_api_key`.
- A Minecraft Java client that can join a `host:25565` address by name.
- `chmod +x single-standalone/mcctl` (a checkout from Windows drops the executable bit; `git update-index --chmod=+x single-standalone/mcctl` before any commit).
- A clean tree: run `DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/run.sh` and `bash single-standalone/tests/t_invariants.sh` first; both at 0 failed. Do not start the run on a red suite.
- Safety: use a host with nothing else on it. Step 1 changes the firewall: keep a second SSH session open, or use the provider's console.

## 4. Recording

For every step write one row in `docs/acceptance.md`: step number, date and time (UTC), host (A or B), the commands run, the result (PASS, FAIL or N/A with the reason), and notes (versions, counts, timings, anything surprising). A FAIL gets a line in `docs/troubleshooting.md` or a bug against the owning task. The run is complete when every row is PASS or N/A with a reason.

## 5. Steps

| # | Do (host A unless stated) | Expect |
|---|---|---|
| 1 | Fresh host path: `mcctl doctor`, `init`, `firewall plan`, `firewall apply`, open a **new** SSH session, `firewall confirm`, `up`. Then `ss -ltnp` and `iptables -S DOCKER-USER`, `iptables -S MCCTL-EGRESS`, `iptables -S MCCTL-INGRESS`. | The stack is healthy. Only 25565 and SSH listen on public addresses (SFTP only on 127.0.0.1). `DOCKER-USER` jumps to both chains; `MCCTL-INGRESS` holds the `GAME_SUBNET` RETURN, the `connlimit` rule and the `hashlimit` rule limited to the router address. |
| 2 | Vanilla end to end: `create s1 --type PAPER --accept-eula`, `start s1`, wait for healthy, join the hostname **without a port**, `rcon s1 list`, `whitelist add s1 PLAYER`, `backup s1 now`, `backup s1 list`, stop, `backup s1 restore ID`, start, `delete s1`. | Every command works. The DNS record is gone after `delete`; `trash/` holds `s1-<UTC>.tar.gz` readable with `tar -tzf`; no `mc-s1` container remains. |
| 3 | Two servers with different hostnames; each client reaches the right one. Stop one. | The other keeps working. |
| 4 | Nested server zip: create from CurseForge slug `prominence-2-hasturian-era` pinned to file `9184730` (a server pack that is a zip holding the real zip; the Pterodactyl installer once failed on exactly this). | itzg installs real mods. Record the number of jars in `data/mods`. If it does not, record the failure and the workaround in `troubleshooting.md`. |
| 5 | Loader not stated: create from CurseForge slug `all-the-mods-10` (a server pack that does not state the NeoForge version; the Pterodactyl installer needed `LOADER_VERSION`). | It starts, or the docs name the variable that fixes it (`mcctl type NAME set NEOFORGE --loader-version V`). |
| 6 | Modrinth: create one server from a Modrinth modpack that has a server side (choose one and record its slug; no slug is promised here). | It starts. |
| 7 | Host B (WSL): repeat step 18 (Spike S1) and check `lsmod`/`modprobe -n -v xt_connlimit xt_hashlimit xt_conntrack` and `command -v systemd-run`. | The router still reaches game containers; a game container cannot reach the LAN gateway or `169.254.169.254`; the two kernel modules load or are built in; where `systemd-run` is missing, `firewall apply` refuses with exit 3 and says why. |
| 8 | Live views: `mcctl top` and `mcctl logs s1 -f` for several minutes in an 80-column terminal and in a wide one; press Ctrl-C each time; repeat `top` under `LANG=C`. | No flicker, no wrapped box lines, the terminal is restored after Ctrl-C (cursor visible, no alternate screen left), ASCII bars under `LANG=C`. |
| 9 | SFTP: add a key (`mcctl sftp add-key`), connect through an SSH tunnel to `127.0.0.1:2222`, upload and download a file, and confirm that server A's user cannot see server B's files; confirm key-only login (a password attempt fails). | Works as stated. **Open point from the Task 21 spec:** if the chroot is empty because no mount of `servers/NAME/data` exists in the SFTP container, that is a Task 9 bug: record it as FAIL. |
| 10 | Edit under load: with a player online, `edit s1 --memory 6G`. Then with `--yes`. | Refused without `--yes` (exit 4). With `--yes` the server returns with the new limit (`docker stats`, `docker inspect`), the router still routes to it, and `mcctl backup s1 now` works (the sidecar was recreated with the server). |
| 11 | Worlds: `world s1 backup` while a player is online and check autosave is back on; stop; `world new --seed 123`, `use`, `rename`, `export`, `import --as`, `delete` of a non-active world, `reset`; restore a world archive made on another machine. | Each refuses on a running server where Task 16 says it must; the safety archive exists before each deletion; the player's inventory in the original world is intact after switching back. |
| 12 | Settings and drift: `set s1 MAX_PLAYERS=5`; `status` shows `config: pending`; `apply`; `status` shows `current`; `get s1 MAX_PLAYERS` and the in-game cap agree; set a MOTD with `$`, a double quote and `\n`. | The MOTD shows correctly in the client's server list. |
| 13 | Mods and plugins: on a Fabric server `modrinth add fabric-api`, `mods add` a real https jar URL, add a local jar, `sync`, `mods installed`; `mods remove` the URL and `sync`; `files put` a jar by hand and `sync`; on a Paper server `plugins add` a URL; `mods clear --remove-installed`. | The jars appear and disappear as the list says; the hand-placed jar survives `sync`; `clear --remove-installed` really empties the directory (Task 20, C5: if not, record FAIL). |
| 14 | Version and loader: `upgrade` a `VERSION=LATEST` server; `version set` an older release (refused); `type set` PAPER to FABRIC with plugins present (refused, with the count); `reinstall` a Forge server. | Each as the Task 18 spec says; the reinstall flag is gone from `server.env` afterwards and `status` is `current`. |
| 15 | Modpack lifecycle: `modpack set`, `update` while pinned (refused), `update --version V`, `update --clean`, `remove --type FORGE`. | A snapshot is taken first each time; `--clean` empties `mods/` and the pack reinstalls. |
| 16 | Files: `files put`, `get`, `edit`, `rm`; `get ../../etc/passwd` and a `put` through a symlink pointing outside (both refused); check file ownership on the host (`ls -ln servers/s1/data`) and `docker run … alpine:3.20 tar --help`. | Both refused; files written through the helper belong to UID 1000; busybox `tar` accepts `--no-same-owner` and `-C`. |
| 17 | Clone, rename, export, import: `clone --with-data` of a running server, `rename` (new host, then the same host), `export`, `delete`, `import`. | DNS records and routes follow each step with no orphan (check the Cloudflare dashboard); the imported server has a new RCON secret; SFTP follows the rename; the record's comment reads `mcctl name=NEW` after a same-host rename (real `PATCH`). |
| 18 | Spike S1 (host A, then B in step 7): start the stack, create a game container with the label `mc-router.host=probe.<domain>`; from the router container open a TCP connection to the game container's port 25565; from the game container try `169.254.169.254`, the LAN gateway and the host's address. | Router to game works; the three attempts from the game container fail; the router's connections are not counted by `MCCTL-INGRESS`. |
| 19 | Spike S2: start one `itzg/minecraft-server` and one `itzg/mc-backup` as `create` renders them; check that `rcon-cli` needs no password argument, that the sidecar reads `RCON_PASSWORD_FILE` and reaches RCON at `127.0.0.1`, and that `backup now` writes an archive. | If the sidecar can read a per-restart password without a shared file, record it (the plan's default of one password per server stands unless this says otherwise). |
| 20 | Firewall effect: from one source open 12 quick connections to port 25565; a normal client still joins; reboot the host. | Connections past the limit are cut; after the reboot `MCCTL-INGRESS` and `MCCTL-EGRESS` exist again (the guard rebuilt them) and the firewall state is as before. |
| 21 | Backup methods: local at a short interval (`--backup local --backup-interval 5m`), check `prune`; optionally restic or rsync if credentials exist. | Archives appear on schedule; `prune` keeps the configured count, and it removes the oldest names, not the newest: the archive order comes from the names, so run `prune` on the names `itzg/mc-backup` really writes before any `PRUNE_BACKUPS_COUNT` is used in production; the optional methods pass or are marked N/A. |
| 22 | Cleanup: `delete` every test server; check Cloudflare for leftover `mcctl name=` records; `mcctl down`; `firewall rollback` if the host is reused. | No record, container, volume or mcctl iptables chain remains; `trash/` holds one archive per deleted server. |

## 6. What to do with the results

PASS everywhere: close the plan, and replace the "not yet recorded" words in `prerequisites.md` with the real versions. A FAIL: write the cause and fix in `troubleshooting.md` when it is an operator matter, or a bug against the owning task (the table above names it) when it is code. Re-run only the failed steps and any step that depends on them.

## 7. Not covered

IPv6; a host behind NAT with no public IP; Bedrock; Velocity (docs only); load testing beyond step 20.
