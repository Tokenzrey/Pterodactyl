# Task 18 spec: version, loader type, upgrade, reinstall, and modpack management (Task 19 merged)

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32) and `D:\Documents\code\pterodactyl\docs\single-standalone\`. Depends on Tasks 14 and 16 (specs `…-task-14.md`, `…-task-16.md`): `server_env_set/get/unset`, `write_compose`, `_recreate_guard`, `_recreate_apply`, `snapshot_members`. Model for the implementer: Sonnet; a second look at the downgrade guard is cheap.
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 18"; "Task 19" is a stub).
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

Change a server's Minecraft version, loader type and loader version, upgrade it, force the installer to run again, and manage the modpack it runs (show, set, update, remove). Anything that can damage a world takes a verified full snapshot first and changes nothing when it fails.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | "`set` and `upgrade` run a full backup first" (with `cmd_backup`) | `cmd_backup now` runs `docker exec <sidecar> backup now` and dies unless the sidecar is **running** (`lib/backup.sh`, `now)` branch). An upgrade is usually done on a stopped server, where that can never succeed. | Use `snapshot_members NAME backups/pre-<verb>-<UTC>.tar.gz .` (Task 16): the whole `data/`, through the helper container, with `save-off`/`save-on` on a live server. Refuse and change nothing when it fails. |
| C2 | `reinstall` sets the flag and calls `apply`; `modpack update --clean` sets `REMOVE_OLD_MODS` and applies | The one-shot keys are removed from the drift hash (Task 14, C3), so `apply_pending` sees nothing to do and never recreates; the flag would not reach the container. | These flows bypass the hash gate: `server_env_set` the flag, `write_compose`, `_recreate_guard`, `_recreate_apply`, wait for healthy, `server_env_unset` the flag, `write_compose`, `_recreate_apply` **again**, so no container keeps the flag (controller R10: a kept `REMOVE_OLD_MODS` deletes `mods/` at every restart); a stopped server is refused. Afterwards `status` shows `config: current`. |
| C3 | "`1.20` vs `1.20.0` is `0`" using `sort -V` | `sort -V` orders `1.20` before `1.20.0`. | Strip trailing `.0` components from both sides before comparing. |
| C4 | `modpack info` shows the pack name and version "when the running container exposes `MODPACK_NAME` and `MODPACK_VERSION`" | The itzg page says those are **placeholders usable inside other variable values** (`MOTD: Running %MODPACK_NAME%`), not that they appear in the container's environment. | `info` always prints what mcctl knows from `modpack.env` (source, pack id, `pinned <version>` or `latest`). It then tries `docker exec mc-NAME printenv MODPACK_NAME MODPACK_VERSION` and prints the values when they come back, otherwise `resolved name/version: unknown`. |
| C5 | `modpack remove [--purge-mods]` | After removal `TYPE` still says `AUTO_CURSEFORGE` or `MODRINTH`, which cannot start without a pack. | `remove` requires `--type TYPE` (a non-modpack type from the valid list, for example `FORGE`) and accepts `--version V` and `--loader-version V`. Without `--type`: exit 2 saying why. |
| C6 | `upgrade` "runs `docker compose pull`" | `compose pull` updates the **itzg image**. The Minecraft version of `VERSION=LATEST` is resolved again at every container start. | `upgrade` = snapshot, `dc pull`, recreate. It does not check whether the image changed; its final message says "image pulled; the version is resolved at start". `--to V` pins `VERSION` first. A modpack server is refused: "the modpack decides the version: mcctl modpack NAME update". |
| C7 | `modpack set` "leaves the CurseForge key as a file reference only" | The key check lives inline in `cmd_create` (`lib/servers.sh`, the `$src == curseforge` branch). | Extract it into `modpack_require_key` in `lib/modpack.sh`; `create` and `modpack set` both call it (exit 3 when the key file is empty or missing). |
| C8 | `type set` to any valid type | `AUTO_CURSEFORGE` and `MODRINTH` are modpack types and are set only by `mcctl modpack`. | `type set` refuses them. |
| C9 | `--yes` | global (Task 10, C1). | Use `confirm`. |
| C10 | "Modify `mcctl`" | Dispatch discovers `cmd_*`. | `mcctl` is not changed. |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| itzg names | `single-standalone/docs/itzg/` | present: `FORGE_VERSION NEOFORGE_VERSION FABRIC_LOADER_VERSION FORGE_FORCE_REINSTALL FABRIC_FORCE_REINSTALL FORCE_REDOWNLOAD REMOVE_OLD_MODS` (with `_INCLUDE`, `_EXCLUDE`, `_DEPTH`). Quilt has no documented loader-version variable. |
| Reinstall advice | `server-types.md` | set the flag temporarily and remove it after the server starts. Forge: `FORGE_FORCE_REINSTALL=true`; Fabric: `FABRIC_FORCE_REINSTALL=true`; Pufferfish and Purpur: `FORCE_REDOWNLOAD=true`. |
| Valid types | `server-types.md` | `VANILLA FORGE NEOFORGE FABRIC QUILT PAPER PUFFERFISH PURPUR LEAF FOLIA SPIGOT BUKKIT`; modpack platforms `AUTO_CURSEFORGE`, `MODRINTH`. |
| `modpack_env SOURCE ID [VERSION]` | `lib/modpack.sh` | prints `KEY=VALUE` lines; exit 2 for an unknown source or an empty id; a numeric CurseForge id is refused (Task 4 ruling). |
| Health | itzg image | the image has its own healthcheck; `cmd_status` already reads `.State.Health.Status`. |
| `cmd_backup now` | `lib/backup.sh` | needs a running sidecar (C1). |
| Planned | Tasks 14, 16 | see the header. |

## 4. Behaviour

### 4.1 Pure functions (`lib/versions.sh`)

- `version_cmp A B`: 0 equal, 1 A newer, 2 A older, 3 not comparable (a snapshot such as `24w14a`, a pre-release such as `1.21-pre1`, `LATEST`, `SNAPSHOT`). Both sides must match `^[0-9]+(\.[0-9]+)*$` after stripping trailing `.0`; otherwise 3. Compare with `sort -V`.
- `loader_var TYPE`: `FORGE` -> `FORGE_VERSION`, `NEOFORGE` -> `NEOFORGE_VERSION`, `FABRIC` -> `FABRIC_LOADER_VERSION`; empty for the others. `reinstall_flag TYPE`: `FORGE` -> `FORGE_FORCE_REINSTALL`, `FABRIC` -> `FABRIC_FORCE_REINSTALL`, `PURPUR` and `PUFFERFISH` -> `FORCE_REDOWNLOAD`; empty otherwise.

### 4.2 Commands (`lib/versions.sh`)

- `mcctl version NAME show`: prints `VERSION` and `TYPE` from `server.env`. `version NAME set V [--allow-downgrade]`: V matches the pattern of `check_server_values`; modpack servers refused (C6); `version_cmp` 2 (older than current) is refused unless `--allow-downgrade`, with the reason "a world saved by a newer version can be damaged by an older one"; 3 asks `confirm`; then snapshot (C1), `server_env_set VERSION`, `write_compose`, `_recreate_guard`, `_recreate_apply`.
- `upgrade NAME [--to V]`: C6. A snapshot first; a failed snapshot or a failed `pull` changes nothing.
- `type NAME set TYPE [--loader-version V]`: C8; unknown type refused; a switch **away from** a mod loader or plugin type is refused while `mods/` or `plugins/` hold jars, unless `MCCTL_YES` is set, and the message gives the count (counted with `data_run … find`); removes every loader variable that does not belong to the new type; `--loader-version` writes `loader_var TYPE` and is refused for a type without one; snapshot, write, recreate as above.
- `reinstall NAME [--timeout 600]`: C2. A type without a flag: exit 2 saying so. After the recreate, wait until the container's health is `healthy` or `--timeout` expires (non-zero on a timeout, and the flag is removed anyway, because it must not stay set).

### 4.3 Modpack commands (`lib/modpack.sh`)

- `modpack NAME info` (C4); a server with no modpack prints `no modpack`.
- `modpack NAME set --source curseforge|modrinth --pack ID [--version V]`: `modpack_require_key` for CurseForge; `modpack_env` for validation (exit 2); snapshot; `confirm`; write `modpack.env` and `TYPE` through `write_atomic`/`server_env_set`; `write_compose`; recreate.
- `modpack NAME update [--latest | --version V] [--clean]`: a pinned server refuses without `--latest` or `--version` and prints the pin; `--latest` removes the pin; `--clean` adds the one-shot `REMOVE_OLD_MODS=TRUE` (C2) after a snapshot and a message that quotes the itzg warning that the whole `mods` directory is deleted. A server with no modpack: exit 1.
- `modpack NAME remove --type TYPE [--version V] [--loader-version V] [--purge-mods]`: C5; snapshot; empties `modpack.env`; sets `TYPE`; keeps the installed mods unless `--purge-mods` (removed through `data_run`).

## 5. Tests (`single-standalone/tests/t_versions.sh`, `single-standalone/tests/t_modpack.sh` extended)

1. E9 version table, at least 25 pairs: `1.9 < 1.10`, `1.21 < 1.21.1`, `1.20 = 1.20.0`, `1.20.4 > 1.20`, `1.21.1 > 1.20.4`, `LATEST`, `SNAPSHOT`, `24w14a`, `1.21-pre1`, `1.21.1-rc1`, empty, `1..2`, `1.2.`, 40 digits.
2. `loader_var` and `reinstall_flag` tables for every valid type.
3. `version set s1 1.20.4` at `1.21.1`: refused (exit 4), nothing changed, no snapshot call; with `--allow-downgrade`: proceeds. `LATEST` against `1.21`: asks `confirm`. A modpack server: refused.
4. C1: for `set`, `upgrade`, `type set`, `modpack set|update --clean|remove`, a stopped server is snapshotted with `docker run … tar` (not `backup now`); a failing tar (`docker.run.tar.rc` = 1) aborts with `server.env`, `modpack.env`, `compose.yaml` byte-identical and no `docker compose` call.
5. `upgrade` on `VERSION=LATEST`: the ordered calls are snapshot, `compose … pull`, recreate (`up -d --force-recreate`, or `create --force-recreate` when stopped); `--to 1.21.4` writes `VERSION` first.
6. `type set s1 FABRIC` writes `TYPE=FABRIC` and removes a stale `FORGE_VERSION`; `QUILT`/`PAPER` with jars present are refused with the count and pass with `MCCTL_YES=1`; `--loader-version 0.16.9` writes `FABRIC_LOADER_VERSION`; refused for `PAPER`; `AUTO_CURSEFORGE` and `MODRINTH` refused (C8).
7. `reinstall` (C2): the `docker compose` calls include the recreate even though the hash is unchanged; the compose file rendered for that recreate holds the flag, the final `server.env` and `compose.yaml` do not; no second recreate follows; health `starting` then `healthy` (the fake `docker.inspect` changes between calls) ends exit 0; a timeout exits non-zero and still removes the flag; `status` then reports `config: current`. A type without a flag: exit 2.
8. `modpack info`: with `modpack.env` it prints source, id, `pinned 9184730` or `latest`; with `docker.exec` returning `Name\n1.2\n` it prints them, with a failing exec it prints `unknown`; no modpack prints `no modpack`.
9. `modpack set`: key check (missing key exits 3 before the snapshot), unknown source or empty id exit 2, snapshot, `confirm` declined leaves everything unchanged, the CurseForge key is never in `modpack.env`, `compose.yaml` or the call log (E4).
10. `modpack update`: pinned without options refused and prints the pin; `--version V` rewrites the pin; `--latest` drops it; `--clean` follows C2 and quotes the warning; no modpack exits 1.
11. `modpack remove` without `--type` exits 2; with `--type FORGE` the mods stay; with `--purge-mods` a `find … -delete`-style call in the helper removes them after the snapshot.
12. E7 on every mutating command here; E5: goldens unchanged except where a test sets `VERSION`/`TYPE` explicitly; E11, E3 (`cmd_version cmd_upgrade cmd_type cmd_reinstall cmd_modpack` named in tests; no `eval`, no `sudo`).
13. Flow (E13): `upgrade` and `modpack update --clean` as ordered logs in `tests/t_flows.sh`.

## 6. Files

- Create: `single-standalone/lib/versions.sh`, `single-standalone/tests/t_versions.sh`.
- Modify: `single-standalone/lib/modpack.sh` (`cmd_modpack`, `modpack_require_key`), `single-standalone/lib/servers.sh` (`create` calls `modpack_require_key`), `single-standalone/tests/t_modpack.sh`, `single-standalone/tests/t_flows.sh`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

`## mcctl version`, `upgrade`, `type`, `reinstall`, `modpack`; the downgrade rule and why; that the snapshot goes to `backups/pre-<verb>-<UTC>.tar.gz` and is not pruned (Task 8's prune applies to the sidecar's own archives only; say so); what `reinstall` does and when to use it; `--clean` and its warning; the unknown-resolved-version note.

## 8. Not provable in the sandbox

That the installers honour the flags exactly as `server-types.md` says; that `MODPACK_NAME`/`MODPACK_VERSION` can be read from the container; the length of a real snapshot of a large modpack server; that the image healthcheck reports `healthy` after a reinstall.

## 9. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_versions.sh`, `t_modpack.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-18-report.md`.
