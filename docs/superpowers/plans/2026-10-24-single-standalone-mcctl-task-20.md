# Task 20 spec: mods, plugins and Modrinth project lists

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32) and `D:\Documents\code\pterodactyl\docs\single-standalone\mods-and-plugins.md`. Depends on Tasks 14 and 15 (`apply_pending`, `_recreate_guard`, `server_env_set`, `data_run`).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 20").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`.

## 1. Goal

Manage the mods, plugins and Modrinth projects of a server as declarative lists. The lists are plain files under `servers/NAME/lists/`; the renderer turns them into the itzg variables `MODS`, `PLUGINS`, `MODRINTH_PROJECTS`; itzg installs what is listed at every start. Local jars go in through an attach-point directory.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | the renderer emits `KEY: \|` block scalars "with `$` escaped as `$$`" using the existing escaping | `compose_escape` doubles `\` and escapes `"` because it is for double-quoted scalars. Inside a literal `\|` block a backslash and a quote are plain characters; only `$` is special to Compose. Using `compose_escape` would corrupt entries. | A separate `block_escape LINE` that only turns `$` into `$$` and refuses control characters. |
| C2 | local jars are "copied to `servers/NAME/mods/` (mounted at `/mods`)" | The server template mounts only `./data:/data`. Docker would create a missing bind source as a root-owned directory, which the container user cannot use. The itzg attach points are `/mods`, `/plugins`, `/config` (synchronised into `/data` at start, `mods-and-plugins.md`). | `create` makes `servers/NAME/mods` and `servers/NAME/plugins` (mode 755); the template mounts `./mods:/mods:ro` and `./plugins:/plugins:ro` for every server. Jars are mode 644 so UID 1000 can read them. All goldens gain the two mount lines; regenerate with `UPDATE_GOLDEN=1` and read the diff. Servers created before this task get the mounts at their next render (config pending). |
| C3 | the validator forbids `$`, and a test expects `$` "escaped as `$$`" | Both cannot be tested through the same path. | `valid_mod_entry` refuses `$`. The renderer escapes `$` anyway, for a hand-edited list file; each has its own test. |
| C4 | `valid_mod_entry`: "an `https://` URL, or a container path under `/mods` or `/plugins`" | A path can contain `..`. A URL can carry credentials (`https://user:pass@host/x.jar`), which would sit in `compose.yaml` as a plain value, against the Global Constraint on secrets. | Refuse any `..` component in a container path, and any `@` in the authority part of a URL. |
| C5 | `clear --remove-installed` "renders the key empty so itzg removes them" | The documentation sentence is "an empty list will remove all mods/plugins". Whether an environment variable set to the empty string triggers that is not stated. | Implement as the plan says, and mark it unverified: Task 23 gets a step. If the real image ignores an empty value, the fallback is for `--remove-installed` to delete the listed jars through `data_run` after the apply; the spec leaves that to a follow-up. |
| C6 | `sync [--restart]` | itzg installs at container start; `apply_pending` only acts when the hash changed. | `sync` = `apply_pending`. `sync --restart` also restarts when nothing was pending (`dc restart`), after `_recreate_guard`. |
| C7 | "Modify `mcctl`" | Dispatch discovers `cmd_*`. | `mcctl` is not changed. |
| C8 | list files are only a Task 20 matter | Task 21 (`clone`, `export`, `import`, `rename`) must carry `lists/`, `mods/` and `plugins/` with the server. | Carry-over to Task 21. |

## 3. Verified facts

| Thing | Where | Behaviour |
|---|---|---|
| `MODS`, `PLUGINS` | `mods-and-plugins.md` | accept a comma or newline delimited list of URLs and container paths; example uses a `\|` block. |
| Removal | same, line 117 | "Entries removed from the `MODS` or `PLUGINS` list will be automatically removed from the `mods` or `plugins` directory. An empty list will remove all mods/plugins. To temporarily disable processing, comment out the environment variable." |
| `USES_PLUGINS` | same | `USES_PLUGINS: true` for hybrid servers. |
| `MODRINTH_PROJECTS` | same | a `\|` block of project slugs, optionally `:version`. |
| `REMOVE_OLD_MODS` | same | removes old jars before content is brought over from the attach points. |
| Renderer | `lib/compose.sh` | `EXTRA_ENV` is a text block of `      KEY: "…"` lines; `_fill_template` takes blocks; a placeholder alone on a line vanishes when the block is empty. |
| Planned | Tasks 14, 15 | `settings_type`, `apply_pending`, `data_run`, `data_pipe`, `safe_path`. |

## 4. Behaviour

### 4.1 List files

`list_file NAME KEY` = `servers/NAME/lists/<key lower-case>.list` for `MODS`, `PLUGINS`, `MODRINTH_PROJECTS`; one entry per line, no blank or comment lines. `list_add NAME KEY ENTRY` (validates, ignores a duplicate with "already in the list", writes through `write_atomic`), `list_remove NAME KEY ENTRY`, `list_clear NAME KEY`, `list_show NAME KEY`.

- `valid_mod_entry ENTRY`: an `https://` URL (no whitespace, quote, backtick, `$`, control character or `@` in the authority) or a container path starting `/mods/` or `/plugins/` (no `..` component), at most 500 characters.
- `valid_modrinth_entry ENTRY`: `^[a-z0-9_-]{1,64}(:[A-Za-z0-9._-]{1,64})?$`.

### 4.2 Rendering (`lib/compose.sh`, `templates/server.compose.tmpl`)

For each list file that exists and has at least one entry, emit `      KEY: |` followed by one line per entry indented 8 spaces, each through `block_escape`. An absent file emits nothing. A file that exists and is empty is the `--remove-installed` state (C5) and emits `      KEY: ""`. `clear` without the flag deletes the file; with it, truncates to empty after `confirm`. The template mounts `./mods:/mods:ro` and `./plugins:/plugins:ro` (C2).

### 4.3 Commands (`lib/mods.sh`)

- `mcctl mods NAME list|installed|add URL|FILE...|remove ENTRY|clear [--remove-installed]|sync [--restart]`; `mcctl plugins NAME …` (same; `add --hybrid` also `server_env_set USES_PLUGINS true`); `mcctl modrinth NAME list|add PROJECT[:VERSION]|remove PROJECT|clear`.
- `add FILE`: a local file starting with the zip signature `PK` and at most 200 MB is copied into `servers/NAME/mods/` or `plugins/` (mode 644) and is **not** added to the list (it is the attach point). A directory or a missing file is refused.
- `add URL`: C4 validation; added to the list; prints `config pending: mcctl mods NAME sync`.
- `remove ENTRY`: removes a list line; for a local jar name, removes the file from the attach-point directory.
- `list`: the declared list, then the attach-point files. `installed`: the jars actually present under `data/mods` or `data/plugins` through `data_run … ls`.
- `mods add` on a plugin type (`PAPER SPIGOT BUKKIT PURPUR PUFFERFISH LEAF FOLIA`) and `plugins add` on a mod loader (`FORGE NEOFORGE FABRIC QUILT`) are refused without `--force`.
- `sync` per C6; every change message says whether the server must restart.

## 5. Tests (`single-standalone/tests/t_mods.sh`; E5 goldens regenerated)

1. `valid_mod_entry` table, at least 25 cases: accepts `https://x.example/a.jar`, `/mods/a.jar`, `/plugins/common`; refuses `http://`, a newline, a space, `$`, a quote, a backtick, `https://u:p@x/a.jar`, `/mods/../etc`, `/etc/x`, 501 characters, empty. Same style for `valid_modrinth_entry`.
2. A duplicate add is ignored and says so; ordering follows the file.
3. Render: `MODS: |` with entries in file order, 8-space indent, no quote or backslash doubling (C1: an entry containing `\` is preserved, though the validator refuses it, so test `block_escape` directly); `$` in a hand-edited file becomes `$$` (C3); a control character in a hand-edited file makes the render fail; absent file emits nothing; empty file emits `KEY: ""`.
4. Goldens: all six gain exactly the two mount lines; add one fixture with all three lists.
5. `create` makes `mods/` and `plugins/` mode 755 (E12; SKIP without POSIX modes); a local jar is copied with mode 644 only when it starts with `PK` and is at most 200 MB (use a sparse or truncated file for the size case), is not in the list, and a non-jar is refused.
6. `mods list` shows the declared list and the attach-point files; `installed` makes a `docker run … ls` call and nothing else; works for a stopped server.
7. `clear` removes the file and leaves jars alone; `clear --remove-installed` asks `confirm` (declined: nothing changes) and leaves an empty file that renders `KEY: ""`.
8. Type guards: `mods add` on `PAPER` and `plugins add` on `FABRIC` refused with `--force` lifting it; `plugins add --hybrid` writes `USES_PLUGINS`.
9. `sync`: with a pending change it ends in the recreate calls of Task 14; with nothing pending and no flag it says "nothing to apply" and makes no call; `sync --restart` with nothing pending asks the guard and runs `compose … restart`.
10. `modrinth add fabric-api` and `lithium:mc1.21-0.13.0` accepted; `"x y"`, `A`, `x:` refused.
11. E6: both validators and `block_escape` join the property test; E4 canary; E11 atomic list writes (a failing write leaves the old list); E3 (`cmd_mods cmd_plugins cmd_modrinth` named in tests, no `eval`, no `sudo`).
12. Flow (E13): `modrinth add`, `mods add URL`, `sync`, `mods installed`, `mods remove`, `sync` in `tests/t_flows.sh`.

## 6. Files

- Create: `single-standalone/lib/mods.sh`, `single-standalone/tests/t_mods.sh`.
- Modify: `single-standalone/lib/compose.sh` (`block_escape`, list rendering), `single-standalone/templates/server.compose.tmpl` (two mounts, one block placeholder), `single-standalone/lib/servers.sh` (`create` makes the attach-point directories), `single-standalone/tests/golden/*.compose.yaml`, `single-standalone/tests/t_compose.sh`, `single-standalone/tests/t_fuzz.sh`, `single-standalone/tests/t_flows.sh`, `single-standalone/docs/reference.md`.
- Do not modify: `single-standalone/mcctl`.

## 7. Documentation

`## mcctl mods, plugins, modrinth`: the declarative model ("the list is the truth: what you remove is removed at next start"); the attach points and why a local jar is not in the list; the type guards; `sync`; the `--remove-installed` caveat (C5); that mods placed by hand with `mcctl files put` are outside the list; that a removed entry is deleted by itzg and a backup is the way back.

## 8. Carry-overs

Task 21 carries `lists/`, `mods/` and `plugins/` in `clone`, `export`, `import`, `rename`. Task 23 gains a step: add a local jar, start, see it in `/data/mods`; `modrinth add fabric-api`; `clear --remove-installed` really empties the directory; a jar placed with `files put` survives a `sync`.

## 9. Not provable in the sandbox

That an empty `MODS: ""` removes installed mods (C5); that itzg leaves hand-placed jars alone; that `/mods:ro` is readable by the container user; that `PK` plus a size cap is enough to keep out junk (it is a sanity check, not a scan).

## 10. Gate

`DOCKER_HOST=unix:///nonexistent bash single-standalone/tests/t_mods.sh`, `t_compose.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-20-report.md`.
