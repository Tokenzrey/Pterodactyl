# mcctl command reference

One section per command, in the order the commands were added. `mcctl help` lists every command that exists. Exit codes
are the same everywhere: 0 ok, 1 failure, 2 usage, 3 preflight or configuration invalid, 4 refused for safety.

## Configuration

Settings live in `config/mcctl.env` (copy `config/mcctl.env.example`; the copy is not tracked by Git). Every command except
`help`, `version`, and `doctor` loads and validates it first and exits 3, naming each bad key, when a value is invalid.

| Key | Default | Meaning |
|---|---|---|
| `MCCTL_DNS` | `on` | `on`: one DNS record per server in Cloudflare. `off`: local play, no Cloudflare, no token, no zone (see [Local play](#local-play-mcctl_dnsoff)). |
| `MCCTL_DOMAIN` | none (`mc.local` when `MCCTL_DNS=off`) | Servers become `<name>.MCCTL_DOMAIN`. A lower-case host name with at least one dot, no scheme, no path. |
| `MCCTL_PUBLIC_IPV4` | none | Public IPv4 address the DNS records point at. Needed with `MCCTL_DNS=on` only. |
| `MCCTL_CF_ZONE_ID` | none | Cloudflare Zone ID of the zone that holds `MCCTL_DOMAIN` (letters and digits only). Needed with `MCCTL_DNS=on` only. |
| `MCCTL_GAME_SUBNET` | `172.30.0.0/24` | Private IPv4 network of the game containers, `/16` to `/29`, no host bits set. |
| `MCCTL_ROUTER_IP` | `172.30.0.2` | Fixed address of mc-router inside that network: not the network, first (gateway) or broadcast address. |
| `MCCTL_DOCKER_SOCKET` | `/var/run/docker.sock` | The Docker socket whose group mc-router is given (`group_add`), so that it can reach the API as a non-root user. Change only for a non-default socket. |
| `MCCTL_DOCKER_GID` | (set by mcctl) | Not a setting: `stack_dc` sets it to the group of `MCCTL_DOCKER_SOCKET` before each compose call. |
| `MCCTL_CONN_LIMIT` | `10` | Per-source connection limit on 25565 (integer 1 to 65535). |
| `MCCTL_RATE` | `10/second` | New-connection rate limit per source on 25565 (`N/second`, `N/minute`, `N/hour`). |
| `MCCTL_SSH_PORTS` | empty | SSH ports to keep open (comma list). When empty, detected from `sshd -T`, `ss`, `$SSH_CONNECTION`. |
| `MCCTL_FIREWALL_ROLLBACK_SECONDS` | `300` | Dead-man timer seconds after `firewall apply` (0 to 3600; 0 disables). |

Rules:

- The file is parsed, never executed. Only `MCCTL_KEY=value` lines are read; a value may use letters, digits and
  `. _ : / @ , + = % -`, optionally in quotes, with a trailing `# comment`. Anything else (`$(...)`, a key such as `PATH`) is
  refused with the file name and line number.
- A value already set in the environment wins over the file. An empty value counts as not set.
- `MCCTL_ROOT` (the folder that holds `config/`, `secrets/` and `servers/`) comes from the environment only and must be an
  absolute path. It defaults to the folder that holds `./mcctl`.
- A key a command needs but that is empty stops that command with exit 3 and a message naming every missing key.
- Credentials are never settings. The Cloudflare API token is the file `secrets/cloudflare_token` (mode 600; see
  [Cloudflare DNS](#cloudflare-dns)).
- With `MCCTL_DNS=on` (the default), `create`, `delete`, `clone`, `rename` and `import` need `MCCTL_DOMAIN`, `MCCTL_PUBLIC_IPV4` and `MCCTL_CF_ZONE_ID`. With `MCCTL_DNS=off` none of them is needed.
- `MCCTL_PUBLIC_IPV4` is the address the world sees: the game-port DNS records are DNS-only (not proxied), so anyone who
  looks the name up learns it.

### Variables mcctl sets itself

These are set by the `mcctl` script and its monitor code, not read from `config/mcctl.env`. `MCCTL_HOME` is the folder of `mcctl`, found from the script's own path; `MCCTL_VERSION` is what `mcctl --version` prints. Both are overwritten at each start, so setting them in the environment has no effect. `_MCCTL_UTF8_KEY` and `_MCCTL_UTF8_CACHE` are the monitor's cached check that the terminal is UTF-8; they are not for the operator.

`MCCTL_ROUTER_BIND` is the address the router's game port is published on: `127.0.0.1` with `MCCTL_DNS=off`, `0.0.0.0` with `on`. `MCCTL_DOCKER_GID` is the group of the Docker socket, given to the router (`group_add`); both are set by `stack_dc` before each compose call.

## mcctl init

```
mcctl init
```

Creates `secrets/` and `servers/` under `MCCTL_ROOT` with mode 700 (a parent it has to create is 700 too). It is safe to
run again: it puts the mode back to 700 and leaves what is inside alone. It makes no Docker, network or Cloudflare call and
creates no configuration file; it tells you to copy `config/mcctl.env.example` to `config/mcctl.env` when that is missing.

## mcctl doctor

```
mcctl doctor
```

Checks the host and prints one line per check, `[ok]` or `[FAIL]`, then exits 3 if any failed. It never stops at the first
failure and never prints a secret.

| Check | Fails when |
|---|---|
| `config` | `config/mcctl.env` or the environment holds an invalid value (the errors are printed above the line) |
| `bash` | bash is older than 4.4 |
| `docker compose` | `docker compose version` fails (Docker Engine with the Compose v2 plugin is required) |
| `jq`, `curl` | the command is not on `PATH` |
| `secrets/<file>` | a file in `secrets/` is not mode 600 (400 is accepted). The line says `run: chmod 600 secrets/<file>`. |

`secrets/` not existing yet is not a failure: run `mcctl doctor` before `mcctl init` on a new machine.

## Servers: how mcctl knows them

Docker is the record. A server exists when a container carries the label `mcctl.name=NAME`; `mcctl list` asks Docker and never
reads `servers/`. The folder `servers/NAME/` only holds the server's files: `server.env` and `modpack.env` (what you chose),
`compose.yaml` (generated from them, never edited by hand), `data/` (the world, mods and configs) and `backups/`. The RCON
password is the file `secrets/rcon-NAME` (mode 600), outside the folder. A server name is 1 to 40 characters of lower-case
letters, digits and `-`, starting with a letter or digit. When Docker cannot be asked (daemon down, no permission) a command
stops with exit 1 and says so; it never treats that as "no such server". Each server also has one Cloudflare DNS record (below),
and `mcctl delete` leaves an archive of its world and backups in `trash/` (not tracked by Git).

## Local play (`MCCTL_DNS=off`)

For playing on one machine, no domain and no Cloudflare account are needed:

```
# config/mcctl.env
MCCTL_DNS=off                  # MCCTL_DOMAIN may stay empty: the names are <name>.mc.local
```

```
./mcctl up
./mcctl create s1 --type PAPER --accept-eula
./mcctl start s1
```

- No DNS record is made, no Cloudflare call is made, and no token is read. `doctor` and the preflight say so.
- The names only have to resolve on the machine the Minecraft client runs on. Add the line `127.0.0.1 s1.mc.local` to its hosts file
  (Windows: `C:\Windows\System32\drivers\etc\hosts`, edited as Administrator). `create`, `clone`, `rename` and `import` print this line.
- The game port is published on `127.0.0.1` only (`MCCTL_ROUTER_BIND`): other machines on the network cannot join. Change
  `MCCTL_DNS` and run `./mcctl up` again so the router is made again with the new address.
- `delete` removes no DNS record when DNS is off. A record made while DNS was on stays in Cloudflare until you remove it there.

## Cloudflare DNS

With `MCCTL_DNS=on` (the default). With `MCCTL_DNS=off` this section does not apply: see [Local play](#local-play-mcctl_dnsoff).

Players reach a server at `HOST.MCCTL_DOMAIN` (HOST is `--hostname`, by default the server name). `create` makes that name an A
record in the Cloudflare zone `MCCTL_CF_ZONE_ID`, pointing at `MCCTL_PUBLIC_IPV4`, and `delete` removes it. Every record mcctl makes is:

- **DNS-only** (`proxied: false`, TTL 120 s). Cloudflare's proxy does not carry Minecraft, so the name resolves to this machine's real
  public address: anyone who looks it up learns it. mcctl does not hide the origin IP and these docs do not claim it does.
- **Marked** with the comment `mcctl name=<server>`. mcctl deletes only records whose comment starts with `mcctl `, and never changes or
  overwrites any record: when the zone already has a record of the same name, `create` refuses (exit 4), shows the record (type, address,
  comment) and writes nothing. Remove it in the Cloudflare dashboard or pick another `--hostname`. If the comment says `mcctl name=X`, it is
  left over from a server X that is gone: `mcctl delete X` removes it.

**The API token** is the file `secrets/cloudflare_token`, mode 600, the token alone on one line. Create it in the Cloudflare dashboard
(My Profile, API Tokens, Create Token) with the permission **Zone, DNS, Edit** for the zone of `MCCTL_DOMAIN` only. Make the file without
putting the token in your shell history:

```
(umask 077; read -rs -p 'Cloudflare API token: ' t; printf '%s\n' "$t" > secrets/cloudflare_token)
```

mcctl reads the file only to hand the token to `curl` on its standard input, as a curl configuration line (`curl --config -`): it is
never a command-line argument (so not in `ps` or shell history) and never printed. A file that holds anything but one token on one line
is refused (exit 3) before any request. Every request is HTTPS only and gives up after 30 seconds; `curl` and `jq` must be installed
(`mcctl doctor` checks both).

With `MCCTL_DNS=on`, `create` and `delete` need `MCCTL_DOMAIN`, `MCCTL_PUBLIC_IPV4`, `MCCTL_CF_ZONE_ID` and the token file; without any of them they stop with
exit 3 before anything is asked or changed. To find a server's records, `delete` asks Cloudflare for the records whose comment is
exactly `mcctl name=<server>` and whose name is a single label under `MCCTL_DOMAIN`, so it finds them even when the server's folder is gone.

## mcctl create

```
mcctl create NAME --type TYPE --accept-eula [--version V] [--memory 4G] [--cpus 2] [--hostname H]
             [--modpack-source curseforge|modrinth --modpack ID [--modpack-version V]]
```

Makes the server but does not start it: the container exists in the state `created`. Start it with `mcctl start NAME`.

| Flag | Default | Meaning |
|---|---|---|
| `--type` | none (required) | The itzg server type, upper-cased: `PAPER`, `FABRIC`, `FORGE`, `VANILLA`, ... A modpack source sets it itself (`AUTO_CURSEFORGE`, `MODRINTH`); leave `--type` out then. |
| `--accept-eula` | none (required) | You agree to the Minecraft EULA, <https://aka.ms/MinecraftEULA>. Without it `create` refuses (exit 2). `server.env` gets `EULA=TRUE` only through this flag; nothing accepts it for you. |
| `--version` | `LATEST` | Game version (`1.21.1`, `LATEST`, `SNAPSHOT`). With a modpack the pack decides, unless you give one. |
| `--memory` | `4G` | JVM heap (`2G`, `1536M`). The container limit is set 25% plus 256 MiB above it. |
| `--cpus` | `2` | CPU limit, more than 0 (`2`, `1.5`). |
| `--hostname` | the name | The label players use: `HOST.MCCTL_DOMAIN`. Lower-case letters, digits and `-`, not ending in `-`. Two servers cannot share one. |
| `--modpack-source`, `--modpack`, `--modpack-version` | none | The pack, written to `modpack.env` (see below). |

Order:

1. Every flag is checked (all problems are printed, nothing is touched; exit 2), then the configuration (exit 3, see below).
2. The name and the hostname are checked against Docker (exit 4 when taken; the message names the server that has the hostname).
3. The DNS record `HOST.MCCTL_DOMAIN` is made (see [Cloudflare DNS](#cloudflare-dns)). A record of that name that already exists is
   refused (exit 4); a request that fails is exit 1. Either way nothing has been written yet.
4. The files are written (`data/` and the RCON secret are given to the game's user first: see [RCON](#rcon-how-mcctl-talks-to-a-server)),
   the server's SFTP user is added (see [mcctl sftp](#mcctl-sftp); a failure there only prints a warning), then `docker compose create`
   runs. mc-router needs no signal: it follows Docker's events.

If any step after the DNS record fails, what was done is taken back in reverse order: first the containers `compose create` may
have made, then the DNS record, then the folder and `secrets/rcon-NAME`. When removing the containers fails, the folder, the secret
and the record are all kept, so no container is left without its folder or its record; the message says to run `mcctl delete NAME`.
When only the DNS record cannot be removed, the warning names it and `mcctl delete NAME` removes it later. A DNS request whose answer
was lost (a timeout) may still have made the record, so a failed request is followed by a look-up that deletes any mcctl record of that
name. A folder `servers/NAME` that exists while Docker has no such server is a leftover of an interrupted create or delete: `create`
refuses (exit 4) and leaves it alone.

With `MCCTL_DNS=on` needs `MCCTL_DOMAIN`, `MCCTL_PUBLIC_IPV4`, `MCCTL_CF_ZONE_ID` and `secrets/cloudflare_token` (exit 3 without any of them). With `MCCTL_DNS=off` it needs none of them.
### Modpacks

`--modpack-source` picks the platform, `--modpack` is the pack and `--modpack-version` pins a version (leave it out for the
latest). `create` writes the matching itzg variables to `modpack.env`; the platform is also `--type` (`AUTO_CURSEFORGE` or
`MODRINTH`), so do not pass `--type`. Both values are checked first: the pack is letters, digits, `.`, `_` and `-` (no space,
`=` or newline), at most 100 characters; a wrong value exits 2 and nothing is written.

| Source | `--modpack` | `--modpack-version` | Written to `modpack.env` |
|---|---|---|---|
| `curseforge` | the pack's slug: the last part of its CurseForge page URL, for example `all-the-mods-10` | a file id (digits), for example `9190157` | `MOD_PLATFORM=AUTO_CURSEFORGE`, `CF_SLUG`, `CF_FILE_ID` |
| `modrinth` | the slug or the project id | a version id or number, for example `5.0.1` | `MOD_PLATFORM=MODRINTH`, `MODRINTH_MODPACK`, `MODRINTH_VERSION` |

A CurseForge pack given as a number (a project id) is refused: the image selects a pack by slug, not by project id.

**CurseForge API key.** A CurseForge pack needs your CurseForge API key (get one at <https://console.curseforge.com>). It is
the file `secrets/curseforge_api_key`, mode 600, the key alone on one line, shared by every CurseForge server. `create` exits 3
before it touches anything when that file is missing or empty. Make the file without putting the key in your shell history:

```
(umask 077; read -rs -p 'CurseForge API key: ' k; printf '%s\n' "$k" > secrets/curseforge_api_key)
```

mcctl only checks that the file has content; it never prints or passes on the key. The generated `compose.yaml` of a
CurseForge server lists the file as a compose secret (mounted read-only at `/run/secrets/cf_api_key` in the game container
only) and passes it to the image as `CF_API_KEY_FILE`; the key is never a value in `server.env`, `modpack.env`,
`compose.yaml`, a command line or the output. A plain `CF_API_KEY` in `modpack.env` is refused (exit 4), and so is
`CF_API_KEY_FILE` on a CurseForge server (exit 3): mcctl sets that one. Deleting a server leaves the key file alone. A server
counts as a CurseForge server when `TYPE`, `MOD_PLATFORM` or `MODPACK_PLATFORM` is `AUTO_CURSEFORGE`. `mcctl doctor` checks
the mode of the key file like that of every file in `secrets/`.

## mcctl start, stop, restart

```
mcctl start NAME
mcctl stop NAME
mcctl restart NAME
```

`docker compose start`, `stop` or `restart` for both containers of the server (the game server and its backup sidecar). `stop`
and `restart` give the game server up to 60 seconds to save the world and shut down. An unknown server is exit 1; a name that
cannot be a server is exit 2.

## mcctl kill

```
mcctl kill NAME
```

`docker compose kill`: the server gets no chance to save, so whatever it had not saved is lost and the world can be damaged. It
asks first; with no terminal it refuses (exit 4) unless you pass `--yes` or set `MCCTL_YES=1`. Use `mcctl stop NAME` unless the
server is stuck.

## mcctl edit

```
mcctl edit NAME [--memory SIZE] [--cpus N]
```

Changes the memory and CPU limits of a server. At least one of `--memory` or `--cpus` is required. It regenerates
`servers/NAME/server.env` and `servers/NAME/compose.yaml` and recreates the containers so the new limits take effect.

| Flag | Meaning |
|---|---|
| `--memory` | JVM heap (`2G`, `1536M`). The container limit is set 25% plus 256 MiB above it. |
| `--cpus` | CPU limit, more than 0 (`2`, `1.5`). |

What is rewritten: the `MEMORY=` and `CPUS=` lines of `server.env` are replaced in place (appended when absent); every other
line and comment is kept byte for byte. `compose.yaml` is regenerated from `server.env` and `modpack.env`. Both files are
written atomically (a temp file beside the target, then `mv`), so a failed write leaves the old file and no temp behind.

Three outcomes:

- **Live server, 0 players online:** asks `Restart NAME now to apply ...?`. A yes (or `--yes`) recreates and restarts; a no
  (or no terminal without `--yes`) exits 4 and changes nothing.
- **Live server, players online:** refuses without `--yes` (exit 4), naming the count. With `--yes` it recreates, disconnecting
  the players. When RCON cannot be asked or the reply does not parse, the count is unknown and counts as players online: `--yes`
  is required.
- **Stopped server:** no question. The new `compose.yaml` is applied with `docker compose create --force-recreate` (not `up`),
  so the new container exists but stays stopped. `docker compose start` would start the old container with its old limits; a
  changed `compose.yaml` is ignored by `start`.

The whole compose project is recreated (`docker compose up -d --force-recreate` with no service name, or `create
--force-recreate`), never `mc` alone: the backup sidecar shares the game container's network namespace
(`network_mode: "service:mc"`), so recreating `mc` alone would leave the sidecar attached to a dead namespace. After a live
recreate, mc-router needs no signal: it follows Docker's events.

Exit codes: 0 applied, 1 Docker failure or unknown server, 2 bad input (invalid name, missing option, invalid value), 4 refused
(players online without `--yes`, or a declined confirmation).

An `edit` with values equal to the current ones still writes and recreates: it doubles as "apply again". No other command
re-applies before Task 14.

| Troubleshooting | |
|---|---|
| Files written but the recreate failed | The `server.env` and `compose.yaml` are already on disk with the new values. Run the same `mcctl edit NAME --memory ... --cpus ...` again to re-apply; it writes the same values and recreates. |

## mcctl version, upgrade, type, reinstall

These four change what a server runs, then recreate its containers. Each one that can damage a world takes a snapshot first
(see "Snapshots" below), and a refusal or a failed snapshot changes nothing.

```
mcctl version NAME show
mcctl version NAME set V [--allow-downgrade]
mcctl upgrade NAME [--to V] [--allow-downgrade]
mcctl type NAME set TYPE [--loader-version V]
mcctl reinstall NAME [--timeout SECONDS]
```

**version.** `show` prints `VERSION` and `TYPE`. `set` writes `VERSION` (`1.21.1`, `LATEST`, `SNAPSHOT`, ...) and recreates the
containers. A version older than the current one is refused (exit 4) unless `--allow-downgrade`: a world saved by a newer version
can be damaged by an older one. Versions compare as dotted numbers, with trailing `.0` ignored (`1.20` is `1.20.0`; `1.9` is
older than `1.10`). `LATEST`, `SNAPSHOT`, a snapshot such as `24w14a` and a pre-release such as `1.21-pre1` cannot be compared,
so the change asks `confirm` (`--yes` answers it). A modpack server is refused: its pack decides the version (`mcctl modpack NAME
update`).

**upgrade.** A snapshot, then `docker compose pull` (the newest itzg image), then a recreate. The image does not fix the
Minecraft version: `VERSION=LATEST` is resolved again at every start, so the new version appears at the next start. `--to V`
writes `VERSION` first, with the same downgrade rule. A modpack server is refused. A failed snapshot or a failed pull changes
nothing.

**type.** `set` changes the type to a plain one: `VANILLA FORGE NEOFORGE FABRIC QUILT PAPER PUFFERFISH PURPUR LEAF FOLIA SPIGOT
BUKKIT` (`docs/single-standalone/server-types.md`). `AUTO_CURSEFORGE` and `MODRINTH` are set only by `mcctl modpack`. The loader
variables of the other types are removed (after a switch to `FABRIC`, no `FORGE_VERSION` is left). `--loader-version V` writes
the variable of the type: `FORGE_VERSION`, `NEOFORGE_VERSION` or `FABRIC_LOADER_VERSION`; a type without one refuses it.

A switch away from a mod loader (its `mods/` folder) or a plugin type (its `plugins/` folder) is refused while that folder holds
jars; the message gives the count. `--yes` switches anyway, and the jars are kept.

**reinstall.** For a server whose installer must run again. It sets the one-shot flag of the type (`FORGE_FORCE_REINSTALL`,
`FABRIC_FORCE_REINSTALL`, or `FORCE_REDOWNLOAD` for `PUFFERFISH` and `PURPUR`; `docs/single-standalone/server-types.md`) and recreates
the containers with it. It then waits until the running server reports `healthy` (`--timeout`, 600 seconds by default), removes the
flag from `server.env` and `compose.yaml`, and recreates the containers once more, so the flag is in their environment only while
the installer runs. The second recreate happens even after a timeout, which then exits 1. A type without a flag exits 2. A stopped
server is refused (exit 4, nothing changed): start it first. There is no snapshot: the installer does not write the world.

**modpack.** Four subcommands; the pack's variables are in `modpack.env`, and the platform is `TYPE`.

```
mcctl modpack NAME info
mcctl modpack NAME set --source curseforge|modrinth --pack ID [--version V]
mcctl modpack NAME update [--latest | --version V] [--clean [--timeout SECONDS]]
mcctl modpack NAME remove --type TYPE [--version V] [--loader-version V] [--purge-mods]
```

- `info` prints the source, the pack and `pinned V` or `latest`, from `modpack.env`. Then it asks the running container for
  `MODPACK_NAME` and `MODPACK_VERSION` (`printenv`). The itzg names are placeholders for other variables' values
  (`docs/single-standalone/configuration.md`), so they are often not in the environment: the line then says
  `resolved name/version: unknown`. That is normal, not an error. A server with no modpack prints `no modpack`.
- `set` checks the pack first (exit 2 for a bad source or id; a CurseForge pack also needs the key file, exit 3, see "CurseForge
  API key" above). Then it takes a snapshot, asks `confirm`, writes `modpack.env` and `TYPE`, removes any `VERSION` (the pack
  decides it), and recreates. A declined confirm (exit 4) leaves `server.env` and `modpack.env` as they were.
- `update` on a pinned pack (`CF_FILE_ID` or `MODRINTH_VERSION` in `modpack.env`) refuses (exit 2) and prints the pin, unless
  `--version V` (a new pin) or `--latest` (no pin) says what to do. Without options on an unpinned pack it recreates, so the
  newest pack is installed at the start.
- `update --clean` takes a snapshot, then recreates the running server with `REMOVE_OLD_MODS=TRUE`, waits for it to report `healthy`
  (`--timeout SECONDS`, 600 by default; `--timeout` works only with `--clean`), and recreates it once more without the flag, so no
  restart later deletes `mods/`. itzg's warning (quoted by mcctl): all content of the `mods` or `plugins` directory is deleted before
  the pack is unpacked, so every mod in `mods/` goes, also the ones the pack does not have. A stopped server is refused (exit 4):
  start it first.
- `remove` needs `--type`, the plain type the server runs now (`FORGE`, `FABRIC`, `PAPER`, ...). Without `--version` a server with
  no `VERSION` is refused (exit 4): it would run the image's `LATEST`, and a newer version can upgrade the world. The mods stay
  unless `--purge-mods`, which needs a stopped server (exit 4 otherwise) and removes the contents of `mods/` after the snapshot.
  `modpack.env` is emptied.

**Snapshots.** Every snapshot is a full copy of `data/` (`snapshot_members`: a running server is quiesced with `save-off` and
`save-all flush`, then `save-on`), written to `servers/NAME/safety/pre-<command>-<UTC>.tar.gz` (`pre-version`, `pre-upgrade`,
`pre-type`, `pre-modpack-set`, `pre-modpack-update`, `pre-modpack-remove`) and read back before the change goes on. The folder is
not pruned: `mcctl backup NAME prune` reads only `backups/`, and it would delete the oldest archive there, the pre-change snapshots
included. `mcctl delete` keeps `safety/` in its archive. Nothing removes these files but you.

| Troubleshooting | |
|---|---|
| The files are written but the recreate failed | The new `server.env` and `compose.yaml` are on disk. Run the same command again to recreate. For `reinstall` the flag is already removed; run it again. |
| `upgrade` or `version` says a snapshot failed | Nothing changed. Read the message from the snapshot (for example Docker not running, or the helper image cannot be pulled). |

## mcctl delete

```
mcctl delete NAME
```

Removes the server: its containers, its DNS record, `servers/NAME` and `secrets/rcon-NAME`. Its world, mods and backups are kept
in an archive first. It asks first, and the question names the archive; with no terminal it refuses (exit 4) unless you pass `--yes`
or set `MCCTL_YES=1`. In this order, each step safe to run again:

1. `docker compose stop`, so the archive does not catch a world that is being written.
2. `data/`, `backups/` and `safety/` (the world archives taken by `world` commands) are written to `trash/NAME-<UTC time>.tar.gz` (for example `trash/survival-20261024T101500Z.tar.gz`, mode
   600), beside its final name first and moved into place, then read back in full (`tar -tzf`). If that fails, `delete` refuses
   (exit 4) and removes nothing; the server stays stopped (`mcctl start NAME`).
3. The DNS records mcctl made for the server are deleted (see [Cloudflare DNS](#cloudflare-dns)). This comes before the containers
   so that a record never outlives its server. If it fails (Cloudflare refuses or cannot be reached), `delete` stops (exit 1) with a
   warning that names the record: nothing has been removed, the server is only stopped, and running `mcctl delete NAME` again once
   Cloudflare answers starts clean.
4. `docker compose rm -s -f`. If it fails, `delete` stops (exit 1): the DNS record is gone, the containers and the folder are still
   there, and running it again finishes the job.
5. The server's SFTP user and key file are removed (see [mcctl sftp](#mcctl-sftp); a failure there only prints a warning). Then a
   helper container removes `data/`, `backups/` and `safety/`: they were archived in step 2, and they belong to the game's user (root
   may own files in `backups/`), which the host user cannot remove. Last, `servers/NAME` and `secrets/rcon-NAME` are deleted. If the
   helper fails, `delete` stops (exit 1): the containers and the DNS record are gone, the folder and the secret are left, and the next
   `mcctl delete NAME` finishes.

Step 2 is skipped for a folder that has none of `data/`, `backups/` and `safety/`, and the question says so. When nothing is left of a server
but its DNS record (a `create` whose clean-up could not reach Cloudflare says so and points here), `delete NAME` removes the record,
and that is all it does, without asking.

- A server that is not in Docker, has no folder and no DNS record of its own is exit 1.
- Safe to run again: if the containers are already gone (someone ran `docker rm`, or an earlier run stopped half way) but the
  folder is still there, `delete` finishes the job.
- If Docker has the containers but `compose.yaml` is missing, `delete` stops (exit 1) and tells you to remove `mc-NAME` and
  `mc-NAME-backup` with `docker` first.
- `trash/` is never emptied by mcctl: each delete adds one archive, and it stays until you remove it
  (`tar -tzf trash/FILE` lists one; `tar -xzf trash/FILE -C somewhere` unpacks it). A delete that is run again after a failure
  writes a second archive.

## mcctl list

```
mcctl list
```

One row per container that carries `mcctl.managed=true`: name, Docker state (`created` = made but never started), the address
(`HOST.MCCTL_DOMAIN`) and Docker's status text. With no servers it prints a hint and exits 0.

## mcctl status

```
mcctl status NAME
```

Prints the state of the game container (with its health when the image reports one), the address players use, the image, the
`config:` line (current or pending, see [Settings](#mcctl-set-get-unset-env-apply)), and when it started (only while it runs).
An unknown server is exit 1.

## mcctl java

```
mcctl java NAME set 17|21|25|default
```

Chooses the Java version of the server's image. The image is `itzg/minecraft-server:javaN` for 17, 21 or 25; `default` removes the choice and
uses the image's default, which is the newest Java (25 at the time of writing).

**Why it matters.** Forge 1.20.1 and most mods of that era run on Java 17. On Java 25 they fail at start with
`Unsupported class file major version 69`. A server made from an older modpack needs `17`.

```
mcctl create deceased --modpack-source curseforge --modpack deceasedcraft --modpack-version FILE_ID --accept-eula
mcctl java deceased set 17
mcctl start deceased
```

The value is the structural key `JAVA` in `server.env`. It is not an environment variable of the game container, and `mcctl set` refuses
it (use `mcctl java`). The change is applied at once: a running server is recreated with the new image, a stopped one is made again
(still stopped). `clone`, `export` and `import` carry the value.

## mcctl set, get, unset, env, apply

```
mcctl set NAME KEY=VALUE... [--apply] [--force]
mcctl get NAME KEY
mcctl unset NAME KEY...
mcctl env NAME
mcctl apply NAME
```

A setting is one `KEY=VALUE` line of `servers/NAME/server.env` (the itzg variables: `MOTD`, `MAX_PLAYERS`, `PVP`, ...). `set`
validates every pair first and writes nothing unless all of them pass. The file is written in one go and `compose.yaml` is
rendered from it. Without `--apply` the answer is `config pending: mcctl apply NAME`. `--apply` applies the change at once (see
apply). `--force` stores a KEY that is not a known setting (it never lifts a refusal from the lists below).

`get` prints the value and exits 1 when the key is not set. `unset` removes keys (a structural key is refused). `env` prints
`server.env` without its comments. KEY is capitals, digits and `_`, starting with a letter.

### The pending model

A change reaches the running server only through `apply`, never through `set`. `status` shows one line:

| `config:` | Meaning |
|-----------|---------|
| `current` | the container runs the configuration in `server.env` |
| `pending (mcctl apply NAME)` | the configuration differs from the one the container was made with |
| `unknown (created before tracking; mcctl apply NAME stamps it)` | the container has no `mcctl.config_hash` label: it was made before this version |
| `unknown (server.env does not render; mcctl apply NAME shows why)` | `server.env` or `modpack.env` is not valid |

`apply` compares the same hash. Equal: `nothing to apply`, and Docker compose is not called. Otherwise `compose.yaml` is
written, then the players are checked: with none online it asks to confirm; with players online, or when the answer cannot be
read, `--yes` is required, and without it the command exits 4 with nothing changed (the config stays pending). Then the whole
compose project is recreated (`up -d --force-recreate`; a stopped server is created with
`create --force-recreate`).

The one-shot keys `*_FORCE_REINSTALL`, `FORCE_REDOWNLOAD` and `REMOVE_OLD_MODS` are left out of the hash: setting one does not make
the configuration pending, and `apply` does not recreate for it.

### Keys and types

| Key | Type | Accepts |
|-----|------|---------|
| `MOTD`, `LEVEL_TYPE`, `SEED`, `OPS`, `WHITELIST` | text | up to 1000 characters |
| `MAX_PLAYERS`, `VIEW_DISTANCE` | int | a whole number, up to 9 digits |
| `DIFFICULTY` | enum | `peaceful`, `easy`, `normal`, `hard` (any case, stored in lower case) |
| `MODE` | enum | `survival`, `creative`, `adventure`, `spectator` |
| `PVP`, `HARDCORE`, `ALLOW_NETHER`, `ENABLE_WHITELIST`, `OVERRIDE_ICON`, `RESOURCE_PACK_ENFORCE` | bool | `true` or `false` (stored `TRUE` or `FALSE`) |
| `ICON`, `RESOURCE_PACK` | https URL | starts with `https://`, no space |
| `RESOURCE_PACK_SHA1` | SHA-1 | 40 hex digits (stored in lower case) |
| `GENERATOR_SETTINGS` | JSON | valid JSON, up to 8192 characters (stored compact) |

A key that `properties` maps (below) but that has no type here is stored as text.

### Always refused, even with `--force`

| What | Why |
|------|-----|
| a credential: a name ending in `PASSWORD`, `PASSWD`, `SECRET`, `TOKEN` or `_KEY` | a secret as a plain environment value would sit in `compose.yaml` and in `docker inspect`. Put it in a file under `secrets/` and set `KEY_FILE`. |
| the structural keys `TYPE VERSION MEMORY CPUS EULA HOSTNAME_SLUG BACKUP_ENV_FILE AUTOSTART JAVA` | they belong to the server's identity or have their own command: `mcctl edit` for `MEMORY` and `CPUS`, `mcctl autostart` for `AUTOSTART` |
| the reserved keys `RCON_PORT ENABLE_RCON RCON_PASSWORD_FILE CF_API_KEY_FILE` | `mcctl rcon`, the backup sidecar, `rotate-rcon` and the CurseForge key assume their defaults and files. itzg warns against changing the RCON port. |

## mcctl motd, icon, resourcepack, autostart

- `mcctl motd NAME TEXT`: `set MOTD=TEXT`.
- `mcctl icon NAME URL [--override]`: `set ICON=URL` (https only). `--override` also sets `OVERRIDE_ICON=TRUE`. A local icon file
  is not accepted yet; it comes with `files`.
- `mcctl resourcepack NAME URL --sha1 HEX [--enforce]`: the https URL and the 40-hex `--sha1` are both required. `--enforce` also sets
  `RESOURCE_PACK_ENFORCE=TRUE`.
- `mcctl autostart NAME on|off`: `off` writes `restart: "no"` on both services, the game container and its backup sidecar, so that
  a restart of the Docker daemon does not bring the server back. Takes effect at the next `apply`.

## mcctl properties

```
mcctl properties NAME list | get KEY | set KEY VALUE | dump
```

`KEY` is a `server.properties` name such as `max-players`. It maps to the itzg variable through the "Other Server Property
Mappings" table of the itzg notes (`docs/single-standalone/configuration.md` in the repository root); `list` prints that table, and
`max-players` is `MAX_PLAYERS`.
`rcon.port` and `rcon.password` are refused: the RCON port and password belong to mcctl (`mcctl rotate-rcon NAME` makes a new
password). A property that is not mapped exits 2. `dump` prints `data/server.properties` of the server with the RCON password
redacted; it says when the file does not exist yet.

## Settings troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| "I changed a setting and nothing happened" | The change is in `server.env`, and the running container keeps its old configuration until `apply`. `mcctl status NAME` says `pending`: run `mcctl apply NAME`. A `set --apply` does the same in one step. |

## mcctl list

## RCON: how mcctl talks to a server

Every server has a random RCON password, made once by `create` and kept in `secrets/rcon-NAME` (mode 600, 32 letters and digits). The
file belongs to the game's user (UID 1000): mcctl gives it to that user when it writes it (`create`, `rotate-rcon`, `import`), so the
server can read it, and the host user cannot read it back. `export --with-secrets` copies it through a read-only helper container.
The generated `compose.yaml` mounts it as a compose secret in the game container and in its backup sidecar and passes it on as
`RCON_PASSWORD_FILE`. mcctl never reads it: every command below runs `docker exec -i mc-NAME rcon-cli COMMAND...`, and `rcon-cli`
inside the container finds the password itself. The password is not in `server.env`, `compose.yaml`, an argument, the process list
or any output. `mcctl rotate-rcon NAME` replaces it. (That `rcon-cli` needs no password argument, and that the backup sidecar reads
`RCON_PASSWORD_FILE`, are not yet confirmed against the real images: acceptance spike S2.)

All of these commands need the server to exist (exit 1 otherwise) and to be running; a stopped server is exit 1 and the message
says `mcctl start NAME`. A server that has only just started can take a minute before RCON answers; the command then fails with
exit 1.

## mcctl rcon

```
mcctl rcon NAME COMMAND [ARGS...]
```

Sends one command and prints the server's reply, for example `mcctl rcon survival say hello` or `mcctl rcon survival time set day`.
This is the raw primitive: the words are passed to `rcon-cli` as they are (there is no shell in between, so `;` and `$` are only
text). Refused with exit 2, before Docker is asked: no command; a first word that starts with `-` (rcon-cli would read it as one
of its own options); any word that holds a control character (a newline, a carriage return, a tab). Negative numbers after the
first word are fine (`tp Notch -100 64 -200`).

## mcctl console

```
mcctl console NAME
```

`docker exec -it mc-NAME rcon-cli`: an interactive console (leave it with Ctrl-D). It needs a terminal; without one it exits 2 and
points at `mcctl rcon`.

## mcctl whitelist, ban, kick, op

```
mcctl whitelist add|remove SERVER PLAYER
mcctl whitelist list [--names]|on|off|reload SERVER
mcctl whitelist import SERVER FILE
mcctl ban SERVER PLAYER [--reason TEXT]
mcctl kick SERVER PLAYER
mcctl op SERVER PLAYER
```

Each sends the matching Minecraft command (`whitelist add Notch`, `ban Notch`, ...) and prints the reply. A player name is 1 to 16
letters, digits, `_` or `.` (a leading `.` is how Floodgate marks a Bedrock player). Anything else, such as `x; stop`, `@a`, or a name
with a space, is refused with exit 2 before Docker is asked and before anything is sent: the wrappers send a name and nothing else.
`--reason TEXT` is one argument of at most 100 characters with no control character (a `;` is allowed). The reason is an option,
not a third word: `mcctl ban SERVER PLAYER reason` is refused. To take a ban or operator status back, see `pardon` and `deop` below.

## mcctl players

```
mcctl players NAME
```

Prints who is online: the server's own reply to `list`.

## mcctl whitelist list --names, reload, import

```
mcctl whitelist list SERVER --names
mcctl whitelist reload SERVER
mcctl whitelist import SERVER FILE
```

`list --names` prints the names from the reply (`There are N whitelisted players: a, b`), one per line; an empty whitelist prints
nothing. Without `--names` the reply is printed as it is. `reload` sends `whitelist reload`.

`import` reads FILE, a local text file with one player name per line. Blank lines and lines starting with `#` are skipped, and a
CR at the end of a line is dropped. Every other line must be a valid player name. The whole file is checked before anything is
sent: one bad line refuses the file (exit 2), and the message gives its line number, never its text. A file of more than 500 lines
is refused. Then each name is sent as `whitelist add NAME`, with a progress line every 50 names. The import stops at the first
failed command, and the names before it stay added.

## mcctl banlist

```
mcctl banlist SERVER [--names]
```

Prints the server's ban reply. With `--names`, prints the name or address of each entry (the part before `was banned by`), one per
line; no entries print nothing. The layout of the reply differs a little between server versions, and is not checked against a real
server here.

## mcctl ban-ip, pardon, pardon-ip, deop

```
mcctl ban-ip SERVER ADDR [--reason TEXT]
mcctl pardon SERVER PLAYER
mcctl pardon-ip SERVER ADDR
mcctl deop SERVER PLAYER
```

`ADDR` is an IPv4 address (four decimal parts, each 0 to 255, no leading zero) or an IPv6 address (2 to 8 groups of 1 to 4 hex
digits, with `::` at most once, and at least two colons). `::1` has one group and is refused. Anything else is refused with exit 2
before Docker is asked. `--reason` is checked as for `ban`.

## mcctl ops

```
mcctl ops SERVER
```

Prints the operators' names from `servers/SERVER/data/ops.json`, read through the helper container that `mcctl files` uses. It works
on a stopped server. It prints `no operators` when the list is empty or there is no `ops.json`. Invalid JSON is an error (exit 1).
Vanilla has no command that lists operators, which is why this reads the file.

## mcctl say, save

```
mcctl say SERVER MESSAGE
mcctl save SERVER
```

`say` sends MESSAGE, 1 to 256 characters with no control character; quote it when it has spaces. `save` sends `save-all flush`,
which writes the world to disk now. Whether the server waits until the save is finished depends on its version; not checked here.

## mcctl gamerule, time, weather, worldborder

```
mcctl gamerule SERVER RULE [true|false|N]
mcctl time SERVER set day|night|noon|midnight|N
mcctl weather SERVER clear|rain|thunder [SECONDS]
mcctl worldborder SERVER get
mcctl worldborder SERVER set SIZE [SECONDS]
mcctl worldborder SERVER center X Z
```

- `gamerule`: RULE is a letter, then up to 63 letters, digits or `_`. Without a value the rule is read, otherwise it is set to
  `true`, `false` or a whole number of at most 9 digits.
- `time set`: N is a whole number of at most 8 digits.
- `weather`: SECONDS is 1 to 1000000.
- `worldborder set`: SIZE is 1 to 59999968, SECONDS 0 to 1000000. `center`: X and Z are whole numbers from -29999984 to 29999984.
  The limits are those this was written against; they are not checked against the installed server.

## mcctl difficulty, defaultgamemode

```
mcctl difficulty SERVER peaceful|easy|normal|hard [--persist]
mcctl defaultgamemode SERVER survival|creative|adventure|spectator
```

`difficulty` changes the running server. With `--persist` it also stores `DIFFICULTY=` (in lower case) in
`servers/SERVER/server.env` and prints `config pending`. The stored value reaches the containers with `mcctl apply SERVER`, which
recreates them (see Settings). The runtime change is sent first, so when it fails nothing is stored. A stopped server refuses both.

Every runtime command here needs a running server; on a stopped one it exits 1 and says `mcctl start`.

## mcctl rotate-rcon

```
mcctl rotate-rcon NAME
```

Makes a new RCON password (`secrets/rcon-NAME`, replaced atomically; the old one is not kept). The server and its backup sidecar read
the password when they start, so:

- a **running** server is restarted (`docker compose restart`, both containers), which disconnects its players. `rotate-rcon` asks
  first; with no terminal it refuses (exit 4) unless you pass `--yes` or set `MCCTL_YES=1`, and on a no it changes nothing;
- a **stopped** server just gets the new file, which applies the next time it starts; no question is asked.

If the restart itself fails (exit 1), the new password is already in place and applies at the next `mcctl restart NAME`. If the
secret cannot be written (for example `secrets/rcon-NAME` is a directory, which Docker makes when a bind-mounted file is missing),
the old password is unchanged and nothing is restarted.

## The router and the egress guard

Players connect to one public port, **25565**, which belongs to `mc-router`. It reads the host name in the Minecraft handshake
(`play.mc.example.net`) and forwards the connection to the game container whose `mc-router.host` label is that name; a bare IP address or
an unknown name matches nothing. Game containers publish no port. The router and the egress guard are one compose project,
`mcctl-stack`, defined in `templates/stack.compose.yml` and started by `mcctl up`. Game servers are separate projects (`mcctl-NAME`)
that join the network `mcctl_game`.

Two things to know about the router:

- It reads the Docker socket to discover game containers. The socket is mounted `:ro`, which is a read-only mount of the socket file,
  **not** a read-only Docker API: anything that can talk to the socket can still create containers. mc-router is trusted with that.
- It has a fixed address on the game network, `MCCTL_ROUTER_IP`, because the egress guard needs to name it.

**The egress guard** is a second container (`mcctl-egress-guard`, host network, `NET_ADMIN` and nothing else) that installs iptables
rules in the Docker host's network namespace so that game containers cannot reach the host, the LAN or the cloud metadata service. It
creates a chain `MCCTL-EGRESS`, puts one jump to it first in `DOCKER-USER`, and fills it in this order (a packet takes the first rule that
matches):

1. replies and related traffic (`ESTABLISHED,RELATED`): `RETURN`;
2. router to the game network (`MCCTL_ROUTER_IP` to `MCCTL_GAME_SUBNET`): `RETURN`. Without it rule 3 would also cut mc-router off from
   the servers it routes to, because the default game network lies inside `172.16.0.0/12`;
3. game network to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` (which holds `169.254.169.254`) and
   `100.64.0.0/10`: `DROP`.

There is **no rule that lets one game container reach another** (game network to game network), on purpose: a game server must not be
able to open connections to its neighbours. The default game network lies inside `172.16.0.0/12`, so rule 3 drops such traffic wherever
bridge traffic passes through iptables. The backup sidecar of a server does not need that path: the generated `compose.yaml` runs it
with `network_mode: "service:mc"`, in the network namespace of its server, so it reaches RCON over `localhost`, has no address of its own
and publishes nothing. (Both points, the drop and the shared namespace, are covered by tests against fakes and not yet checked on a real
Docker host.)

New connections from the game network to the host itself (SSH, anything bound to `0.0.0.0`, the bridge gateway) are dropped by a rule
in `INPUT`. Traffic to the public internet is not touched. The chain is flushed and refilled whenever the guard container starts, so a
changed subnet or router address leaves no stale rule; the old `INPUT` rule of a changed subnet stays (harmless) until the host reboots.

The guard is **healthy only when every one of these rules exists**, and mc-router does not start before it is healthy. If the host's
DNS server is on a private address (for example `192.168.1.1`), rule 3 is expected to stop name look-ups from game containers
(not yet checked on a real host); set a public resolver in Docker's `daemon.json` (`"dns": ["1.1.1.1"]`) if that happens.

## mcctl up

```
mcctl up
```

Starts the router stack. In order, and it stops at the first problem:

1. **Port check.** `ss -ltnp` must show nothing listening on 25565. If something does, `up` exits 3, prints the listener (the process
   and pid when your user may see them; otherwise run `ss -ltnp "sport = :25565"` as root) and creates nothing. When the listener is this
   stack's own router, `up` carries on, so it can be run again to update the stack. Typical cause: another mc-router, such as the one of
   a Pterodactyl stack on the same host: stop that first.
2. **Game network.** Creates `mcctl_game` with `MCCTL_GAME_SUBNET` when it does not exist. When it exists with a different subnet, `up`
   exits 3: the egress rules are written for `MCCTL_GAME_SUBNET`, so the network would be left unguarded. Change the setting back, or stop
   the game servers and run `docker network rm mcctl_game`.
3. **The stack.** `docker compose -p mcctl-stack up -d --wait`. This returns only when the egress guard is healthy; if it is not, `up`
   exits 1 and the router is not started. See why with `docker logs mcctl-egress-guard`. The guard installs iptables with `apk` when it
   starts, so the host needs to reach the Alpine package mirrors.
4. **SFTP.** The file `sftp.compose.yml` is generated again, then `docker compose -p mcctl-sftp up -d` starts the SFTP container (see
   [mcctl sftp](#mcctl-sftp)). This comes after the router, and a failure here (exit 1) leaves the router running: the message says so.

Needs `ss` (the `iproute2` package) and Docker with the Compose v2 plugin.

## mcctl down

```
mcctl down
```

Stops and removes the router stack (`docker compose -p mcctl-stack down`) and then the SFTP stack (`docker compose -p mcctl-sftp down`).
Players connected through the router are disconnected and nobody can join until `mcctl up`; SFTP users are disconnected too. The game
servers, the `mcctl_game` network and the egress rules are not touched (the rules belong to the Docker host and stay until it reboots
or the firewall is flushed); `mcctl up` rebuilds them.

## mcctl sftp

```
mcctl sftp add-key NAME PUBKEYFILE
mcctl sftp remove-key NAME
mcctl sftp repair
```

Files of a server over SFTP: one shared container (`atmoz/sftp`, container `mcctl-sftp`, compose project `mcctl-sftp`) with one user
per server, named after it. `mcctl create NAME` adds the user, `mcctl delete NAME` removes it. After login the user sees one folder,
`NAME/`, which is the server's `data/` (world, mods, configs), read-write as UID 1000, the user the game runs as. Nothing else of the
host is visible.

**Login is by key only.** No user has a password, so a user without a key cannot log in. Give the server's user a public key
(`ssh-keygen -t ed25519` makes one; the file ends in `.pub`):

```
mcctl sftp add-key survival ~/.ssh/id_ed25519.pub
```

The file must be an OpenSSH public key (`ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*`, `sk-*`), else `add-key` exits 2. Each call appends:
a server may have several keys. `remove-key NAME` deletes **all** keys of NAME, and NAME cannot log in until a key is added again
(to revoke one key, `remove-key`, then `add-key` the keys to keep). Only public keys are ever involved, and no command prints one.

**Connecting.** The port is published on `127.0.0.1:2222` of the host only, so it is not reachable from the internet. From the host
itself:

```
sftp -P 2222 -i ~/.ssh/id_ed25519 survival@127.0.0.1
```

From your own machine, tunnel through SSH first (`ssh -N -L 2222:127.0.0.1:2222 you@HOST`), then run the same `sftp` command there.
To publish the port on every address, set `MCCTL_SFTP_PUBLIC=1` (in the environment or in `config/mcctl.env`) and run `mcctl up`; only
key logins are possible either way, but a public SSH port is still one more thing on the internet, and the host's firewall must allow it.

### Connecting step by step

These steps connect from your own machine (Linux, WSL, Git Bash or PowerShell with OpenSSH, or FileZilla on Windows) to one
server's files. The SFTP port listens on the host's loopback only, so the connection goes through an SSH tunnel to the host.

**1. Check that the key is installed.** The public key of your device must be in `sftp-keys/NAME` on the host. On the host:

```
cat ~/mcctl/sftp-keys/NAME
```

Compare it with your own public key (`cat ~/.ssh/id_ed25519.pub` on the device): they must be the same line. If the file is missing,
copy your `.pub` file to the host and run `mcctl sftp add-key NAME PUBKEYFILE` there.

**2. Check that the SFTP container runs.** On the host:

```
docker ps --filter name=mcctl-sftp --format '{{.Names}} {{.Status}}'
```

It must show `Up`. If it does not, run `mcctl up`, which starts SFTP when there is a user. A `Restarting` status is covered in
[troubleshooting](troubleshooting.md#problems-outside-mcctls-messages).

**3. Open the tunnel.** On the device, in a terminal that stays open while you use SFTP:

```
ssh -N -L 2223:127.0.0.1:2222 -i ~/.ssh/id_ed25519_vps deploy@HOST
```

`-N` runs no shell, only the tunnel. `-L 2223:127.0.0.1:2222` means: a connection to port 2223 on the device goes to port 2222 as seen
from the host, which is the SFTP container. Replace `HOST` with the host's address, and `~/.ssh/id_ed25519_vps` with the key that logs
in to the host (not the SFTP key). The local port must be free on the device. Port 2222 is a poor choice on a laptop that also runs a
local mcctl, because it may already be in use there.

**4. Connect with `sftp`.** In a second terminal on the same machine:

```
sftp -P 2223 -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new NAME@127.0.0.1
```

- The user is the server's name (`NAME`), not `deploy`.
- `-i` is the **private** key whose public key is in `sftp-keys/NAME`. Its public half must match step 1.
- No password is asked for. A password prompt means the key was not used: check the path after `-i` and its permissions (`chmod 600`).
- On the first connection, `accept-new` accepts the server's host key. If the key changes later, see
  [troubleshooting](troubleshooting.md#problems-outside-mcctls-messages).

Inside `sftp`, the user sees one folder, `NAME/`, which is the server's data (world, mods, configs):

```
ls
cd NAME
ls
put /home/you/local-file.txt remote-name.txt
get remote-name.txt /home/you/copy.txt
bye
```

Use absolute paths on your own side. Remote paths are relative to the folder you are in.

**Windows and WSL.** A tunnel opened in Git Bash or PowerShell listens on Windows' `127.0.0.1`. A tunnel opened in WSL listens on
WSL's `127.0.0.1`. Programs on one side cannot use a tunnel on the other side (unless WSL's mirrored networking is on). Keys are per side
too: `~` in Git Bash is `C:\Users\<you>`, and in WSL it is `/home/<you>`. Use one environment for both the tunnel and the client, or copy
the key to the place the client reads.

**FileZilla (Windows).** FileZilla needs the tunnel from step 3 running on Windows, and the key in a format it accepts:

1. If FileZilla refuses the OpenSSH key, convert it: open PuTTYgen, **Load** the private key, then **Save private key** (a `.ppk`
   file). Keep the converted key private.
2. In FileZilla, open **File → Site Manager → New site** and set:
   - Protocol: **SFTP - SSH File Transfer Protocol**
   - Host: `127.0.0.1`
   - Port: `2223`
   - Logon type: **Key file**
   - User: `NAME`
   - Key file: the path of the `.ppk` (or the private key)
   - Password: leave it empty
3. Click **Connect** and accept the host key.

**Public mode (no tunnel).** To reach SFTP without a tunnel, set `MCCTL_SFTP_PUBLIC=1` in `config/mcctl.env` and run `mcctl up`. The port
then listens on every address, and the firewall allows `2222/tcp` (`mcctl firewall plan` shows it). Login is still key only, but the port
is on the internet and receives scans. Prefer the tunnel unless you need a public port.

**Host keys.** The SFTP server's host keys are kept in the Docker volume `mcctl-sftp-hostkeys` (full name
`mcctl-sftp_mcctl-sftp-hostkeys`). A recreated container keeps them, so clients do not see a new key. If you remove the volume on
purpose, every client must forget the old key first: `ssh-keygen -R "[127.0.0.1]:2223"`.

**How it is built.** SFTP is its own compose project, so the router stack keeps exactly one published port (25565). `sftp.compose.yml` in
`MCCTL_ROOT` is generated from `templates/sftp.compose.yml`; never edit it. It lists, for every user in `sftp-users.conf`, two mounts:
`servers/NAME/data` at `/home/NAME/NAME` (read-write) and, once a key exists, the key file `sftp-keys/NAME` read-only at
`/home/NAME/.ssh/keys/NAME.pub`, where `atmoz/sftp` looks for public keys. `sftp-users.conf` (mode 600) has one line per user,
`NAME::1000:1000:NAME`; `sftp-keys/` is mode 700 and its files mode 600; `sftp.compose.yml` is mode 644. A path that holds a control
character (a newline) or a `:` cannot be written into the file safely and is refused with exit 3, before any file is written.

**Changes reconnect everyone.** `atmoz/sftp` reads its users and keys only when it starts. So `add-key`, `remove-key`, `create`, `delete`
and `repair` regenerate `sftp.compose.yml` and, when the SFTP container is running, recreate it
(`docker compose -p mcctl-sftp up -d --force-recreate sftp`). **SFTP users are disconnected for a few seconds** and must reconnect;
game servers and the router are not touched. When the container is not running, only the file is written; `mcctl up` starts it.

**`mcctl sftp repair`** regenerates `sftp.compose.yml` and recreates the container when it runs. `create` and `delete` never stop for an
SFTP problem (a server must not be blocked by it): they print a warning that names the server and says to run `mcctl sftp repair` once the
cause is fixed. Run it after fixing the cause of a warning, after editing `sftp-users.conf` by hand, or when SFTP does not show a server's
files.

| Troubleshooting | |
|---|---|
| `WARN: NAME: SFTP could not be set up` after `create` | The server exists. Read the error above the warning (a path with a newline or `:`, a file where `sftp.compose.yml` belongs, a full disk), fix it, run `mcctl sftp repair`. |
| `up` says the router is up but SFTP did not start | Usually port 2222 is taken (`ss -ltn 'sport = :2222'`) or Docker could not pull `atmoz/sftp`. Fix it, run `mcctl up` again. |
| A user logs in but sees an empty folder, or cannot log in | `mcctl sftp repair`, then `docker logs mcctl-sftp`. Check that the key was added after the server was created (`ls sftp-keys/`). |

Not yet checked on a real host (acceptance run): that `atmoz/sftp` reads the key at `/home/NAME/.ssh/keys/NAME.pub` as its README says,
that a key login succeeds and shows the server's files as UID 1000, and how short the disconnect on a recreate is. The container keeps
only the capabilities `CHOWN`, `SETGID`, `SETUID`, `DAC_OVERRIDE` and `SYS_CHROOT` (sshd needs the last one to put each user in its folder).

## mcctl firewall

```
mcctl firewall plan
mcctl firewall apply
mcctl firewall confirm
mcctl firewall rollback
```

Puts a default-deny host firewall (ufw) in front of the VPS with SSH and the Minecraft router port open, and gives the
router port a per-source connection limit and a new-connection rate limit. A bad `apply` never locks the operator out:
SSH is allowed before the firewall is enabled, and a dead-man timer switches it off again unless you confirm from a new
session.

| Command | What it does |
|---|---|
| `plan` | No root needed, changes nothing. Prints the SSH ports that stay open, the policy, each ufw rule, the ingress limits, and whether the guard's ingress chain is active. |
| `apply` | Root only. Saves the previous ufw/iptables state, adds the rules, enables ufw, verifies every SSH port is accepted (or disables again at once), and arms a dead-man timer. |
| `confirm` | Root only. Stops the dead-man timer. The firewall stays on. |
| `rollback` | Root only. Disables ufw and stops the timer. |

**The dead-man timer.** When ufw is inactive before `apply`, a `systemd-run` timer switches the firewall off after
`MCCTL_FIREWALL_ROLLBACK_SECONDS` seconds (default 300). Open a **new** SSH session right after `apply`; if it works, run
`mcctl firewall confirm` from it to cancel the timer. If you cannot log in, do nothing: the firewall disables itself. Set
`MCCTL_FIREWALL_ROLLBACK_SECONDS=0` to skip the timer (not recommended on a remote VPS). Without `systemd-run` and a timer
wanted, `apply` refuses (exit 3) before touching anything.

**Why ufw does not filter the game port.** Port 25565 is published by Docker. Published traffic is DNAT-ed in
`nat/PREROUTING` and then crosses `FORWARD` and the `DOCKER-USER` chain. `INPUT` and ufw rules never see it, so a limit
placed there does nothing. The per-source connection limit and new-connection rate limit live in a private chain
`MCCTL-INGRESS`, built by the egress-guard container (see [The router and the egress guard](#the-router-and-the-egress-guard))
next to `MCCTL-EGRESS`. The jump to `MCCTL-INGRESS` sits at position 2 in `DOCKER-USER` (after `MCCTL-EGRESS` at position 1).
`firewall apply` handles ufw only and reports whether the ingress chain is active.

**The limits.** `MCCTL_CONN_LIMIT` (default 10) is the per-source connection limit: more than this many simultaneous
connections to the router port from one source IP are dropped. `MCCTL_RATE` (default `10/second`) is the new-connection
rate limit per source. Both match only connections whose destination is the router (`-d $ROUTER_IP -p tcp --dport 25565
-m conntrack --ctstate NEW`); router-to-game traffic never matches. Many players behind one shared address (a school, a
household) count as one source, so raise `MCCTL_CONN_LIMIT` when they are cut off.

| Key | Default | Meaning |
|---|---|---|
| `MCCTL_CONN_LIMIT` | `10` | Per-source connection limit on 25565. Integer 1 to 65535. |
| `MCCTL_RATE` | `10/second` | New-connection rate limit per source on 25565. `N/second`, `N/minute` or `N/hour` (N from 1 to 999999). |
| `MCCTL_SSH_PORTS` | empty | SSH ports to keep open, comma-separated. When empty, detected from `sshd -T`, `ss` and `$SSH_CONNECTION`. |
| `MCCTL_FIREWALL_ROLLBACK_SECONDS` | `300` | Dead-man timer seconds. 0 disables. Integer 0 to 3600. |

IPv4 only. If the guard is unhealthy because the kernel lacks `xt_connlimit` or `xt_hashlimit`, check with
`modprobe -n -v xt_hashlimit` and install the matching kernel module package.

## mcctl top

```
mcctl top [NAME]
```

Live, flicker-free table of every server (or one): CPU, memory, network and disk, with colour bars.

**Columns.** NAME (up to 24 characters), CPU (percentage and bar), MEM (percentage and bar), and, when the
terminal is at least 100 columns wide, NET and BLOCK (network and disk I/O). Below 100 columns the last two
are dropped, not wrapped.

**Colour thresholds.** Green below 60%, yellow from 60% to 84%, red from 85%. Set `NO_COLOR` to any non-empty
value to disable colour.

**`MCCTL_REFRESH`.** Seconds between refreshes (default 2). A number from 0.2 to 3600; anything else exits 2.

**Piped or redirected.** When standard output is not a terminal, `mcctl top` prints one frame without colour or
cursor codes and exits 0.

**ASCII fallback.** When the locale is not UTF-8 (e.g. `LANG=C`), the bars and box use ASCII characters (`#`,
`-`, `+`, `|`) instead of Unicode.

**How it ends.** On a terminal, Ctrl-C restores the cursor and the screen and exits 0.

## mcctl logs

```
mcctl logs NAME [-f] [--tail N] [--level INFO|WARN|ERROR] [--grep TEXT]
```

Streams a server's console log with colour, a level filter, and a text filter. A stopped server's log is shown
too.

| Option | Default | Meaning |
|---|---|---|
| `-f` | off | Follow: keep streaming new lines. Ctrl-C exits 0. |
| `--tail N` | 100 | Show the last N lines (0 to 100000). |
| `--level INFO\|WARN\|ERROR` | off | Show entries at or above the given level. INFO keeps everything; WARN keeps WARN, ERROR and FATAL; ERROR keeps ERROR and FATAL. Stack-trace lines and unrecognised lines follow the decision made for the entry before them; before any entry they are kept. |
| `--grep TEXT` | off | Case-insensitive substring match (never a regex), applied to each physical line. At most 200 characters. |

**Colour.** The timestamp is dim; the level word is coloured (INFO green, DEBUG and TRACE dim, WARN yellow,
ERROR and FATAL red and bold). WARN, ERROR and FATAL also colour the message. Stack-trace lines take the colour
of the preceding WARN or ERROR. Colour is applied only when standard output is a terminal and `NO_COLOR` is empty.

**Control characters.** Control characters (everything below space except tab, and DEL) are removed from every
line before it is printed, so a raw ESC byte in the log cannot clear the screen or retitle the window.

## mcctl files

```
mcctl files NAME ls [PATH]
mcctl files NAME cat PATH
mcctl files NAME get PATH [DEST]
mcctl files NAME put SRC PATH [--force]
mcctl files NAME rm PATH [--recursive]
mcctl files NAME mkdir PATH
mcctl files NAME mv SRC DEST
mcctl files NAME edit PATH
```

Reads and changes the files in the `data/` folder of server NAME (its world, mods and configuration). PATH is relative to
that folder: `world/level.dat`, or `./mods/a.jar`. An absolute path, a `..` part or a control character is refused (exit 2).
A name that starts with `-` is used as `./-name`.

| Subcommand | What it does | Refused (exit 4) when |
|---|---|---|
| `ls [PATH]` | Lists PATH (default: the folder itself) with `ls -la`. Works whether the server runs or not. | |
| `cat PATH` | Prints the file. | |
| `get PATH [DEST]` | Copies the file to DEST on this machine (default: `./` and its base name). A failed copy leaves no file behind. | DEST exists. |
| `put SRC PATH [--force]` | Copies the local file SRC into the folder, through a temporary file beside PATH. | PATH exists and `--force` is not given. |
| `rm PATH [--recursive]` | Removes a file, or a folder with `--recursive`. A folder needs a confirmation: `--yes` (or `MCCTL_YES=1`) answers it; without a terminal the answer is no. | PATH is `.` (the folder itself; exit 2 for an empty PATH); PATH is a folder and `--recursive` is missing; no confirmation. |
| `mkdir PATH` | Creates one folder. | |
| `mv SRC DEST` | Moves or renames a file or folder. | DEST exists. |
| `edit PATH` | Copies the file to a private folder, opens `$EDITOR` (default `vi`) on the copy, and writes it back only when its content changed. | The file is over 1 MB, before or after the edit. |

Exit codes: 0 ok; 1 failure (no server of that name, or the helper failed); 2 usage or an unsafe path; 3 an invalid
`MCCTL_UID` or `MCCTL_DATA_IMAGE`; 4 refused.

**Why a helper container.** The files in `data/` belong to the game's user (UID 1000 in itzg's image), so the host user
may not be able to read or write them, and `sudo` is not wanted. Each command starts one throw-away container
(`docker run --rm`) that sees only `data/`, mounted at `/data`. It runs as `MCCTL_UID`, with no network, all capabilities
dropped, a read-only root file system (only `/data` and a `/tmp` in memory are writable), `no-new-privileges`, at most 64
processes and 128 MB of memory. A path is checked twice: as text here, and inside the container with `readlink -f`, which
refuses a symbolic link that leads out of `data/`. The container is the boundary: it cannot see anything outside `data/`.
The link check is a second barrier, in case the mount ever grows.

**The other helpers.** Four steps need what neither the game's user nor the host user has. Each runs as root in a container with
only the capability it needs, one path mounted at `/m`, no network and a read-only root file system: giving a file or folder to the
game's user (`CHOWN`, for `data/` and the RCON secret); reading a server's folder to archive it (`DAC_READ_SEARCH`, read-only);
removing `data/`, `backups/` and `safety/` after the archive has been read back (`DAC_OVERRIDE`); and reading the RCON secret for
`export --with-secrets` (`DAC_READ_SEARCH`, read-only). They use the pinned `alpine:3.20`, never `MCCTL_DATA_IMAGE`.

**The image.** The helper is `alpine:3.20`. The first call pulls that image through the host's Docker, which needs the
network once; later calls use the local copy. `MCCTL_DATA_IMAGE` names another image (letters, digits and `. / : _ -`).

**`MCCTL_UID`.** The user the helper runs as: an integer from 1 to 65535, default 1000. Change it only if the game runs as
another user.

**Running servers.** The game may rewrite the same files while you change them. Stop the server first
(`mcctl stop NAME`) when you change a world or its settings.

## mcctl backup

```
mcctl backup NAME now|list|restore ID|prune
```

Backups are archives in `backups/`. The sidecar (`itzg/mc-backup`) writes them on its schedule (`BACKUP_INTERVAL`, from `create --backup-interval`), and `now` writes one at once.

- `now` runs `backup now` in the sidecar (`docker exec mc-NAME-backup backup now`). The server must be running, because the sidecar must be running.
- `list` prints the archives in `backups/`, newest first. With none it prints `no backups yet for NAME`.
- `restore ID` replaces `data/` with the archive `ID`, a file name in `backups/`. The server must be stopped. The archive is read with `tar -tzf`; its members must be regular files and folders with no absolute path and no `..`; its layout must be all under one top-level `data/`, or the members as they are in `data/`. After the confirm, the current `data/` is moved to `data.pre-restore-UTC`, and the archive is extracted as the game's UID (`MCCTL_UID`, default 1000). The command prints both paths. `--yes` or `MCCTL_YES=1` answers the confirm.
- `prune` keeps the newest `PRUNE_BACKUPS_COUNT` archives (default 7, from `backup.env`) and deletes the rest. Every archive needs a UTC timestamp in its name; if one has none, nothing is deleted.

What is refused: `now` on a stopped server (`is not running`, exit 1); `restore` on a running server (`is running: stop it first`, exit 4); an archive with unsafe members (`has unsafe members`, exit 4, nothing changed); an `ID` with a `/` or `..` (`invalid archive id`, exit 2); `prune` with an archive that has no timestamp (exit 4, nothing deleted).

## mcctl modpack

```
mcctl modpack NAME info
mcctl modpack NAME set --source curseforge|modrinth --pack ID [--version V]
mcctl modpack NAME update [--latest | --version V] [--clean [--timeout SECONDS]]
mcctl modpack NAME remove --type TYPE [--version V] [--loader-version V] [--purge-mods]
```

`info` prints the pack and its resolved name and version. A stopped container cannot report the resolved values, so they print as `unknown`; a server without a pack prints `no modpack`. `set`, `update` and `remove` change `modpack.env`; like other settings, the change is pending until [apply](#mcctl-set-get-unset-env-apply). `itzg/minecraft-server` installs the pack at start, using its own `AUTO_CURSEFORGE` or `MODRINTH` support. `--clean` reinstalls from the pack: the containers are recreated, the install is waited for, and they are recreated again without `REMOVE_OLD_MODS`; this needs a running server. `remove --purge-mods` also deletes the mods the pack installed; this needs a stopped server.

What is refused: a CurseForge pack without `secrets/curseforge_api_key` (exit 3, before anything else); `CF_API_KEY_FILE` in a server's `modpack.env` (exit 3, mcctl owns that key); `--clean` on a stopped server (exit 4); `--purge-mods` on a running server (exit 4); `update` on a server with no modpack (exit 1).

## mcctl world

```
mcctl world NAME list
mcctl world NAME info [WORLD]
mcctl world NAME use WORLD
mcctl world NAME new WORLD [--seed S] [--type T] [--generator-settings FILE] [--hardcore]
                           [--datapacks-enable a,b] [--datapacks-disable a,b] [--use]
mcctl world NAME rename OLD NEW
mcctl world NAME delete WORLD
mcctl world NAME reset [WORLD]
mcctl world NAME backup [WORLD] [--out FILE]
mcctl world NAME export WORLD OUT.tar.gz
mcctl world NAME restore WORLD ARCHIVE
mcctl world NAME import ARCHIVE [--as WORLD] [--use]
mcctl world NAME seed
mcctl world NAME datapack list [--world W]
mcctl world NAME datapack add FILE [--world W]
mcctl world NAME datapack remove PACK [--world W]
```

A world is a folder of `servers/NAME/data` that holds `level.dat`. The active world is `LEVEL` in `server.env` (default
`world`). The server reads `LEVEL` when it starts; `mcctl world NAME use WORLD` writes it and recreates the container
(`apply_pending`). `server.properties` is never changed.

| Subcommand | What it does | Needs a stopped server |
|---|---|---|
| `list` | One row per world, newest first (by the mtime of `level.dat`); `*` marks the active one. Folders without `level.dat` are not worlds. | no |
| `info [WORLD]` | Path, size, modified time, siblings and whether it is active (default: the active world). | no |
| `use WORLD` | Makes an existing world the active one (`LEVEL`), then applies it. | yes |
| `new WORLD ...` | Creates the settings of a new world (see below). Refuses a name that exists. | yes |
| `rename OLD NEW` | Renames the world and its siblings. `LEVEL` follows when OLD is active. Refuses an existing NEW. | yes |
| `delete WORLD` | Refuses the active world. Copies the world to a safety archive, then removes it. | yes |
| `reset [WORLD]` | Copies the world to a safety archive, then removes it. The server makes a new one at its next start (from `SEED` if it is set). | yes |
| `backup [WORLD] [--out FILE]` | A verified archive of the world (default: `backups/world-WORLD-<UTC>.tar.gz`, which `backup prune` may remove). | no |
| `export WORLD OUT.tar.gz` | As `backup`, to OUT. OUT must not exist. | no |
| `restore WORLD ARCHIVE` | Replaces the world with the one in ARCHIVE. The current one is copied first. | yes |
| `import ARCHIVE [--as WORLD] [--use]` | Adds a world from an archive. The name is the archive's folder, or `--as`. | yes |
| `seed` | Prints the seed of the running world (the game's `seed` command). | a running server |
| `datapack list / add / remove` | The datapacks in the world's `datapacks/` folder. `add` checks that the zip has `pack.mcmeta` at its root. | `add` and `remove` |

**Running servers.** `list`, `info`, `backup`, `export`, `seed` and `datapack list` also work while the server runs. Every
other subcommand needs a stopped server: otherwise it exits 4 and changes nothing (`mcctl stop NAME` first).

**Names.** A world name is 1 to 64 letters, digits, `_`, `.` or `-`, starting with a letter or digit. It cannot be one of the
server's own folders (`plugins`, `mods`, `config`, `logs`, `libraries`, `versions`, `cache`, `crash-reports`,
`defaultconfigs`, `resourcepacks`, `datapacks`, `backups`) or end in `_nether` or `_the_end`: a world with those names would
be written into the server folders.

**The Paper layout.** Paper keeps a world's nether and end beside it, as `WORLD_nether` and `WORLD_the_end`. Those three are a
group: backup, delete, reset, rename, restore and import move them together. `list` and `info` count a folder as a world only
when it holds `level.dat`, so the nether folder of a world is not listed as a world of its own.

**Safety archives.** Before anything removes or overwrites a world (`delete`, `reset`, `restore`), the group is archived to
`servers/NAME/safety/world-WORLD-<UTC>.tar.gz` (mode 600; the folder is 700 and is made on demand), read back with
`tar -tzf`, and only then removed. When the archive fails, nothing is removed. A second archive in the same second gets a
`-2` suffix. `mcctl backup NAME prune` reads only `backups/`, so it never removes a safety archive. `mcctl delete NAME`
(the whole server) puts `safety/` into its `trash/` archive with `data/` and `backups/`.

**Live backups.** `backup` and `export` on a running server turn autosave off (`save-off`), flush the world (`save-all
flush`), archive it, and turn autosave back on (`save-on`), in that order. `save-on` is sent even when the archive or a
signal fails. If `save-off` or the flush fails, nothing is archived and the command says `autosave state unknown: run
mcctl rcon NAME save-on`. If autosave is still off after an error, run `mcctl rcon NAME save-on`.

**Known window (C9).** The backup sidecar also turns autosave off and on around its own runs. A `world backup` that overlaps
one of those runs can turn autosave back on while its archive is still being written. The archive is still verified, but it
may not be a consistent snapshot. Run `world backup` at a quiet time, or stop the server for a consistent copy.

**`new` without `--use`.** `new` writes the settings you give (`SEED`, `LEVEL_TYPE`, `GENERATOR_SETTINGS`, `HARDCORE`,
`INITIAL_ENABLED_PACKS`, `INITIAL_DISABLED_PACKS`) and marks the change pending (`mcctl apply NAME`). It does not write
`LEVEL`, so the world is not made: the server makes a world only at a start with `LEVEL` set to its name. The message says
how to switch: run the same command with `--use`, which also sets `LEVEL` and applies it.

**`import` and `restore` layouts.** An archive for `import` holds one `level.dat`, at its root (then `--as` is required) or in
one folder. Its top-level folders must be that world and its `_nether` and `_the_end` siblings. `restore` takes an archive whose
top-level folders are WORLD, WORLD_nether and WORLD_the_end, and must contain WORLD. A link, a hard link, a device, an absolute
name or a `..` part is refused before anything else (exit 4). Extraction happens in a staging folder (`.mcctl-import-<pid>`)
and then the folders are moved into place.

**`datapack add`.** The file name is 1 to 64 letters, digits, `.`, `_` or `-` before `.zip`. The helper checks that
`pack.mcmeta` is at the root of the zip before the file is put in place. A datapack already there is replaced.

Exit codes: 0 ok; 1 failure (no such world, or the helper or Docker failed); 2 usage or an invalid name; 3 an invalid
`LEVEL` in `server.env`; 4 refused (the server runs, a confirmation was not given, an unsafe archive, or a name that exists).

## mcctl mods, plugins, modrinth

```
mcctl mods NAME list | installed | add URL|FILE... [--force] | remove ENTRY | clear [--remove-installed] | sync [--restart]
mcctl plugins NAME ...           the same verbs; add also takes --hybrid (a server that runs mods and plugins)
mcctl modrinth NAME list | add PROJECT[:VERSION]... | remove PROJECT | clear | sync
```

**The list is the truth.** Each server keeps three lists under `servers/NAME/lists/`: `mods.list`, `plugins.list` and
`modrinth_projects.list`, one entry per line. A list that exists is rendered as a literal block into the image's `MODS`,
`PLUGINS` or `MODRINTH_PROJECTS` variable, and the image installs what is listed at every start. What you remove from a list
is removed from the server at its next start. Back up first (`mcctl backup NAME now`) if you may want an entry back.

**What an entry may be.** A URL: `https://` only, no credentials (`user:pass@` is refused: it would sit in `compose.yaml` as a
value), no space, quote, backtick, `$` or backslash, at most 500 characters. Or a container path under `/mods/` or `/plugins/`
with no `..` part. A Modrinth entry is a project slug, `fabric-api`, optionally with a version, `lithium:mc1.21-0.13.0`.
An entry that is already in the list is not added twice. A list entry that starts with a space, or holds a control character
(a hand-edited file), makes the render fail (exit 4).

**Local jars are not in a list.** `add FILE` copies the jar into `servers/NAME/mods/` (or `plugins/`), the attach point that
compose mounts read-only at `/mods` (or `/plugins`) for every server. The file must start with the zip signature `PK` and be
at most 200 MB; it is copied with mode 644 so that the game's user can read it. It is used at the next start. `sync` makes the two
folders (mode 755) for a server created before they existed, so that Docker never makes them root-owned. `remove JARNAME`
deletes a jar from that folder; a copy the server already has in `data/` stays until `mcctl files NAME rm` removes it there.
`list` prints the list, then the local files, marked as such. Files put by hand with
`mcctl files put` into `data/mods` are outside the lists: no list command adds or removes them.

**`installed`** lists `data/mods` (or `data/plugins`) as the image left it, through one helper container. It works for a stopped
server. Before the first start the folder does not exist, and the command says so.

**Type guards.** `mods add` on a plugin type (PAPER, SPIGOT, BUKKIT, PURPUR, PUFFERFISH, LEAF, FOLIA) and `plugins add` on a mod
loader (FORGE, NEOFORGE, FABRIC, QUILT) are refused (exit 4) unless `--force` is given. `plugins add --hybrid --force` also sets
`USES_PLUGINS=true` in `server.env`. `--hybrid` is for plugins only.

**Pending.** Each change says whether the server must be synced. `sync` is `mcctl apply NAME`: when the configuration rendered
from the files differs from the one the container runs, it writes `compose.yaml`, checks for players (the same question as
`apply`) and recreates the containers. With nothing pending it says `nothing to apply` and runs no compose command.
`sync --restart` also restarts a server with nothing pending. A list file is read when `compose.yaml` is written, so a list
change only reaches the containers at the next sync.

A list key may not also be set in `server.env` or `modpack.env` while its list file exists: the render refuses it (exit 3).

**`clear` and `--remove-installed`.** `clear` deletes the list file. The image then stops managing that key, and what it
installed stays. `clear --remove-installed` keeps an empty file, which renders `KEY: ""`. The image's documentation says an
empty list removes all mods or plugins. That is not checked against the real image yet (Task 23 checks it on a live server);
until then treat it as unverified. It asks first: without a terminal it needs `--yes`, and a refusal changes nothing.

Exit codes: 0 ok; 1 failure (no such server, or the helper or Docker failed); 2 usage or a bad entry; 3 `server.env` does not
render; 4 refused (a type guard, a file that is not a jar, a declined confirmation, or the player check).

## mcctl info

```
mcctl info NAME
```

Says what a server is and holds, from its files and from Docker: type, version, modpack (source and id, or `none`), memory, cpus,
hostname and address, state (with the uptime when it runs), `config` (`current`; `pending`, where `mcctl apply NAME` applies it; or
`unknown` when the container has no hash label, which means it was created before tracking), the active world and its size, the size
of `data/`, the backup method from `backup.env`, and the time of the newest file in `backups/`. It works on a stopped server. A size the
helper cannot measure reads `unknown`; the command still exits 0. An unknown name exits 1.

## mcctl clone

```
mcctl clone NAME NEW [--with-data] [--hostname H] [--yes]
```

Makes NEW from NAME, stopped. Copied: `server.env` (with `HOSTNAME_SLUG` set to the new hostname), `modpack.env`, `backup.env`, `lists/`,
`mods/` and `plugins/` (their modes are kept, so a jar stays readable by the game's user). Not copied: `secrets/` (NEW gets its own RCON
password), `backups/`, `safety/`, and `compose.yaml` (it is rendered for NEW). With `--with-data` the world (`data/`) is copied too,
from one helper container to another, so nothing is extracted on the host; without it NEW starts with an empty world.

The hostname is `--hostname H`, or the slug of NEW. NEW and the hostname must be free: a name in use is exit 4, and the message names the
server that has the hostname. A running NAME with `--with-data` is quiesced for the copy (autosave off, then on again, also when the copy
fails); it needs a confirmation, `--yes` or a terminal answer, and is refused (exit 4, nothing changed) without one. The steps and their
rollback are those of `create`: a failed clone takes NEW back.

## mcctl rename

```
mcctl rename NAME NEW [--hostname H] [--yes]
```

Gives a server the name NEW. The containers are removed and made again, so NAME is down for the time of the rename; it is started again
at the end only when it was running. The hostname becomes the slug of NEW, or `--hostname H`; `--hostname` with the old hostname keeps
the DNS record and relabels its comment (`mcctl name=NAME` becomes `mcctl name=NEW`). The steps, each with the undo that a later failure
runs (newest first):

| Step | Does | Undone by |
|---|---|---|
| 1 | DNS: a new hostname gets a new record; the same hostname gets the comment relabelled (PATCH) | the record deleted, or the comment set back |
| 3 | stops NAME if it runs | starts NAME |
| 4 | removes its containers (`compose rm -s -f`) | makes them again (`compose create`) |
| 5 | moves `servers/NAME` to `servers/NEW` (with `data/`, `backups/`, lists, mods, plugins) | moves it back |
| 6 | moves `secrets/rcon-NAME` to `secrets/rcon-NEW` (the same password) | moves it back |
| 7 | SFTP: the key `sftp-keys/NAME` moves to NEW, NAME's user is removed, NEW's added | NEW's user removed, the key moved back, NAME's user added back |
| 8 | `HOSTNAME_SLUG` in `server.env` is the new host; `compose.yaml` is rendered for NEW | the old `server.env` and `compose.yaml` text is written back |
| 9 | `compose create` for NEW, NEW started if NAME ran | NEW's containers removed |
| end | with a new hostname, NAME's old DNS record is deleted | a failure only warns and names the record: `mcctl delete NAME` removes it |

A failure at a step takes back the steps that ran, in reverse. A failing undo is a warning that says what is left. After any failure,
exactly one of NAME and NEW is complete, and the same command run again finishes the rename. A refusal before step 1 (NEW exists, the
hostname is taken, the confirmation is declined) changes nothing and exits 4; a failure of step 1 leaves NAME as it was (exit 1).
Not checked on a real Docker host yet: that the bind mounts, labels and mc-router route of a renamed server work, that PATCH works
against real Cloudflare, and that SFTP follows the new name (Task 23).

## mcctl export

```
mcctl export NAME OUT.tar.gz [--with-secrets]
```

Writes the server as one gzip tar with mode 600. OUT must not exist (exit 4). The layout is fixed: the marker `mcctl-export` (text lines
`format=1`, `name=NAME`, `mcctl=VERSION`, `created=` the UTC time, `secrets=0` or `1`), then `server.env`, `modpack.env` and `backup.env`
when they exist, `lists/`, `mods/`, `plugins/`, and `data/` (the world, read through the helper). `--with-secrets` adds exactly
`secrets/rcon-NAME`. Left out: `backups/` (it is large: `mcctl backup` keeps those), `safety/`, and `compose.yaml` (rendered again from
`server.env` by `import`). A running server has autosave off while `data/` is read (save-off, save-all flush, save-on). A failure writes
nothing: no OUT and no temporary file.

With `--with-secrets` the archive holds the RCON password, a credential: keep it like the secret itself. The password is never printed.

## mcctl import

```
mcctl import ARCHIVE [NAME] [--hostname H] [--yes]
```

Makes a stopped server from an export. Before anything is made, the archive is checked, and any failure is exit 4 with nothing made:

- every member passes `archive_safe_members` (a symbolic or hard link, a device, an absolute name, a `..` component, a control
  character or a newline in a name: refused, and the member is named);
- every top-level name is one an export writes: `mcctl-export`, `server.env`, `modpack.env`, `backup.env`, `lists`, `mods`, `plugins`,
  `data`, `secrets`;
- the marker `mcctl-export` is there with `format=1`, and `server.env` is there.

NAME defaults to the marker's name and must be free. The hostname is the archive's `HOSTNAME_SLUG`, or `--hostname H`, and must be free
(exit 4, naming the owner). Then the steps of `create`: `server.env`, `modpack.env` and `backup.env` are written from the archive; `lists`,
`mods` and `plugins` are extracted with `tar --no-same-owner` (umask 022, so a jar is mode 644); `data/` is written by a helper
container, which takes only `data/` out of the stream. The RCON secret is the archive's, written as `secrets/rcon-NAME`, when the archive
has one; otherwise a fresh one. The renderer then checks `server.env`: a credential written as a plain value, or a bad value, exits 1 with
the reason, and everything is taken back.

## mcctl exec and shell

```
mcctl exec NAME COMMAND [ARGS...]
mcctl shell NAME
```

`exec` runs one command in the game container, as the game's user (`docker exec -u UID:UID mc-NAME COMMAND ...`): UID 1000, the user of
the itzg image under its root entry point; `MCCTL_UID` changes it. The exit status is the command's. The server must run (exit 1, with
`mcctl start NAME`). The command needs at least one word, and the first word may not start with `-` (exit 2).

`shell` runs `bash` there, interactively (`docker exec -it -u UID:UID mc-NAME bash`). It needs a terminal (exit 2 without one: use
`exec`) and a running server (exit 1).

Exit codes for these commands: 0 ok (or the command's own status for `exec`); 1 failure; 2 usage; 3 `MCCTL_UID` or the configuration is
invalid; 4 refused (a name in use, a declined confirmation, a refused archive).
