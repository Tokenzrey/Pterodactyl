# Task 21 spec: server information, clone, rename, export, import, exec, shell

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32). Depends on Tasks 7, 14, 15, 16, 20 (specs `…-task-14.md`, `…-task-15.md`, `…-task-16.md`, `…-task-20.md`). Model for the implementer: Opus (rename and import move or create whole servers; E7 matters).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 21").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

`info` summarises a server. `clone` makes a second server from the first. `rename` changes a server's name (and, if wanted, its hostname) without losing data. `export` and `import` move a server between machines. `exec` and `shell` run commands inside the game container. Every multi-step command is built from steps that each have an undo, so a failure leaves a working server and no orphan record.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | `cf_delete_record` as a consumer | It exists: `cf_delete_record HOST NAME` and `cf_delete_server NAME` (`lib/cloudflare.sh`). `cf_create_record HOST NAME` refuses a name that already has a record. | Use them as they are. |
| C2 | "`rename` keeps the old hostname only when `--hostname` says so" | Keeping the host means the record already exists, with the comment `mcctl name=OLD`; `cf_create_record` refuses it. Nothing relabels it. | Add `cf_relabel_record HOST OLD NEW` (`PATCH` of the comment, only when the comment is exactly `mcctl name=OLD`). The fake `curl` models only GET, POST and DELETE: extend it with PATCH (same strictness, same `FAIL_AT` counting). |
| C3 | clone/import "use Task 7's order" | The ordered tail of `cmd_create` is inline: DNS, directories, secret, files, `write_compose`, `sftp_add_user`, `dc create`, `router_reload`, undo through `_create_undo`. Copying it twice invites drift. | Extract `_provision NAME HOST WRITE_FN` from `cmd_create` (name and hostname checks, `cf_create_record`, `mkdir_private`, `_write_rcon_secret`, then `WRITE_FN` writes the config files, `write_compose`, `sftp_add_user`, `dc create`, `router_reload`; on a failure `_create_undo`). `cmd_create`, `cmd_clone` and `cmd_import` call it. `t_servers.sh` (256 assertions), `t_failure.sh` and `t_flows.sh` guard the refactor and must pass unchanged. |
| C4 | "`import` extracts … with plain `tar --no-same-owner` for the small config files" | Extracting an archive on the host trusts its member names. | Check with `archive_safe_members` (Task 16, C2) first, and extract only the top-level names `mcctl-export`, `server.env`, `modpack.env`, `backup.env`, `lists`, `mods`, `plugins`, `data`, `secrets`; any other top-level member refuses the archive. |
| C5 | export layout | Not specified. | The archive has a marker file `mcctl-export` (text: `format=1`, `name=`, `mcctl=VERSION`, `created=UTC`, `secrets=0\|1`) at the top, then `server.env`, `modpack.env`, `backup.env` when present, `lists/`, `mods/`, `plugins/`, `data/`, and `secrets/rcon-NAME` only with `--with-secrets`. `backups/` and `compose.yaml` are not exported. |
| C6 | `rename`: "moves the folder including `backups/`, regenerates, recreates" | Moving the folder changes the bind-mount source; names that carry the server name are the compose project (`mcctl-OLD`), the containers (`mc-OLD`, `mc-OLD-backup`), the labels, the secret `secrets/rcon-OLD`, the SFTP user and its key file `sftp-keys/OLD`, and the DNS comment. | The step list of section 4.3, with an undo for each. |
| C7 | `exec` "as the container user" | The itzg process runs as UID 1000 under a root entry point. | `docker exec -u ${MCCTL_UID:-1000}:${MCCTL_UID:-1000}`; `shell` adds `-it` and `bash`. |
| C8 | `--yes` | global (Task 10, C1). | Use `confirm`. |
| C9 | "Modify `mcctl`" | Dispatch discovers `cmd_*`. | `mcctl` is not changed. |
| C10 | `info` lists `config pending` | `status` already shows it after Task 14. | `info` calls the same comparison (`config_hash`). |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| Create order | `lib/servers.sh`, `cmd_create` | check `server_exists`, `hostname_taken`, leftover directory; `cf_create_record "$host" "$name"`; `mkdir_private` for `servers`, `secrets`, dir, `data`, `backups`; `_write_rcon_secret`; write `server.env` (and `modpack.env`, `backup.env`) with `write_atomic`; `write_compose`; `sftp_add_user "$name" 2>/dev/null \|\| true`; `dc create`; `router_reload`; each failure after the record calls `_create_fail NAME HOST MSG` (undo, exit 1). |
| Undo | `lib/servers.sh` | `_create_undo NAME HOST` removes the containers (`dc rm -s -f`), the record (`cf_delete_record HOST NAME`), then `_remove_files NAME`. |
| Delete order | `lib/servers.sh` | confirm, stop, archive to `trash/`, DNS, containers, router, files, `sftp_remove_user`. |
| SFTP | `lib/sftp.sh` | `sftp_add_user NAME` writes `NAME::1000:1000:/NAME` to `sftp-users.conf` and creates `sftp-keys/`; `sftp_remove_user NAME` removes the line and `sftp-keys/NAME`. |
| Cloudflare | `lib/cloudflare.sh` | `cf_create_record HOST NAME`, `cf_delete_record HOST NAME`, `cf_delete_server NAME`, `cf_records`, `fqdn_for HOST`. |
| Secrets | `lib/rcon.sh` | `_write_rcon_secret NAME` (fresh password), `ensure_rcon_secret NAME` (keep if present; unused so far). |
| Fake `curl` | `tests/fakebin/curl` | GET, POST, DELETE only; refuses an existing name (81057) and an unknown id (81044). |
| Planned | Tasks 14 to 20 | `server_env_set`, `config_hash`, `snapshot_members`, `archive_safe_members`, `data_run`, `data_pipe`, `_recreate_guard`. |

## 4. Behaviour

### 4.1 `info NAME`

Prints (unknown server: exit 1): type, version, modpack source and id (or `none`), memory, cpus, hostname and fqdn, state and uptime, `config: current|pending|unknown` (C10), active world and its size, data size (`data_run … du -sk`), the backup method from `backup.env` and the time of the newest file in `backups/` (host `stat`). It works on a stopped server; the size lines say `unknown` when `data_run` fails.

### 4.2 `clone NAME NEW [--with-data] [--hostname H]`

NEW free (name and hostname uniqueness through `_provision`); default hostname `slugify NEW`. `WRITE_FN` copies `server.env` (with `HOSTNAME_SLUG` set to the new host), `modpack.env`, `backup.env`, `lists/`, `mods/`, `plugins/`; never `secrets/`, never `backups/`. The new server gets its own RCON secret (`_write_rcon_secret`, so a different password). `--with-data` streams the source's `data/` into the new `data/`: `data_run SRC tar -cf - -C /data . \| data_pipe NEW tar -xf - --no-same-owner -C /data`; a running source is bracketed by `save-off` and `save-on` (trap, as in Task 16) and needs `confirm`, or `MCCTL_YES`. Without `--with-data` the clone starts with an empty world. The clone is created stopped.

### 4.3 `rename NAME NEW [--hostname H]`

Default new hostname `slugify NEW`; `--hostname H` may equal the old one. Steps, each with an undo that runs in reverse on a failure after the step:

1. validate; `confirm` (names the downtime); refuse an existing NEW (container, folder, hostname).
2. DNS: different host: `cf_create_record NEWHOST NEW`, undo `cf_delete_record NEWHOST NEW`; same host: `cf_relabel_record HOST NAME NEW`, undo the reverse relabel.
3. note whether OLD runs; `dc OLD stop`; undo `dc OLD start` when it ran.
4. `dc OLD rm -s -f`; undo `dc OLD create`.
5. `mv servers/OLD servers/NEW`; undo `mv` back.
6. `mv secrets/rcon-OLD secrets/rcon-NEW`; undo back.
7. SFTP: move `sftp-keys/OLD` to `sftp-keys/NEW` when present, `sftp_remove_user OLD`, `sftp_add_user NEW`; undo the reverse.
8. rewrite `HOSTNAME_SLUG` (`server_env_set`) and `write_compose NEW`; undo restores the saved old `server.env` text and compose.
9. `dc NEW create`, `router_reload`; start NEW with `dc NEW start` when OLD had been running (step 3 stopped it on purpose, so no player guard is needed); then delete the old DNS record when the host changed (`cf_delete_record OLDHOST OLD`; failure only warns and names the record).

No `mc-OLD` container is left. If step 2 fails, nothing has moved.

### 4.4 `export NAME OUT.tar.gz [--with-secrets]` and `import ARCHIVE [NAME] [--hostname H]`

- `export`: OUT must not exist; layout C5; the data is streamed with `data_run` (`save-off` and `save-on` on a live server); written through `write_atomic` at mode 600; `--with-secrets` adds the RCON secret and prints a warning that the archive now holds a credential.
- `import`: `archive_safe_members`; top-level names per C4; marker `mcctl-export` with `format=1`; `server.env` present; NAME defaults to the marker's name; an existing name is refused; the host comes from `HOSTNAME_SLUG`, and a taken host needs `--hostname`. `WRITE_FN` extracts the small files with `tar --no-same-owner` into the server directory and `data/` through `data_pipe`. The RCON secret: the archive's, renamed to `rcon-NAME`, when present, otherwise `_write_rcon_secret`. The imported `server.env` is validated by the renderer (a credential-looking key, a bad value) and a failure undoes everything.

### 4.5 `exec NAME CMD...` and `shell NAME`

`exec`: server must run (exit 1 with `mcctl start`); at least one word; the first word may not start with `-`; one `docker exec -u UID:UID mc-NAME CMD...`; the exit status is the command's. `shell`: needs a terminal (exit 2 otherwise); `docker exec -it -u UID:UID mc-NAME bash`.

## 5. Tests (`single-standalone/tests/t_portable.sh`, E7 in `tests/t_failure.sh`, E8 in `tests/t_archive.sh`)

1. `info`: unknown exits 1; all fields present for a created server (stopped and running); `config: pending` when the fake label differs; `unknown` sizes when `docker.run.du.rc` = 1.
2. `_provision` refactor: `t_servers.sh`, `t_failure.sh`, `t_flows.sh` pass unchanged.
3. `clone`: existing NEW refused; default and explicit host; unique host enforced (names the owner); different RCON secret (compare the two secret files); `secrets/` and `backups/` not copied; `modpack.env`, `backup.env`, `lists/`, `mods/`, `plugins/` copied; `HOSTNAME_SLUG` updated; `--with-data` makes one `docker run … tar -cf -` and one `docker run -i … tar -xf -`; a running source calls `save-off`, then `save-on` even when the tar fails; without `MCCTL_YES` a running source is refused.
4. `rename`: ordered `calls` (DNS first, then stop, rm, the folder move is a file check, create, HUP); new host `cf_create_record` before the old record is deleted; same host uses PATCH relabel; `mc-OLD` absent; secret and SFTP key moved; a failing DNS call (`FAIL_AT=1`) leaves OLD untouched; a failure at every later mutating call leaves either a complete OLD or a complete NEW, never neither (E7 loop); the server restarts only if it ran.
5. `cf_relabel_record`: patches only a record whose comment is exactly `mcctl name=OLD`; refuses another comment; fake `curl` PATCH test in `t_cloudflare.sh`.
6. `export`: no `secrets/` and no `backups/` by default; the marker file's fields; `--with-secrets` adds exactly `secrets/rcon-NAME`, mode 600, with the warning; OUT exists: refused; `write_atomic` leaves nothing on a failure.
7. E8 `import`: hostile fixtures (symlink, hard link, absolute, `..`, device, newline name) refused with exit 4 and no `docker run … tar -x`; an unknown top-level member refused; no `server.env`: refused; no marker or `format=2`: refused; existing name: refused; taken host without `--hostname`: refused naming the owner; archive without a secret: a fresh one is written; with one: it is renamed to `rcon-NAME` and not shown in any output (E4).
8. Round trip: `export` then `delete` (to `trash/`) then `import` gives a server whose `server.env`, lists and `data/` are identical and whose DNS record and route exist again.
9. `exec`: stopped server exits 1; `exec s1 ls -la` is one `docker exec -u 1000:1000 mc-s1 ls -la`; no word, or a first word `-x`: exit 2; the exit status passes through (`docker.exec.rc` = 7). `shell`: stopped refused; no terminal exits 2; with a terminal stand-in, `docker exec -it -u 1000:1000 mc-s1 bash`.
10. E7 loops for `clone`, `rename`, `import`; E4 canary in every flow; E3 (`cmd_info cmd_clone cmd_rename cmd_export cmd_import cmd_exec cmd_shell`, `_provision` named in tests; no `eval`, no `sudo`).
11. Flow (E13): clone, rename, export, delete, import, in `tests/t_flows.sh` with the ordered log.

## 6. Files

- Create: `single-standalone/lib/portable.sh`, `single-standalone/tests/t_portable.sh`.
- Modify: `single-standalone/lib/servers.sh` (`_provision`, `cmd_create` calls it), `single-standalone/lib/cloudflare.sh` (`cf_relabel_record`), `single-standalone/tests/fakebin/curl` (PATCH), `single-standalone/tests/t_cloudflare.sh`, `single-standalone/tests/t_failure.sh`, `single-standalone/tests/t_archive.sh`, `single-standalone/tests/t_flows.sh`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

One section per command. For `rename`: the steps and what is undone on a failure; for `export`: the archive layout, what is left out and why, and that `--with-secrets` makes the file sensitive; for `import`: the checks; for `clone`: what is and is not copied.

## 8. Not provable in the sandbox (owed to acceptance, Task 23 step 17)

That a renamed server's bind mounts, labels and router route work on real Docker; that `PATCH` on a record's comment works against real Cloudflare; that the streamed `tar` pipe between two helper containers is byte-exact on a real world; that SFTP follows a rename (see the open point below).

## 9. Open point (Task 9)

`sftp_add_user` writes a user line `NAME::1000:1000:/NAME` but `templates/stack.compose.yml` mounts only `users.conf` and `sftp-keys`; no mount of `servers/NAME/data` into the SFTP container exists, so a chroot path `/NAME` has nothing behind it. Whatever Task 9 settles on, `rename` and `clone` must go through its API (`sftp_add_user`, `sftp_remove_user`) and move the key file. If Task 9 adds a generated mount file, this task regenerates it.

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_portable.sh`, `t_servers.sh`, `t_failure.sh`, `t_archive.sh`, `t_cloudflare.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-21-report.md`.
