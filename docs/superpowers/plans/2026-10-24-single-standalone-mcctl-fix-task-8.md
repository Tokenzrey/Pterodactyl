# Fix spec for Task 8 (backup and restore): defects found on review

Status: written, not dispatched. Written on 2026-10-24 after review of `lib/backup.sh`, `lib/common.sh`, `tests/t_backup.sh` and the templates, and after the Task 9 fix is in (it must be done first: the full gate is red on Task 9 items). Task 8 was done in another session; its report was written by that session's controller (`task-8-report.md`), not by an implementer.
Model for the implementer: Opus (restore can destroy a world; it is data-loss code).
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Defects (each verified)

| # | Defect | Evidence | Severity |
|---|---|---|---|
| F1 | The archive checker accepts symlinks and hard links. | `_backup_safe_members` lists names with `tar -tzf` and rejects only names with `/`, `..`, or ` -> `. `tar -tzf` prints names only, so a symlink or hard link is not recognised. Tested 2026-10-24 with real `tar.gz` fixtures: `symlink.tar.gz` (member `world/escape` -> `/etc`) and `hardlink.tar.gz` (member `world/copy` -> `world/level.dat`) both return "safe". | critical: `backup restore` can write through a link to any path the host user may write |
| F2 | Restore extracts as the host user, without `--no-same-owner` and without the game's UID. | `lib/backup.sh`, restore step 5: `tar -xzf "$arch" -C "$data_dir"`. When mcctl runs as a user other than UID 1000, the restored files belong to that user, and the game (UID 1000) cannot write its world. The sidecar's files belong to UID 1000, so the archive carries the right owner only when root extracts it. | high: a restored world the server cannot save |
| F3 | The layout of the backup archive is assumed, not checked. | Restore extracts the archive straight into `data/`. If `itzg/mc-backup` wraps its members in one top-level directory (`data/…`), the restore produces `data/data/`. Upstream documentation for the archive layout was not reachable on 2026-10-24 (the pages checked returned 404); the local `single-standalone/docs/itzg/` has no backup page. | medium: unverified; needs the acceptance run to settle |
| F4 | The checker and the restore run on the host, before a snapshot of the current data exists. | Restore step 4 moves `data/` aside, then extracts; a failing extraction leaves the previous data in `data.pre-restore-<ts>`, which is correct, but the message does not say which one is the world. | low |

Checked and fine: `now` refuses a stopped sidecar; `restore` refuses a running server; `prune` keeps the configured count; `RCON_HOST` is `127.0.0.1` in the template, as Task 6 requires.

## 2. Design (decided here)

- **One archive checker, used everywhere.** `archive_safe_members ARCHIVE` in `lib/common.sh` (moved from `lib/backup.sh`). It lists with `tar --quoting-style=escape -tvzf` and checks the type column: the first character must be `-` (regular file) or `d` (directory). Anything else (`l` symlink, `h` hard link, `b`, `c`, `p`) is refused. Names: no leading `/`, no `..` path component (`..`, `../x`, `x/../y`, `x/..`; `a..b` is fine), no backslash. Returns 0; prints every offending member and returns 1; returns 2 when the archive cannot be read. `_backup_safe_members` is deleted and its callers call `archive_safe_members`.
- **Two accepted layouts, decided by the archive, not by the caller.** After the checker passes, restore looks at the top-level names (`tar -tzf | cut -d/ -f1 | sort -u`). If every member is under one top-level name `data`, it extracts with `--strip-components=1`; otherwise it extracts as it is. Any other top-level name refuses the archive (`EX_REFUSED`, names it). Ruling: accept both layouts until the acceptance run has shown which one `itzg/mc-backup` writes, then keep only that one. Cost: one more branch to delete later.
- **Extraction runs in a one-off container with the game's UID** (fixes F2). Until Task 15 provides `data_pipe`, restore uses a private helper in `lib/backup.sh`:
  `docker run --rm -i --network none --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges -v "<servers/NAME/data>:/data" -w /data alpine:3.20 tar -xzf - --no-same-owner -C /data [--strip-components=1]`, with the archive on stdin (`< "$arch"`). `MCCTL_UID` (default 1000) overrides the UID, as in Task 15. Ruling: duplicate of the Task 15 primitive, kept small so Task 15 can replace it in one place. Cost: one function to delete when Task 15 lands.
- **Restore messages name the world.** The final line says: "restored <archive> into <data dir>; the previous data is in <data.pre-restore-ts>; if the world is wrong, stop the server, move <data> aside and move the previous data back".

## 3. Changes

1. `lib/common.sh`: add `archive_safe_members` (section 2).
2. `lib/backup.sh`: delete `_backup_safe_members`; `cmd_backup restore` calls `archive_safe_members` (exit 4 on refusal, naming the members) and then the layout check; extraction through the helper container (section 2) instead of host `tar -xzf`.
3. `lib/backup.sh` restore step ordering stays: refuse while running, verify, check members, `confirm`, move `data/` aside, extract, report. The extraction failure path moves the old data back (currently it only reports the path). Ruling: restore the previous data automatically when extraction fails, because the operator would otherwise have to do it by hand under pressure. Cost: one more `mv`.
4. `tests/fixtures/archives/` (new, committed): `clean.tar.gz` (members `world/level.dat`), `clean-wrapped.tar.gz` (members `data/world/level.dat`), `symlink.tar.gz`, `hardlink.tar.gz`, `abs-path.tar.gz`, `dotdot.tar.gz`, `device.tar.gz` (a device member, if the sandbox tar can write one; otherwise SKIP with reason). Build them with `make_archives.py` (kept beside them; tests never run Python).
5. `tests/t_backup.sh`: replace the cases that depended on the old checker; add the cases of section 4.
6. `tests/t_archive.sh` (E8, created by Task 16) is not part of this fix; if it already exists, its cases for `backup restore` must pass.

## 4. Tests (`single-standalone/tests/t_backup.sh`)

1. `archive_safe_members`: `clean` and `clean-wrapped` return 0; `symlink` and `hardlink` return 1 and name the member; `abs-path` and `dotdot` return 1; a file that is not an archive returns 2; `a..b`-style names are accepted.
2. `backup restore` with `symlink.tar.gz` and `hardlink.tar.gz`: exit 4, no `docker run` call, no change to `data/`, and the sentinel file outside the sandbox is untouched (E8).
3. `backup restore` with `clean.tar.gz`: one `docker run … tar -xzf - --no-same-owner -C /data` call with the archive on stdin, `--user 1000:1000`, `--network none`, `--cap-drop ALL`; the previous `data/` is moved to `data.pre-restore-<ts>` first.
4. `backup restore` with `clean-wrapped.tar.gz`: the same call with `--strip-components=1`.
5. A top-level name other than `data` (for example `plugins/`): refused with exit 4 before any change.
6. A failing extraction (`docker.run.tar.rc` = 1 in the fake): the previous data is moved back, the message says so, exit 1; `data.pre-restore-<ts>` is gone.
7. `MCCTL_UID=2000` changes the container's user; `0` and `abc` are refused (EX_PREFLIGHT).
8. `restore` on a running server: refused, no `docker run`.
9. `now` on a stopped sidecar: refused (existing behaviour, kept).
10. E4: the RCON secret never appears in `calls`; E3: no `eval`, no `sudo`, `rm -rf` lines pass the invariant (the restore's removal goes through `mv`, not `rm -rf`).
11. E12: the restored files' owner, read with the fake's `stat`, is UID 1000 (the fake answers the extraction, so this is asserted from the `calls` line, not from the file system).

## 5. Not provable in the sandbox (acceptance, Task 23 step 2 and step 11)

The archive layout that `itzg/mc-backup` really writes (section 2 accepts both until then); that the game starts on a restored world; that `save-off`/`save-on` bracket a real backup; that the helper's `tar` (busybox in `alpine:3.20`) accepts `--strip-components` and `--no-same-owner`.

## 6. Ponytail notes

- Two layouts accepted: ceiling is one extra branch; upgrade path is to keep the layout the acceptance run confirms.
- The private extraction helper duplicates Task 15's primitive on purpose and is deleted when Task 15 lands.

## 7. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_backup.sh`, then `t_flows.sh`, `t_failure.sh`, `t_invariants.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-8-fix-report.md`.
