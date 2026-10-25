# Task 16 spec: world management (`mcctl world`)

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32). Depends on Tasks 14 and 15 (specs `…-task-14.md`, `…-task-15.md`): `server_env_set`, `apply_pending`, `_recreate_guard`, `data_run`, `data_pipe`, `safe_path`. Model for the implementer: Opus (a mistake deletes player data).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 16").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

List, inspect, switch, create, rename, delete, back up, restore, export, import, reset and seed-query the worlds of a server, and manage a world's datapacks. A world is a directory of `data/` that holds `level.dat`; the active one is the value of `LEVEL` (default `world`). Every step that removes or overwrites a world first writes a verified safety archive and aborts, changing nothing, when that fails.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | ledger ruling: "one function `backup_restore`; `world restore` calls it" | There is no such function. `backup restore` (`lib/backup.sh`, inside `cmd_backup`) restores the whole `data/` from a full archive made by the sidecar, with host-side `mv` and `tar -xzf`. `world restore` restores one world from a world archive. | Two independent implementations. They share only the archive checker (C2). |
| C2 | Review Focus 7: refuse symlinks and hard links, using the existing checker | `_backup_safe_members` (`lib/backup.sh`) lists with `tar -tzf`, which prints names only, and looks for ` -> `. **Tested on 2026-10-24: it accepts an archive with a symlink member and one with a hard-link member.** The same function guards `backup restore` today. | Replace it with `archive_safe_members ARCHIVE` in `lib/common.sh` (section 4.1) and make `_backup_safe_members` call it. `backup restore` is covered by the new tests. |
| C3 | "extracts with `--no-same-owner` through `data_run`" | Extraction reads the archive from stdin, and `data_run` has no stdin (Task 15, C4). | Use `data_pipe NAME tar -xzf - --no-same-owner -C /data`. |
| C4 | snapshot "tar of the group" | The helper container reads `data/` as UID 1000; the host user may not. | `world_snapshot` runs `data_run NAME tar -czf - -- <members>` and writes its stdout to the host file through `write_atomic`, mode 600, in `backups/`. |
| C5 | `valid_world_name` is `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$` | A world named `plugins`, `mods`, `config`, `logs`, `libraries`, `versions`, `cache`, `crash-reports`, `defaultconfigs`, `resourcepacks`, `datapacks` or `backups` would make the server write `level.dat` into a real server directory. A name ending in `_nether` or `_the_end` collides with the sibling layout. | Refuse those names and those suffixes. |
| C6 | `new … --generator-settings FILE` | `GENERATOR_SETTINGS` holds JSON text, longer than Task 14's text limit. | Task 14 adds the type `json` (compact, up to 8192 characters). `server_env_set` stores the compacted JSON. |
| C7 | "every destructive subcommand takes `--yes`" | `--yes` is global (Task 10, C1). | Use `confirm`; no per-command parser. |
| C8 | "require the server to be stopped" | Needs a state probe. | Use `_server_state NAME` from `lib/backup.sh` (prints the container state); `running`, `restarting` and `paused` are live. |
| C9 | `world backup` on a running server | The backup sidecar also runs `save-off` and `save-on` around its own runs; an overlap can turn autosave back on while this tar runs. | Accept the window. Mark it with `# ponytail:` (ceiling: a world backup that overlaps a sidecar backup may be taken with autosave on; upgrade: ask the sidecar for the lock). Document it. |
| C10 | "Modify: `mcctl`" | Dispatch discovers `cmd_*`. | `mcctl` is not changed. |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| `_backup_safe_members`, `_backup_verify_archive`, `_server_state`, `backup_dir NAME` | `lib/backup.sh` | `backup_dir` prints `servers/NAME/backups`; `_server_state` prints the container state; verify is `tar -tzf`. |
| `cmd_backup restore` | `lib/backup.sh` | refuses while running, verifies, checks members, `confirm`, moves `data/` to `data.pre-restore-<ts>`, `tar -xzf` as the host user. |
| `rcon_exec`, `_send` | `lib/rcon.sh` | `rcon_exec NAME CMD...`; the caller makes sure the server runs. |
| itzg names | `single-standalone/docs/itzg/` | `LEVEL` (default `world`), `SEED`, `LEVEL_TYPE`, `GENERATOR_SETTINGS`, `HARDCORE`, `INITIAL_ENABLED_PACKS`, `INITIAL_DISABLED_PACKS` exist. |
| Paper layout | convention | siblings `WORLD_nether` and `WORLD_the_end` next to `WORLD`. |
| Host tools | here | GNU `tar`, `jq`; no `unzip`, no `python3` (mcctl is pure Bash). |
| Planned | Tasks 14, 15 | `server_env_set/get/unset`, `apply_pending`, `_recreate_guard`, `data_run`, `data_pipe`, `safe_path`. |
| Fixtures | `tests/` | none for archives yet. |

## 4. Behaviour

### 4.1 Archive checker (`lib/common.sh`)

`archive_safe_members ARCHIVE`: lists with `tar --quoting-style=escape -tvzf`; for each line the first character must be `-` or `d` (a symlink `l`, a hard link `h`, a device `b` or `c`, or a fifo `p` is refused); the name must not start with `/`, must have no `..` path component (`..`, `../x`, `x/../y`, `x/..`; a name like `a..b` is fine), and must contain no backslash (GNU tar escaped something, for example a newline). Returns 0, or prints every offending member and returns 1. An unreadable archive returns 2. `_backup_safe_members` becomes a one-line call to it.

### 4.2 Pure helpers (`lib/worlds.sh`)

`valid_world_name W` (C5). `active_world NAME` = `server_env_get NAME LEVEL`, else `world`. `world_dirs NAME` = one directory per line, only those holding `level.dat`, from one `data_run NAME sh -c 'for d in /data/*/; do [ -f "$d/level.dat" ] && echo "${d#/data/}"; done'`. `world_group NAME WORLD` = WORLD plus `WORLD_nether` and `WORLD_the_end` when they exist. `snapshot_members NAME OUTFILE MEMBER...` (C4; MEMBER `.` means all of `data/`; Task 18 uses it for a whole-server snapshot) and `world_snapshot NAME WORLD OUTFILE` (= `snapshot_members NAME OUTFILE` plus the members of `world_group NAME WORLD`): on a live server `rcon_exec NAME save-off`, then `rcon_exec NAME save-all flush`, then the tar, then `save-on`, with `save-on` in a trap on EXIT, INT and TERM so it runs when the tar fails too (Review Focus 6); if `save-off` or `save-all flush` fails the tar is not started and the call returns 1 with "autosave state unknown: run mcctl rcon NAME save-on"; on a stopped server there is no RCON. The archive is verified with `tar -tzf` before the function returns 0; on any failure no file is left at OUTFILE.

### 4.3 `mcctl world NAME SUB …`

- Works on a running server: `list`, `info`, `backup`, `export`, `seed`, `datapack list`. Everything else requires a stopped server: otherwise exit 4 before any change, naming `mcctl stop NAME`.
- `list`: marks the active world with `*`, shows size and modified time, newest first, ignores directories without `level.dat`. It never reads a registry file.
- `info [WORLD]` (default active): path, size, modified time, siblings found, and whether it is active.
- `use WORLD`: the world must exist (creating one is `new`'s job); `server_env_set NAME LEVEL WORLD`, then `apply_pending`.
- `new WORLD [--seed S] [--type T] [--generator-settings FILE] [--hardcore] [--datapacks-enable a,b] [--datapacks-disable a,b] [--use]`: refuses an existing name; sets `SEED`, `LEVEL_TYPE`, `GENERATOR_SETTINGS`, `HARDCORE`, `INITIAL_ENABLED_PACKS`, `INITIAL_DISABLED_PACKS` in `server.env` when given (a negative or text seed is fine; the settings file must pass `jq -e .`); `LEVEL` is set only with `--use` (without it the world is created on the first start with that `LEVEL`, so `new` without `--use` records nothing and prints how to switch; document this).
- `rename OLD NEW`: renames the group; updates `LEVEL` if OLD is active; NEW passes `valid_world_name` and must not exist.
- `delete WORLD`: refuses the active world; snapshot to `backups/world-WORLD-<UTC>.tar.gz`, verified, then removal of the group; `confirm`.
- `backup [WORLD] [--out FILE]` and `export WORLD OUT.tar.gz`: one function; default output `backups/world-WORLD-<UTC>.tar.gz`; OUT must not exist.
- `restore WORLD ARCHIVE`: `archive_safe_members`, then every top-level member must be WORLD, WORLD_nether or WORLD_the_end; snapshot of the current group (if it exists), `confirm`, remove the group, `data_pipe … tar -xzf - --no-same-owner`.
- `import ARCHIVE [--as WORLD] [--use]`: `archive_safe_members`; `level.dat` at depth 0 or 1; the world name is the archive's top directory, or `--as`; an existing name needs a free `--as`; extraction through `data_pipe` into a staging directory `/data/.mcctl-import-<pid>` then `mv` to the final name (a failed extraction leaves nothing in the world list).
- `reset [WORLD]` (default active): snapshot, `confirm`, remove the group; the server generates a new world at next start (from `SEED` if set).
- `seed`: `rcon_exec NAME seed`, prints the reply's number; stopped server: exit 1 saying it needs a running server.
- `datapack list [--world W]` reads `<world>/datapacks/`. `datapack add FILE [--world W]`: the base name matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\.zip$`; check `pack.mcmeta` at the zip root in the helper (`data_pipe NAME sh -c 'cat >/tmp/p.zip && unzip -p /tmp/p.zip pack.mcmeta >/dev/null' sh`); then copy it in. `datapack remove PACK [--world W]`: PACK passes `safe_path` and `.zip` rules.

## 5. Tests (`single-standalone/tests/t_worlds.sh`, `single-standalone/tests/t_archive.sh` (E8))

Archive fixtures are committed files in `single-standalone/tests/fixtures/archives/`: `clean`, `symlink` (absolute `/etc`), `symlink-rel` (`../..`), `hardlink`, `abs-path`, `dotdot`, `device`, `newline-name`, `a..b` (legal), generated once by `make_archives.py` kept beside them for maintainers (tests never run it, because mcctl and its tests need no Python and Git Bash cannot always make links).

1. E8, `archive_safe_members`: `clean` and `a..b` return 0; each of the others returns 1 and names the member; an unreadable file returns 2.
2. E8, no write outside the target: for `world import`, `world restore`, `import` (Task 21) and `backup restore`, a hostile archive exits 4, no `docker run … tar -x` call exists in `calls`, and the sentinel file next to the sandbox is untouched. `backup restore` with `symlink` and `hardlink` is refused (C2).
3. `valid_world_name`: accepts `world`, `bonus-2`, `a.b`; refuses `plugins`, `mods`, `backups`, `x_nether`, `x_the_end`, `-x`, `.hidden`, 65 characters, empty.
4. `world list`: the active world is marked, newest first, directories without `level.dat` ignored, no registry file is read (delete `servers/NAME` metadata and it still lists from the fake).
5. `world delete`: refuses the active world; for `delete`, `restore` and `reset` the safety archive is written and verified with `tar -tzf` first; with the fake `docker.run.tar.rc` = 1 there is **no** removal call (assert no `rm` in `calls`) and the archive does not exist.
6. Review Focus 6: `world backup` on a live server: calls are `save-off`, `save-all flush`, `tar`, `save-on` in that order; with a failing tar, `save-on` is still called; with a failing `save-off`, no tar call and the message about autosave; a signal during the tar (kill the process in the test) still sends `save-on`.
7. `world new … --use` writes `LEVEL`, `SEED` (negative and text), `LEVEL_TYPE`, `GENERATOR_SETTINGS` (compact JSON), `HARDCORE=TRUE`, the two pack lists; refuses an existing name; refuses `--generator-settings` that is not JSON; without `--use`, `LEVEL` is unchanged.
8. `world import`: refuses missing `level.dat`; refuses an existing name without `--as`; `--as` names a free one; uses staging then `mv`; a failing extraction (`docker.run.tar.rc` = 1) leaves nothing.
9. `world rename` moves the siblings too and updates `LEVEL` for the active world; `world use` of a missing world is refused; `use` ends with `apply_pending` (stopped path: `create --force-recreate`).
10. `world restore`: top-level members other than the group are refused.
11. `datapack`: a zip without `pack.mcmeta` is refused; a bad base name is refused; `list` reads `datapacks/`.
12. Every mutating subcommand on a live server exits 4 with no change and no `docker run`.
13. E7: `FAIL_AT` on each mutating `docker run` of `delete`, `restore`, `reset`, `rename`, `import`: exit non-zero; a failed `delete` never removes the world; a re-run completes or says what is left.
14. E4 canary; E11 atomic writes; E12 modes: `backups/` is 700 and the archives 600. E3: `cmd_world` and the helpers named in tests, no `eval`, no `sudo`, every removal runs in the container.
15. Flow (E13): `new --use`, start (fake), `backup`, stop, `restore`, `delete` of a non-active world, in `tests/t_flows.sh` with the ordered log.

## 6. Files

- Create: `single-standalone/lib/worlds.sh`, `single-standalone/tests/t_worlds.sh`, `single-standalone/tests/t_archive.sh`, `single-standalone/tests/fixtures/archives/*` (with `make_archives.py`).
- Modify: `single-standalone/lib/common.sh` (`archive_safe_members`), `single-standalone/lib/backup.sh` (`_backup_safe_members` calls it), `single-standalone/tests/t_backup.sh` (hostile-archive cases), `single-standalone/tests/t_flows.sh`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

`## mcctl world` with every subcommand; the stopped-server rule and which commands work live; the safety archive and where it lands; the Paper sibling layout; why `new` without `--use` records nothing; the sidecar-overlap window (C9); what to do if autosave is off (`mcctl rcon NAME save-on`).

## 8. Carry-overs

Task 21 (`import`, `clone --with-data`) calls `archive_safe_members` and `world_snapshot`-style streaming. Task 23 step 11 adds: restore a world from an archive made on another machine; and step 16: busybox `tar` takes `--no-same-owner` and `-C /data`.

## 9. Not provable in the sandbox

That real busybox `tar` and `unzip` in `alpine:3.20` behave as the fakes assume; that itzg really creates a new world from `LEVEL`, `SEED` and the pack lists; that `save-all flush` returns only when the save is done on the installed version.

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_worlds.sh`, `t_archive.sh`, `t_backup.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-16-report.md`.
