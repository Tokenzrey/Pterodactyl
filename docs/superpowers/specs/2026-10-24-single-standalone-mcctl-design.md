# single-standalone / mcctl — design document

> **Status:** Draft for builder check · **Date:** 2026-10-24 · **Size:** Project with written design → full implementation plan next

## Intent and why

The user runs a Pterodactyl Panel deployment in this repo (`ptero`) to manage Minecraft servers (`eggs/modpack-installer/`, Subdomain Manager extension, etc.). They now want a **second, fully independent** system: a script-only (no UI) multi-server Minecraft manager built on the `itzg/minecraft-server` Docker image, reaching feature parity with what the Panel + its extensions provide today, operated entirely from the command line.

This is not a replacement, a migration path, or an integration. It shares no code, database, state, or running process with Pterodactyl. It lives at `D:\Documents\code\pterodactyl\single-standalone\` purely so the two projects stay in one place on disk and so `single-standalone/docs/itzg/` (the itzg reference docs already researched there) sits next to the code that uses them. `./ptero`'s bash architecture (lib-file layout, secrets handling, firewall/egress-guard pattern, test harness discipline) is the **design reference**, not a dependency — nothing in the new tool calls into `ptero`'s code, reads its config, or talks to its Panel.

## Goals

- One server-lifecycle command (`create`, `start`, `stop`, `restart`, `kill`, `delete`) per Minecraft server, each running as its own `itzg/minecraft-server` container.
- Multiple servers running concurrently, each independently configurable (version, loader type, modpack, resources).
- Console access and arbitrary command execution against a running server.
- Player management (whitelist, ban, kick, op) via RCON.
- Backup and restore per server.
- Live, visually-formatted resource monitoring (CPU/RAM/disk/network) and live log streaming — not raw `docker stats`/`docker compose logs` output.
- Modpack install/update from CurseForge or Modrinth, using the image's own built-in platform support.
- Cloudflare-backed subdomain management: one hostname per server, routed through a single public port.
- Host-level and container-level security matching `ptero`'s existing posture (firewall, egress isolation, resource limits).
- SFTP file access per server through one shared, dedicated SFTP container.
- Every piece of this documented: flow diagrams, prerequisites, configuration reference, troubleshooting.

## Non-goals

- No web UI, no API server, no database. Everything is a CLI command or a file on disk.
- No integration with Pterodactyl Panel, Wings, or any of its extensions. No shared secrets, no shared network, no shared state.
- No reimplementation of `eggs/modpack-installer/installer.py`. Modpack resolution is delegated entirely to `itzg/minecraft-server`'s built-in `AUTO_CURSEFORGE`/`MODRINTH` support.
- No Velocity/BungeeCord proxy automation. Documented as a manual, advanced extension point only — no script manages it.
- No generic cron/scheduled-task system beyond the backup scheduler that ships inside the `itzg/mc-backup` companion container.
- No file-registry database (no `servers.json`, no SQLite). Docker itself — container existence, labels, and compose files on disk — is the only source of truth.

## Anti-goals (would mean failure even if "working")

- A feature silently depending on Pterodactyl being installed, running, or even present on the host.
- State that can drift from Docker's actual state (a server believed to exist that Docker doesn't know about, or vice versa).
- A monitoring or log command that's just a thin `docker stats`/`docker logs` passthrough with no formatting work done — the user was explicit that visual quality and real-time refresh matter.
- Secrets (Cloudflare token, RCON passwords, S3 keys) ever appearing in shell history, process listings (`ps`), or world-readable files.

## Constraints

- **Platform**: primary target is a Ubuntu VPS; must also run under WSL for development/testing, with no code path that only works on one.
- **Language**: pure Bash (matching `ptero`'s `bash >= 4.4` floor), no new interpreter/runtime dependency. Python is acceptable only where `ptero` already leans on it for things bash does badly (e.g. JSON handling in `lib/*.py` style) — not required for this project, but allowed if a task genuinely needs it, same bar `ptero` applies.
- **Dependencies**: Docker Engine + Compose plugin, `curl`, `jq` (already implied by JSON handling needs), standard coreutils. No new TUI library, no new language runtime — monitoring/log visuals are built with ANSI escapes and `tput`, not an external tool.
- **Container image**: every Minecraft server instance runs `itzg/minecraft-server:latest` (or a pinned tag the user chooses later); no custom Dockerfile, no custom installer image.
- **Security floor**: matches `ptero`'s today — one public game port (25565) plus SSH, everything else closed; game containers cannot reach the host, LAN, or cloud metadata endpoints (iptables `DOCKER-USER` egress guard, same shape as `compose.wings.yml`'s `egress-guard` service and `lib/firewall.sh`'s `ssh_ports`/plan/apply/rollback flow). The egress guard runs as its own compose companion service (not host-iptables-only), so it works identically on a bare Ubuntu VPS and on WSL2/Docker Desktop. Because the public game port sits behind a DNS-only (non-proxied) Cloudflare record — see "Builder-check findings" — the VPS's IP is directly reachable, so host-level connection rate-limiting is part of this floor too, not optional hardening.
- **Secrets handling**: no credential (RCON password, S3/rsync keys, SFTP key material, Cloudflare API token) is ever a plain `environment:` value in a compose file. Every credential is a file under the per-server (or tool-level) secrets directory, mode 600, mounted read-only and referenced via the `_FILE`-suffix pattern the itzg image already supports where available — matching `ptero`'s `secrets/` convention and closing the `docker inspect`/`docker exec env` exposure path, not just `ps`/shell history.
- **File size / project size**: no single script file should become a monolith; follow `ptero`'s `lib/*.sh` split-by-concern pattern.

## Decisions already made (by the user, in conversation)

| # | Decision | Chosen |
|---|---|---|
| 1 | Relationship to Pterodactyl | Fully independent; shared folder location only |
| 2 | Location | `D:\Documents\code\pterodactyl\single-standalone\` |
| 3 | Platform | Ubuntu VPS (primary) + WSL (must also work) |
| 4 | Networking model | Single public port 25565, mc-router in front, hostname-based routing (like `ptero` Mode A) |
| 5 | Container image | `itzg/minecraft-server`, `TYPE` env var selects loader |
| 6 | Modpack mechanism | itzg's own built-in `AUTO_CURSEFORGE`/`MODRINTH` support — no custom installer |
| 7 | Server state / source of truth | Docker itself (container existence + labels); no separate registry file |
| 8 | Deploy unit | One folder per server, with its own `compose.yaml` |
| 9 | Backup | `itzg/mc-backup` companion container per server (cron internal to that container) |
| 10 | Backup destination | Local, S3, or rsync — chosen per server |
| 11 | RCON password | Random per restart by default; overridable via a per-server env file value |
| 12 | Cloudflare subdomain management | Rebuilt as pure script: direct Cloudflare API calls at `create`/`delete` time |
| 13 | Hostname selection | `--hostname` flag optional at `create`; defaults to a slug of the server name |
| 14 | Host firewall / egress security | Adopt `ptero`'s `lib/firewall.sh` + egress-guard pattern as-is |
| 15 | Resource limits | Settable at `create`, editable later (`mcctl edit <server> --memory ...`) |
| 16 | Generic cron/scheduled tasks | Out of scope — backup scheduling only |
| 17 | SFTP | One dedicated shared SFTP container (e.g. `atmoz/sftp`), per-server chrooted user, auto-created/removed with the server |
| 18 | Velocity/BungeeCord | Documented as a manual advanced option only; no script support |
| 19 | Monitoring output | Live-refreshing terminal TUI (not a static table) |
| 20 | Log output | Live-streaming with color/level highlighting (not raw passthrough) |
| 21 | TUI implementation | Pure Bash + ANSI escapes / `tput`; no new external TUI dependency |

## The parts of the how the user decided

Covered in full in the decisions table above — restated here only where it shapes structure:

- mc-router discovery uses **itzg's own mechanism**: Docker container labels (e.g. `mc-router.host=<hostname>.<domain>`) that itzg's mc-router image reads directly, *not* a generated `routes.json` file (`ptero`'s `games.py` approach). This is a deliberate divergence tracked in `reference_itzg_docker_minecraft_docs.md` (project memory) so future work doesn't conflate the two routing mechanisms.
- Every server is one folder (`servers/<name>/`) holding `compose.yaml`, an env file, and the itzg `/data` bind mount. The compose file is generated from a template at `create` time and regenerated (not hand-edited by the tool) on `edit`.
- Cloudflare subdomain logic is a clean-room rebuild for this context: no database, no queued job, no event hook — the `create` command calls the Cloudflare API synchronously (create DNS record, read back to confirm) and `delete` tears it down the same way. Token lives in a secrets file, never a flag or env var exposed to `ps`.

## Builder-check findings, resolved

A fresh-subagent builder check flagged five open questions before planning could start. Resolutions:

1. **Egress guard on WSL2/Docker Desktop (no host iptables reachable the way a VPS has it).** `ptero` already solves exactly this for Wings via `WINGS_MODE=container` and `compose.wings.yml`'s `egress-guard` companion service, which runs inside the Docker network precisely because "there is no host iptables to reach here" on Docker Desktop (see project memory `project_wings_container_mode`). `mcctl` adopts the same shape: the mc-router compose stack gets its own `egress-guard` companion service (not a bare host-iptables-only script), so the game network's egress block is enforced the same way regardless of whether the host is a bare Ubuntu VPS or WSL2/Docker Desktop. This is now a fixed requirement, not an optional extra for later.

2. **Cloudflare in front of a raw-TCP game port.** Resolved by the user: Minecraft's Java Edition protocol is raw TCP. Cloudflare's free/standard proxy (orange-cloud) does not proxy arbitrary TCP — only paid Spectrum does. **Decision: DNS-only (grey-cloud) A/AAAA record, free tier, no Spectrum.** This means Cloudflare here is DNS hosting only, not a shield: the VPS's public IP is directly reachable on port 25565. The documentation deliverable must state this plainly — no "hidden origin IP" or "DDoS-protected" claim for the game port. Security on the free tier instead rests entirely on constraint-already-listed items: the firewall only opens 25565 + SSH, the egress guard blocks the game network from reaching the host/LAN/cloud metadata endpoint, and (new) host-level connection rate-limiting (e.g. `iptables` recent-match or a documented `fail2ban` jail) is added to the firewall section as a free-tier mitigation for the now-exposed IP. Any admin/API surface this tool has (none planned, but noting for the plan phase) stays off the public port entirely.

3. **RCON/SFTP/S3 credential exposure via `docker inspect`/`docker exec env`, not just `ps`/history.** The anti-goal about secrets was under-specified. **Decision:** no credential (RCON password, S3 keys, SFTP key material) is ever passed as a plain `environment:` value in a server's `compose.yaml`. Every credential uses the `_FILE`-suffix / Docker secrets pattern itzg's own image already supports (e.g. `RCON_PASSWORD_FILE`, confirmed in `single-standalone/docs/itzg/security.md`), mounted read-only from the per-server secrets directory (mode 600, matching `ptero`'s `secrets/` convention). This closes the `docker inspect`/`docker exec env` leak path the reviewer identified, not just the `ps`/shell-history path the original draft named.

4. **`mcctl edit` resource-limit mechanics.** Docker cannot hot-apply `mem_limit`/`cpus` changes without recreating the container — there is no Wings-API-style live push. **Decision:** `mcctl edit <server> --memory/--cpus ...` regenerates the server's `compose.yaml` and then refuses to apply it automatically. It checks live player count over RCON; if the server is running and has players online, it prints the pending change and requires an explicit `--yes`/confirm to recreate the container (same `confirm()` discipline `ptero` already uses for destructive actions). If no players are online, it still asks for confirmation before recreating, since the server goes down briefly either way. This is now a fixed command contract, not an open implementation detail.

5. **mc-router route staleness on `delete`.** The itzg mc-router image's label-watch latency isn't documented upstream clearly enough to rely on blind auto-pickup, and `ptero`'s own `games.sh` already signals its mc-router explicitly (`compose kill -s HUP mc-router`) on every route change rather than trusting it to notice on its own. **Decision:** `mcctl create` and `mcctl delete` both send the equivalent reload signal to the mc-router container immediately after changing labels, exactly mirroring `ptero`'s `games_reload_router` pattern. This is now a fixed step in both commands' sequence, not left to "the router will pick it up."

## Amendment 2026-10-24: world and server management scope

The user asked for complete world and server management commands ("lengkap, detail, dan keseluruhan"). This widens the "versions, worlds, plugins/mods" parity line from "keys in `server.env`" to first-class commands, planned in Tasks 14 to 21:

- **Settings:** `set/get/unset`, `properties`, `motd`, `icon`, `resourcepack`, `autostart`, drift detection (`mcctl.config_hash` label) and `apply`.
- **Files:** `files NAME ls/cat/get/put/rm/mkdir/mv/edit` through a throwaway helper container confined to the server's `data/`.
- **Worlds:** `world NAME list/info/use/new/rename/delete/backup/restore/export/import/reset/seed/datapack`, with a safety archive before every destructive step.
- **Players and runtime:** `whitelist`, `ban`, and `op` each with a `list` form, plus `gamerule`, `time`, `weather`, `worldborder`, `difficulty`, `defaultgamemode`, `say`, `save`, all validated before RCON.
- **Versions:** `version`, `type`, `upgrade`, `reinstall`, with a downgrade guard.
- **Modpacks:** `modpack set/update/remove/info`, pinned versus floating.
- **Mods and plugins:** declarative list files for `MODS`, `PLUGINS`, and Modrinth projects, plus `sync`.
- **Whole-server:** `info`, `clone`, `rename`, `export`, `import`, `exec`, `shell`.
- **EULA** becomes an explicit `create --accept-eula`.

Non-goals are unchanged: no generic cron, no Velocity automation, no web UI, no Pterodactyl dependency. The plan (`docs/superpowers/plans/2026-10-24-single-standalone-mcctl.md`) is the authority for exact command syntax.

## What's left to the builder

These are implementation-detail calls a competent builder makes without coming back to the user; the plan phase should settle them, not re-ask:

- **Command name.** Design assumes `mcctl` as the invoked binary/script name (`./mcctl create ...`). Confirm or rename during plan write-up — purely cosmetic, no behavior depends on it.
- **Exact `lib/*.sh` file split** (e.g. `lib/servers.sh`, `lib/backup.sh`, `lib/sftp.sh`, `lib/cloudflare.sh`, `lib/mcrouter.sh`, `lib/firewall.sh`, `lib/monitor.sh`, `lib/logs.sh`) — mirror `ptero`'s one-concern-per-file split; precise boundaries are a plan-time call.
- **Compose template mechanics** — a literal heredoc template vs. a `yq`/`envsubst`-based generator. Either is fine as long as regeneration is idempotent and hand edits to a generated file are never silently clobbered without a diff/confirm step (match `ptero`'s `confirm`/dry-run discipline where destructive).
- **mc-router container lifecycle** — whether it's a long-running compose service started once by `mcctl init`/`mcctl up` (parallel to `ptero up` for Panel/Wings/mc-router today) or started lazily on first `create`. Recommend: started once, like `ptero`'s stack, since it's the single public entry point.
- **SFTP container's exact image and chroot mechanics** (`atmoz/sftp` config file format, per-user key vs. password) — pick one, document the choice and why.
- **Exact RCON wrapper surface**: `mcctl rcon <server> "<raw command>"` as the primitive, with `mcctl whitelist/ban/kick/op <server> <player>` as thin wrappers over it. Precise wrapper list is plan-time, but the layering (raw passthrough first, convenience commands built on top) is fixed by this design.
- **Monitoring/log TUI exact layout** (box-drawing style, color palette, refresh interval, how `all servers` vs `one server` views differ) — visual design is left to implementation, constrained only by "pure Bash + ANSI, live-refreshing, not a raw passthrough."
- **Backup destination config shape per server** (which env vars map to `itzg/mc-backup`'s own S3/rsync variables) — straight mapping work once `itzg/mc-backup`'s own env var reference is read during planning; not a design-level decision.
- **Test harness** — recommend mirroring `ptero`'s `tests/` discipline (fakebin pattern, disposable-copy runs, no real Docker in CI) rather than inventing a new one; exact fake/mocking boundary is plan-time.

## Documentation deliverable (separate from code)

Per the original request, the implementation plan must also produce, alongside the scripts:

- An architecture/flow overview (sequence diagrams for `create`, `backup`, `restore`, modpack install/update).
- A prerequisites page (Docker/Compose versions, DNS/Cloudflare zone setup, firewall assumptions) that states plainly: the Cloudflare record for the game port is DNS-only (grey-cloud), the VPS's public IP is directly reachable on it, and this is a protocol limitation (raw TCP, free-tier Cloudflare can't proxy it) — not a bug, and not something the tool silently "protects" against. Security for that exposed IP rests on the firewall + egress guard + rate-limiting, which the same page must point to explicitly.
- A full command/configuration reference (every `mcctl` subcommand, every env var a server folder's env file accepts).
- A troubleshooting guide, following the same symptom-table style already used in `single-standalone/docs/itzg/troubleshooting.md` (itzg docs) and `ptero`'s own `docs/operations.md`.

These live under `single-standalone/docs/` (the tool's own docs, separate from the already-existing itzg reference at `single-standalone/docs/itzg/` one level up — naming collision risk noted for the plan phase: the itzg docs folder and this tool's folder both being named "single-standalone" at different repo levels needs a clear README pointer so the two aren't confused).

## Cross-references

- `single-standalone/docs/itzg/` — itzg/docker-minecraft-server reference docs (source of truth for every env var this design delegates to the image).
- `ptero`'s `lib/firewall.sh`, `compose.wings.yml`'s `egress-guard` service, `lib/backup.sh`'s secrets-handling pattern — architectural references for the security and secrets sections.
- Project memory `reference_itzg_docker_minecraft_docs.md` — already flags the itzg-vs-this-repo's-egg distinction; this design adds the mc-router-labels-vs-routes.json distinction as a second thing to keep straight.
