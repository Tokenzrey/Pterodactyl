# Fix spec for Task 9 (SFTP): defects found on review

Status: written, not dispatched. Written on 2026-10-24 after review of the tree as it stood at 15:58 (the Task 9 work was done in another session; no Task 9 report exists in the ledger). Verified against the code and against the upstream `atmoz/sftp` README (fetched 2026-10-24).
Model for the implementer: Sonnet (mechanical: generated compose file, fixed paths, tests). Gate: see section 7.
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Defects (each verified)

| # | Defect | Evidence | Severity |
|---|---|---|---|
| F1 | The SFTP container mounts no server data. A user's chroot (`/home/NAME`) has nothing in it, so there is nothing to upload to or download from. | `templates/stack.compose.yml`, service `sftp`: volumes are only `users.conf` and `sftp-keys`. Comment says "Each server's data dir is mounted into the chroot as /<name>", but no such mount exists. | critical: SFTP does not do what it is for |
| F2 | Public keys are read from the wrong path, so key login can never work. | `atmoz/sftp` README: "Mount public keys in the user's `.ssh/keys/` directory", example `/home/foo/.ssh/keys/id_rsa.pub`; keys are appended to `.ssh/authorized_keys`. Our stack mounts `sftp-keys` at `/etc/sftp/keys`, which the README never mentions. | critical: login impossible |
| F3 | The directory field in `users.conf` has a leading slash. | `lib/sftp.sh` writes `NAME::1000:1000:/NAME`. README: "Directory names at the end will be created under user's home directory", examples use bare names (`upload` becomes `/home/foo/upload`). | high: directory may be wrong or rejected |
| F4 | SFTP's published port is in the router stack. | `templates/stack.compose.yml`: `"${MCCTL_SFTP_BIND:-127.0.0.1}:2222:22"`. This breaks the router stack's invariant (exactly one published port, 25565) and makes `tests/t_router.sh` fail 4 assertions. | high: test failure; also the invariant is a security boundary |
| F5 | `_remove_files` runs `rm -rf` two lines below its name check. | `lib/servers.sh`: `valid_server_name` on one line, `sftp_remove_user` next, then `rm -rf`. The code is safe (the check returns first), but the invariant `every recursive rm in lib/ is guarded` (same or previous line) fails. | medium: invariant failure (code is correct) |
| F6 | `sftp_add_user` and `sftp_remove_user` errors are discarded (`2>/dev/null || true` in `cmd_create` and `_remove_files`). | `lib/servers.sh`. A broken SFTP setup is invisible. | medium: silent failure |

Checked and fine: `cmd_sftp add-key` appends the key to `sftp-keys/NAME` (a file, mode 600), and `_valid_pubkey` checks the key type. Keep both.

## 2. Design (decided here; the implementer follows it)

- **The SFTP service moves to its own compose file.** `templates/sftp.compose.yml` is the template; `sftp_render` writes `$MCCTL_ROOT/sftp.compose.yml` (generated, never edited by hand). The router stack (`stack.compose.yml`) loses the `sftp` service entirely, so its published-port invariant is exact again. Ruling: separate file, because it keeps each stack's security invariant exact and lets SFTP be recreated without touching the router. Cost: one more compose project (`mcctl-sftp`) for `up`/`down` to manage.
- **Per-user mounts, generated.** For every server listed in `users.conf`, the generated file has:
  - `<servers/NAME/data absolute path>:/home/NAME/NAME` (read-write; the game runs as UID 1000 and the SFTP user is 1000:1000);
  - `<sftp-keys/NAME absolute path>:/home/NAME/.ssh/keys/NAME.pub:ro`.
  Paths go through `compose_escape`; a path with a newline, or any control character, is refused with `EX_PREFLIGHT` before any file is written.
- **users.conf line** becomes `NAME::1000:1000:NAME` (bare directory name, F3).
- **The users.conf mount** stays: `<MCCTL_ROOT>/sftp-users.conf:/etc/sftp/users.conf:ro`.
- **The published port** is in `sftp.compose.yml` only: `"<bind>:2222:22"`, where `<bind>` is `127.0.0.1` unless `MCCTL_SFTP_PUBLIC=1` (then `0.0.0.0`). It is decided at render time, so the file holds no `${...}`.
- **Lifecycle.** `sftp_add_user` and `sftp_remove_user` update `users.conf` and the keys directory, then call `sftp_render`. If the SFTP container is running, they also run `up -d --force-recreate sftp` in project `mcctl-sftp`. `mcctl up` starts the router stack and then `mcctl-sftp`; `mcctl down` stops both. Recreating SFTP disconnects SFTP users for a few seconds; the reference says so.
- **Errors are reported, not hidden (F6).** `cmd_create` and `_remove_files` keep going when SFTP fails (a server must not be blocked by SFTP), but the failure prints a `warn` line that names the user and the next step (`mcctl sftp repair`, a new subcommand that re-renders and recreates). `sftp repair` is in this task.

## 3. Changes, file by file

1. `templates/sftp.compose.yml` (new): the `sftp` service: image `atmoz/sftp`, container `mcctl-sftp`, `restart: unless-stopped`, port line from section 2, the users.conf mount, the generated server block, `cap_drop: [ALL]`, `cap_add: [CHOWN, SETGID, SETUID, DAC_OVERRIDE]`, `security_opt: ["no-new-privileges:true"]`, `mem_limit: 128m`, `pids_limit: 128`. The server block is a placeholder line `{{SERVER_MOUNTS}}`, filled by `_fill_template`.
2. `templates/stack.compose.yml`: delete the `sftp` service and its comment lines. Nothing else changes in this file (the router stack is out of scope).
3. `lib/sftp.sh`: `_sftp_render_file`, `sftp_render` (writes `sftp.compose.yml` atomically, mode 644, from the template; the server block is built from `users.conf`), `sftp_dc` (`docker compose -p mcctl-sftp -f $MCCTL_ROOT/sftp.compose.yml "$@"`), `sftp_repair` (render, and `up -d --force-recreate sftp` when the container is running). `sftp_add_user` and `sftp_remove_user` call `sftp_render` and recreate when running. The directory field loses its leading slash (F3).
4. `lib/router.sh` (`cmd_up`, `cmd_down`): also start and stop `mcctl-sftp` (`sftp_render` first). Keep `cmd_up`'s port check unchanged.
5. `lib/servers.sh`: `cmd_create` replaces `sftp_add_user "$name" 2>/dev/null || true` with `sftp_add_user "$name" || warn "...: run 'mcctl sftp repair' after fixing the cause"`; `_remove_files` does the same for `sftp_remove_user`. In `_remove_files`, put `valid_server_name "$name" || return "$EX_USAGE"` on the line directly above `rm -rf -- "$MCCTL_ROOT/servers/$name"`, and move `sftp_remove_user` above that check (F5).
6. `lib/sftp.sh` `cmd_sftp`: new subcommand `repair` (section 2). `add-key` and `remove-key` (a new subcommand: removes the key file and re-renders; required so a lost key can be revoked) call `sftp_render` and recreate when running.
7. `tests/t_invariants.sh`: the compose rules now run on each template file separately; the stack rule stays exact (one published port, 25565); the new rule for `sftp.compose.yml`: exactly one published port, bound to `127.0.0.1` unless the file says `0.0.0.0` for `MCCTL_SFTP_PUBLIC`; no `$` anywhere in the generated output.
8. `tests/t_router.sh`: the four failing assertions must pass with the `sftp` service gone from the stack template. Update only the assertions that counted SFTP; do not weaken any router assertion.
9. `tests/t_sftp.sh`: rewrite the assertions to the design above (section 4).
10. `docs/reference.md`: a `## mcctl sftp` section (add-key, remove-key, repair, the connection example through `127.0.0.1:2222`, the reconnect note, and the key-only login statement).

## 4. Tests (`single-standalone/tests/t_sftp.sh`)

1. `users.conf` line is exactly `NAME::1000:1000:NAME` (no leading slash), mode 600.
2. `sftp.compose.yml` exists after `create` and after `sftp_add_user`; it contains `/home/NAME/NAME` mounted from `<root>/servers/NAME/data`, and `/home/NAME/.ssh/keys/NAME.pub:ro` mounted from `<root>/sftp-keys/NAME`.
3. The published port is `127.0.0.1:2222:22` by default and `0.0.0.0:2222:22` with `MCCTL_SFTP_PUBLIC=1`; it is the only `ports:` entry in that file.
4. `stack.compose.yml` has no `sftp` service and no `2222`.
5. A server folder path containing a newline (create a directory name with one in the sandbox, or make `MCCTL_ROOT` contain one) is refused with `EX_PREFLIGHT`, and no `sftp.compose.yml` is written.
6. `sftp_add_user` for a missing data directory refuses (existing behaviour, kept).
7. `add-key NAME KEY.pub` appends the key to `sftp-keys/NAME` (mode 600) and re-renders; a file that is not a public key is refused (existing `_valid_pubkey`).
8. `remove-key NAME` removes the key file and the mount line; `sftp_remove_user NAME` (through `delete`) removes the user line and both mounts.
9. With the SFTP container running (fake `docker.ps` answers), `add-key` and `delete` call `docker compose -p mcctl-sftp … up -d --force-recreate sftp`; with it stopped, they do not.
10. `mcctl up` calls the router stack and `mcctl-sftp`; `mcctl down` stops both (the fake records the project names).
11. A failing `sftp_add_user` during `create` prints the warning and `create` still succeeds (the server is created; SFTP is repairable).
12. `_remove_files` with the name check moved (F5): an invalid name still refuses before any `rm`.
13. E3: `sftp_render`, `sftp_repair`, `cmd_sftp` named in tests; no `eval`, no `sudo`; the generated file has no `$`.
14. E4: the SFTP token and key contents never appear in `calls` or stdout (the planted canary is the key file's text).
15. E12: `sftp-users.conf` 600, `sftp-keys/` 700, key files 600, `sftp.compose.yml` 644.

## 5. Not provable in the sandbox (for the acceptance run, Task 23 step 9)

That `atmoz/sftp` reads `/home/NAME/.ssh/keys/NAME.pub` as the README states (checked against the README, not a running container); that a key login succeeds; that the bind mount shows the server's files to the SFTP user with UID 1000; that `--force-recreate sftp` disconnects users only briefly.

## 6. Ponytail notes

- The generated file is rewritten every time a user is added or removed. A ceiling: a few hundred servers make it large; upgrade path: one include file per server.
- SFTP recreate on every change is simple and correct; the upgrade path is `docker compose` file reload without recreate, if atmoz ever supports it.

## 7. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_sftp.sh`, `t_router.sh`, `t_invariants.sh`, `t_servers.sh`, `t_flows.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-9-fix-report.md`.
