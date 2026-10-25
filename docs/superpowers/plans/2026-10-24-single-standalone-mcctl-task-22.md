# Task 22 spec: documentation set

Status: written, not dispatched. Verified against the working tree on 2026-10-24 (after 15:32). Runs after Tasks 0 to 21 (it checks them). Model for the implementer: Sonnet (the link and anchor checker is real code).
Plan: `D:\Documents\code\pterodactyl\docs\superpowers\plans\2026-10-24-single-standalone-mcctl.md` ("Task 22").
Code root: `D:\Documents\code\pterodactyl\single-standalone\`. The itzg reference at `D:\Documents\code\pterodactyl\docs\single-standalone\` is a different folder with a similar name; `single-standalone/README.md` must say so in its first paragraph.

## 1. Goal

A documentation set that matches the code: an overview, architecture with diagrams, prerequisites, a reference for every command and configuration key, a task-oriented management guide, a troubleshooting table, a Velocity note, and the acceptance protocol template. A test (`t_docs.sh`) keeps the docs from drifting from the code.

## 2. Corrections to the plan text (the corrections win)

| # | Plan text | What is true | Rule for this task |
|---|---|---|---|
| C1 | "every `cmd_*` function has a section in `docs/reference.md`" | Today it fails: `lib/` defines 21 commands and `docs/reference.md` (392 lines) has no section for `backup` or `sftp`, although each task was to add its own. | Task 22 backfills `## mcctl backup` and `## mcctl sftp` from the code, and the test enforces the rule for everything later. |
| C2 | the test checks links and anchors | `D:\Documents\code\pterodactyl\tests\check_docs.py` does that for `ptero`, in Python. `mcctl` and its tests need only Bash and coreutils. | Write the checker in Bash (`grep`, `sed`, `awk`). To keep anchors computable: headings in `single-standalone/docs/` are ASCII; the slug is lower-case, characters other than `a-z 0-9 space _ -` removed, spaces turned into `-`. |
| C3 | "troubleshooting has one row per failure message the code can print (`grep -h 'die \|err '`)" | The code has hundreds of messages, most with variable text; one row each is neither useful nor maintainable. | A curated table of symptoms (at least 40 rows: symptom, cause, fix). The symptom column quotes a fragment of the real message in backticks, and the test requires every quoted fragment to occur verbatim in a file under `lib/` or `mcctl` (so a reworded message breaks the doc build). |
| C4 | diagrams for create, delete, restore, router/egress | The flows changed during the build. | Draw them from the code as it is (section 4.2); the test checks that each Mermaid block holds its steps in order. |
| C5 | `reference.md` documents "every env var a server folder's env file accepts" | After Task 14 the accepted keys are the table in `lib/settings.sh`. | Generate nothing; write the key table by hand, and the test checks that every key in `settings_type`'s table and every `MCCTL_*` name used under `lib/` appears in `reference.md`. |
| C6 | "Modify: `mcctl`" is not in this task | none | `mcctl` is not changed. |

## 3. Verified facts

| Thing | Where | State |
|---|---|---|
| Docs present | `single-standalone/docs/` | only `reference.md` (392 lines). Sections: init, doctor, create, start/stop/restart, kill, delete, list, status, rcon, console, whitelist/ban/kick/op, players, rotate-rcon, router and egress guard, up, down. |
| Commands in `lib/` today | `grep '^cmd_'` | `backup ban console create delete doctor down init kick kill list op players rcon restart rotate_rcon sftp start status stop up whitelist`. Tasks 10 to 21 add the rest. |
| Section heading rule | `reference.md` | `## mcctl <name>[, <name>...]`, command names with `-` for `_`. |
| Docs checker for `ptero` | `tests/check_docs.py` | links exist, anchors match headings, `docs/README.md` links every page. |
| Wording the plan fixes | Plan, Task 22 | the sentence that the game-port DNS record is DNS-only and the origin IP is reachable. |

## 4. Content

### 4.1 Files (all under `single-standalone/`)

`README.md` (first paragraph: what mcctl is; second sentence: it is not the itzg documentation in `single-standalone/docs/itzg/`), `docs/README.md` (index linking every page), `docs/architecture.md`, `docs/prerequisites.md`, `docs/reference.md` (extended), `docs/management-guide.md`, `docs/troubleshooting.md`, `docs/velocity.md`, `docs/acceptance.md` (the template of Task 23, with empty result columns).

### 4.2 `architecture.md`: Mermaid diagrams from the code

1. **create**: validate flags; `server_exists`, `hostname_taken`, leftover directory; `cf_create_record`; directories and RCON secret; config files; `write_compose`; `sftp_add_user`; `dc create`; `router_reload`; a failure after the record: `_create_undo` in reverse.
2. **delete**: `confirm`; stop; archive to `trash/NAME-<UTC>.tar.gz` and verify with `tar -tzf`; DNS removal; `dc rm -s -f`; `router_reload`; remove files and the SFTP user. A failed DNS call stops everything before any removal.
3. **backup restore** (`backup restore`): refuse while running; verify the archive; check the members; `confirm`; move `data/` aside; extract; report both paths. And **world restore** if Task 16 is in the tree.
4. **router and egress layout**: Internet to port 25565 (DNAT) to `DOCKER-USER` (`MCCTL-EGRESS`, `MCCTL-INGRESS`) to `mc-router` (static IP on `mcctl_game`) to the game containers; the backup sidecar inside each game container's network namespace; the guard container on the host network; the host INPUT drop for the game subnet.
5. **drift** (after Task 14): `set`, hash compare, `status` pending, `apply`, recreate.
Prose under each diagram says what the failure behaviour is.

### 4.3 `prerequisites.md`

Docker Engine and Compose plugin versions (state the minimums the code needs, found by reading what it calls: `docker compose create --force-recreate`, `up -d --force-recreate`, `--wait`); `bash` 4.4; `jq`, `curl`, `ss`, `tar`, GNU `sort -V`; Ubuntu and WSL notes (Spikes S1, S2, results from Task 23 when known, otherwise the words "not yet recorded"); the Cloudflare zone and token (DNS edit on that one zone, nothing else; the file `secrets/cloudflare_token`, mode 600); the CurseForge key file; `systemd-run` for the firewall timer; kernel modules `xt_connlimit`, `xt_hashlimit`, `xt_conntrack`; the firewall assumptions. It must contain this sentence, verbatim: **"The Cloudflare record for the game port is DNS-only (grey cloud); the origin IP is reachable directly, because Cloudflare's free plan cannot proxy raw Minecraft traffic. This is a protocol limit, not a defect; the firewall, the egress guard and the rate limit are what protect that address."**

### 4.4 `reference.md`

Backfill `backup` and `sftp`; add every command from Tasks 10 to 21 if their tasks did not (the test says which are missing); a `## Configuration` table of every `MCCTL_*` key with its default, accepted values and the file that reads it; a settings table (key, type, example) matching `settings_type`; exit codes; the file layout of a server folder and of the root (`servers/`, `secrets/`, `trash/`, `sftp-keys/`, `backups/`).

### 4.5 `management-guide.md`

The eight sections of the plan's Task 22 interface: worlds, settings and drift, files, players, mods/plugins/Modrinth, versions and loaders, modpacks, clone/rename/export/import. Each: when to use it, one worked example with the exact command and the output a user should see, and a "what this refuses and why" list copied from the owning task's tests.

### 4.6 `troubleshooting.md`

The curated table of C3. Seed rows come from the specs: `mcctl: confirmation required but there is no terminal`, `must be accepted to run a server`, port 25565 taken, `ufw` missing, lockout refused, `no server named`, `is already used by server`, `the DNS record of`, `is not running`, `could not archive`, `config pending`, `unsafe member`, the CurseForge key file missing, the guard unhealthy (kernel modules), `autosave state unknown`, and the rest found by reading `die` and `err` calls in `lib/`.

### 4.7 `velocity.md`

States plainly that no script manages Velocity or BungeeCord; how an operator could put one in front manually (the router would then point at the proxy); what the egress guard means for that setup. No promise beyond that.

## 5. Tests (`single-standalone/tests/t_docs.sh`, Bash only)

1. Every relative Markdown link in `README.md` and `docs/*.md` points at a file that exists; every `#anchor` matches a heading slug of its target (C2 slug rule); `docs/README.md` links every page in `docs/`.
2. Every `cmd_*` function defined under `lib/` has a section in `docs/reference.md`: a `## mcctl …` heading whose comma or "and" separated names contain the command (with `_` as `-`). The failure lists the missing commands.
3. Every `MCCTL_*` name that occurs under `lib/`, `templates/` or `config/mcctl.env.example` appears in `reference.md`; every key of `settings_type` appears in the settings table.
4. `prerequisites.md` contains the sentence of section 4.3 verbatim.
5. `architecture.md` has at least five fenced `mermaid` blocks; for create, delete, backup restore, and the router layout, the listed step words appear in the block in the listed order (an `awk` position check).
6. `troubleshooting.md`: at least 40 table rows; every backtick fragment in the first column occurs verbatim in a file under `lib/` or in `mcctl`.
7. `README.md`: its first paragraph names `single-standalone/docs/itzg/` and says the two folders are different things; both link targets exist.
8. `velocity.md` contains the words "no script manages".
9. `acceptance.md` has one section per acceptance step of Task 23 and an empty result column.
10. The checker itself is tested with a fixture folder that has a broken link, a broken anchor, a missing command section, and a stale message fragment; each is reported.
11. E3: no new `eval`, `sudo`, or Python.

## 6. Files

- Create: the files of 4.1 that do not exist, `single-standalone/tests/t_docs.sh`, `single-standalone/tests/fixtures/docs-broken/*`.
- Modify: `single-standalone/docs/reference.md`.
- Do not modify code under `lib/` except to fix a message that a doc row quotes wrongly (then fix the doc instead; the code wins).

## 7. Not provable in the sandbox

Mermaid rendering (the test checks structure, not the picture); the Spike results; whether a new reader can follow `prerequisites.md` on a clean host (Task 23 step 1 is that test).

## 8. Gate

`bash single-standalone/tests/t_docs.sh`, then the whole suite in the background (`run.sh`, and `t_invariants.sh`, both 0 failed). Report: `D:\Documents\code\pterodactyl\.superpowers\sdd\2026-10-24-single-standalone-mcctl\task-22-report.md`.
