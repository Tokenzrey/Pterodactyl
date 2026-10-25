# Task 14 spec: settings engine (`set`, `get`, `properties`, drift, `apply`)

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32) and against the itzg notes in `D:\Documents\code\pterodactyl\docs\single-standalone\`. Depends on Task 10 (planned in `2026-10-24-single-standalone-mcctl-task-10.md`: `cmd_edit`, `_env_put`).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 14").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

Any itzg setting (`MOTD`, `MAX_PLAYERS`, `DIFFICULTY`, `PVP`, and so on) can be read and changed with a command. A change is validated, written to `servers/NAME/server.env`, and rendered into `compose.yaml`. It reaches the running server only through an explicit `apply`, and `status` always says whether the running container matches the configuration (`current` or `pending`).

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | `lib/compose.sh` only "stamps the label" | `render_server_compose` reads exactly `TYPE VERSION MEMORY CPUS EULA HOSTNAME_SLUG BACKUP_ENV_FILE` from `server.env` (the `se` map and `check_server_values`) and writes `environment:` only from those plus `modpack.env` (`EXTRA_ENV`). Every other `server.env` key, for example `PVP=false`, is **never rendered**. As planned, `mcctl set s1 PVP=false` would change a file that has no effect. | The renderer emits every other `server.env` key as an `environment:` entry. Section 4.2. |
| C2 | `config_hash` is the sha256 of the rendered compose, and the compose carries the label `mcctl.config_hash` | The label would be part of the text it is computed from: the hash depends on itself. | Render once with the label value empty, hash that text (after the one-shot removal), render again with the hash as the label value. Section 4.3. |
| C3 | one-shot keys are `*_FORCE_REINSTALL` and `FORCE_REDOWNLOAD` | The Global Constraints and Task 18 add `REMOVE_OLD_MODS` as a third one-shot key. | The one-shot set is `*_FORCE_REINSTALL`, `FORCE_REDOWNLOAD`, `REMOVE_OLD_MODS`. Their rendered lines are removed before hashing. |
| C4 | `apply_pending NAME [--yes]` and "share one recreate routine with `cmd_edit`" | `--yes` is a global flag read as `MCCTL_YES` (Task 10, C1); no command parses it. Task 10's order is validate, ask, write, recreate, so one shared routine that also asks cannot serve both `edit` (ask before write) and `set --apply` (write, then ask). | Split the routine in two (section 4.5): `_recreate_guard NAME` (players check and `confirm`) and `_recreate_apply NAME` (the Docker calls). `cmd_edit` is refactored to use them; its tests stay green. |
| C5 | "`property_to_env` … in the mapping table of `single-standalone/docs/itzg/configuration.md`" read at run time | Run-time code must not depend on the repo's documentation folder, which sits outside `single-standalone/` and may not be there. | Embed the table in `lib/settings.sh` as an associative array. A test, which does run inside the repo, checks that every row of the doc's table (`## Other Server Property Mappings`, line 299 of `configuration.md`) is in the array and says SKIP when the doc is absent. |
| C6 | `icon NAME FILE\|URL` | A local file has to be written into `servers/NAME/data/`. The data directory belongs to the container's user (UID 1000), and the safe way to write there is `data_run`, which is Task 15. Task 14 comes first. | Task 14 implements `icon NAME URL [--override]` only (`ICON`, `OVERRIDE_ICON=TRUE`). The file form moves to Task 15 (`files put … server-icon.png`), with the PNG-signature and 1 MB checks. |
| C7 | "Modify: `mcctl`" | Dispatch discovers `cmd_*` functions. | `mcctl` is not changed. |
| C8 | `status` shows `config pending` | Containers created before this task carry no `mcctl.config_hash` label. | Missing label counts as pending and `status` says `config: unknown (created before tracking; mcctl apply NAME stamps it)`. |
| C9 | recreate "only the game container" | Project-wide rule: any recreate covers the whole compose project (the sidecar shares `mc`'s namespace). A stopped server is recreated with `create --force-recreate`. | `_recreate_apply` follows Task 10 section 4 step 8. |
| C10 | settings may be anything the itzg docs list | itzg warns not to change the RCON port; `mcctl rcon`, the sidecar and `rotate-rcon` assume the defaults and the secret file. | Reserved keys are refused even with `--force` (section 4.1). |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| Structural keys | `lib/compose.sh`, `render_server_compose` | `TYPE VERSION MEMORY CPUS EULA HOSTNAME_SLUG BACKUP_ENV_FILE` are read; `used=([EULA] [TYPE] [VERSION] [MEMORY] [RCON_PASSWORD_FILE])` guards duplicates against `modpack.env`. |
| Env blocks | `templates/server.compose.tmpl` | `{{VERSION_ENV}}` then `MEMORY`, `RCON_PASSWORD_FILE`, then `{{EXTRA_ENV}}`; labels `mcctl.managed`, `mcctl.name`, `mcctl.hostname`, `mc-router.host`; `restart: unless-stopped` on both `mc` and `backup`. |
| Credential refusal | `render_server_compose` | keys ending in `PASSWORD`, `PASSWD`, `SECRET`, `TOKEN`, `_KEY` return `EX_REFUSED` for `modpack.env` and `backup.env`; the same rule applies here. |
| Escaping | `compose_escape VALUE` | `$` to `$$`, `\` to `\\`, `"` to `\"`; a control character is refused. |
| `cmd_status` | `lib/servers.sh` | prints `server:`, `container:`, `address:`, `image:`, `started:` from one `docker inspect --format`. |
| itzg names | `single-standalone/docs/itzg/environment-variables.md`, `configuration.md` | present: `MOTD MAX_PLAYERS DIFFICULTY MODE PVP LEVEL_TYPE SEED ICON OVERRIDE_ICON RESOURCE_PACK RESOURCE_PACK_SHA1 RESOURCE_PACK_ENFORCE ENABLE_WHITELIST OPS WHITELIST VIEW_DISTANCE ALLOW_NETHER HARDCORE`; the property table is two columns, env var and property. |
| Planned (Task 10, not in the tree yet) | Task 10 spec | `cmd_edit`, private `_env_put FILE KEY VALUE`, the players guard, and the recreate calls. This task deletes `_env_put`. |
| Golden files | `tests/golden/*.compose.yaml` (six) | `UPDATE_GOLDEN=1` regenerates them. |

## 4. Behaviour

### 4.1 Commands and validation

- `mcctl set NAME KEY=VALUE... [--apply] [--force]`: every pair is validated first, nothing is written unless all pass. KEY matches `^[A-Z][A-Z0-9_]*$`. VALUE is one line with no control character (so no newline).
  - Known keys (`settings_type KEY` succeeds): the value must pass `settings_validate`. `bool` accepts `true|false|TRUE|FALSE` and is stored as `TRUE` or `FALSE`. `int` is `^[0-9]{1,9}$`. `enum:a,b,c` is case-insensitive and stored as the listed form. `size` is the Task 10 memory pattern. `text` has at most 1000 characters. `https-url` starts with `https://` and has no space. `sha1` is 40 hex. `json` is valid JSON (`jq -e .`), stored compact (`jq -c`), at most 8192 characters; `GENERATOR_SETTINGS` has this type (itzg: "World generation settings JSON"), and Task 16's `world new --generator-settings` relies on it.
  - Unknown key: refused naming the key, unless `--force`.
  - Always refused, even with `--force`: credential-looking keys (`...PASSWORD`, `...PASSWD`, `...SECRET`, `...TOKEN`, `..._KEY`) with the message "put it in a file under secrets/ and set KEY_FILE"; the structural keys `TYPE VERSION MEMORY CPUS EULA HOSTNAME_SLUG BACKUP_ENV_FILE AUTOSTART` (these have their own commands: `edit`, `version`, `type`, `autostart`); and the reserved set `RCON_PORT ENABLE_RCON RCON_PASSWORD RCON_PASSWORD_FILE CF_API_KEY CF_API_KEY_FILE`.
  - Writes go through `write_atomic` (one write for all pairs); `server_env_set NAME KEY VALUE` is the single-key primitive and replaces Task 10's `_env_put`.
  - `--apply`: after writing, run `apply_pending NAME`. Without it, say "config pending: mcctl apply NAME" and do not touch the container.
- `mcctl get NAME KEY` prints the value or exits 1 when the key is not set. `mcctl unset NAME KEY...` removes keys (a structural key is refused). `mcctl env NAME` prints `server.env` without comments.
- `mcctl properties NAME list | get KEY | set KEY VALUE | dump`: `KEY` is a `server.properties` name such as `max-players`. `property_to_env PROPERTY` upper-cases it and turns `-` and `.` into `_` and succeeds only when the result is in the embedded table (C5) or one of `MOTD DIFFICULTY MODE LEVEL LEVEL_TYPE SEED`; otherwise exit 2. `rcon.port` and `rcon.password` are refused with the itzg reason. `list` prints the table; `dump` prints the server's own `data/server.properties` when it exists (read-only, through a plain `cat`; Task 15 owns anything cleverer).
- `mcctl motd NAME TEXT` = `set MOTD=TEXT`. `mcctl icon NAME URL [--override]` = `set ICON=URL`, plus `OVERRIDE_ICON=TRUE` with `--override`; a non-https URL is refused. `mcctl resourcepack NAME URL --sha1 HEX [--enforce]` = `RESOURCE_PACK`, `RESOURCE_PACK_SHA1`, and `RESOURCE_PACK_ENFORCE=TRUE` with `--enforce`; the URL must be https and `--sha1` is required. `mcctl autostart NAME on|off` sets the structural key `AUTOSTART` (default `on`); the renderer writes `restart: unless-stopped` for `on` and `restart: "no"` for `off`, on both services.

### 4.2 The renderer (`lib/compose.sh`, `templates/server.compose.tmpl`)

- After the structural env lines, emit one `      KEY: "escaped"` line for every other `server.env` key, sorted by key, before the `modpack.env` entries. A key that also occurs in `modpack.env` or among the built-in keys is the existing "set twice" error. A credential-looking key is `EX_REFUSED`.
- The template gets `{{RESTART}}` (both services) and one new label `- "mcctl.config_hash={{CONFIG_HASH}}"`.
- `check_server_values` is unchanged.

### 4.3 Drift

- `config_hash NAME`: render with `CONFIG_HASH` empty; delete the env lines whose key is `*_FORCE_REINSTALL`, `FORCE_REDOWNLOAD` or `REMOVE_OLD_MODS`; print the sha256 (64 hex). The same input gives the same hash, and the label value never feeds it.
- `write_compose NAME` renders with the label set to that hash.
- `cmd_status` gains a line `config:    current`, `config:    pending (mcctl apply NAME)`, or the unknown form of C8, comparing the container's label (`{{index .Config.Labels "mcctl.config_hash"}}`, added to the existing `docker inspect --format`) with `config_hash NAME`.

### 4.4 `apply_pending NAME` and `mcctl apply NAME`

If the hashes are equal: say "nothing to apply" and make no Docker call. Otherwise: `write_compose NAME`, `_recreate_guard NAME`, `_recreate_apply NAME`. A declined guard leaves the files as they are (the config stays pending).

### 4.5 Shared recreate routine (`lib/servers.sh`, refactor of Task 10)

- `_recreate_guard NAME`: a stopped server needs nothing. A live one: ask who is online (`rcon_exec NAME list`, parse `There are ([0-9]+) of a max`); more than 0 or unknown: require `MCCTL_YES=1` (exit 4, message with `players online` or `who is online` and `--yes`); 0: `confirm`.
- `_recreate_apply NAME`: live: `dc NAME up -d --force-recreate`, then `router_reload` (a failure only warns); stopped: `dc NAME create --force-recreate`. A failed Docker call: exit 1 with "the files are written".
- `cmd_edit` calls guard, then writes, then apply. Its tests (Task 10) must pass unchanged. Delete `_env_put`.

## 5. Tests (`single-standalone/tests/t_settings.sh`, plus changes to `t_compose.sh` and `t_edit.sh`)

1. Validation table, at least 25 cases: bool (`true`, `FALSE`, `maybe`, empty); int (`20`, `-1`, `1e3`, ten digits); enum (`hard`, `HARD`, `impossible`); `https-url`; `sha1` (39, 40, 41 chars; non-hex); text over 1000; newline and a control character refused; KEY forms (`pvp`, `1X`, `A-B`).
2. Refusals that `--force` does not lift: `RCON_PASSWORD=x`, `CF_API_KEY=x`, `FOO_TOKEN=x`, `RCON_PORT=1`, `ENABLE_RCON=false`, `TYPE=FABRIC`, `MEMORY=9G`, `AUTOSTART=maybe`. Unknown key refused without `--force` (message names it), accepted with it.
3. Render (C1): `set s1 PVP=false MAX_PLAYERS=20` then `compose.yaml` has `PVP: "FALSE"` and `MAX_PLAYERS: "20"` in sorted order before the `modpack.env` entries; the same key in `modpack.env` is the "set twice" error.
4. Inert MOTD: `MOTD='$HOME "q" \n §'` renders `$$HOME`, `\"q\"`, `\\n`, and `§` intact, and no variable is interpolated (assert the exact line).
5. Hash: stable across two renders; changes with a different MOTD; independent of the label (setting a different label changes nothing); `FABRIC_FORCE_REINSTALL`, `FORCE_REDOWNLOAD`, and `REMOVE_OLD_MODS` set then unset leave `status` at `config: current`.
6. Status: fake `docker inspect` with a matching label gives `current`; a differing one gives `pending`; an empty one gives the unknown form.
7. `apply` equal: zero `docker compose` calls and "nothing to apply". Differing: the ordered calls are inspect, `exec … rcon-cli list`, `up -d --force-recreate` (no service name), then the HUP. Stopped: `create --force-recreate`. Players online without `--yes`: exit 4 and files unchanged but the config stays pending.
8. `set … --apply` end to end with the fakes; `set` without `--apply` makes no `docker compose` call and prints `config pending`.
9. `properties`: `set max-players 20` writes `MAX_PLAYERS=20`; `rcon.port` and `rcon.password` refused with the reason; an unmapped property exits 2; `list` prints every row of the embedded table; `dump` reads `data/server.properties` or says there is none. The doc-sync test (C5) passes or SKIPs.
10. `icon` https only (`--override` adds `OVERRIDE_ICON=TRUE`); `resourcepack` needs a 40-hex `--sha1` and https; `--enforce` adds the enforce key; `autostart off` renders `restart: "no"` on both services, `on` renders `unless-stopped`.
11. Goldens: regenerate all six with `UPDATE_GOLDEN=1`; the diff of each is exactly the new label line (and `restart:` is unchanged). Add a seventh fixture with settings and a special MOTD.
12. Atomicity (E11): `set` with one invalid pair among valid ones writes nothing; a failing render leaves `server.env` as it was.
13. Canary (E4): after tests 3 to 8 the planted RCON secret is in no output and no call.
14. Task 10's `t_edit.sh` passes unchanged after the refactor.
15. E3: every new `cmd_*` is named in a test; no `eval`; no `sudo`. Flow (E13): `set`, `status` (pending), `apply`, `status` (current), in `tests/t_flows.sh`.

## 6. Files

- Create: `single-standalone/lib/settings.sh` (functions above, the type table, the embedded property table, `cmd_set cmd_get cmd_unset cmd_env cmd_apply cmd_properties cmd_motd cmd_icon cmd_resourcepack cmd_autostart`), `single-standalone/tests/t_settings.sh`.
- Modify: `single-standalone/lib/compose.sh`, `single-standalone/templates/server.compose.tmpl`, `single-standalone/lib/servers.sh` (status line, recreate split, delete `_env_put`), `single-standalone/tests/golden/*.compose.yaml`, `single-standalone/tests/t_compose.sh`, `single-standalone/tests/t_edit.sh` (only if the refactor needs it), `single-standalone/tests/t_flows.sh`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

Sections for `set`, `get`, `unset`, `env`, `apply`, `properties`, `motd`, `icon`, `resourcepack`, `autostart`; the pending model (what `status` shows and how `apply` resolves it); the key table with types; the always-refused list and why; one troubleshooting row for "I changed a setting and nothing happened".

## 8. Carry-overs

- Task 15: owns `icon NAME FILE` (writes `data/server-icon.png`, PNG signature and 1 MB checks).
- Task 18: its reinstall and `update --clean` flows rely on the one-shot rule of section 4.3 and on `_recreate_guard` and `_recreate_apply`.
- Task 21: `clone` copies `server.env`; the label is recomputed by `write_compose`.

## 9. Not provable in the sandbox

That itzg really turns each rendered variable into the property named in its table; that `restart: "no"` keeps the server down after a daemon restart; label inspection on the real Docker.

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_settings.sh`, `t_compose.sh`, `t_edit.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-14-report.md`.
