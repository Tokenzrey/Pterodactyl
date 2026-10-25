# itzg/docker-minecraft-server Documentation

> **Type:** Index · **For:** All readers · **Updated:** 2026-10-23

This page maps the entire documentation set for the [itzg/docker-minecraft-server](https://github.com/itzg/docker-minecraft-server) Docker image based on your goal: getting started, selecting a server type, configuring properties, deploying to production, or troubleshooting problems. All content is sourced exclusively from the [GitHub repository](https://github.com/itzg/docker-minecraft-server) and [ReadTheDocs](https://docker-minecraft-server.readthedocs.io/en/latest/) — see [PLAN.md](PLAN.md) for the source-bounding constraint.

## Where to start

| Goal | Read | Type |
|------|------|------|
| Understand what the image does and run a first server | [Introduction](introduction.md) | Concept + Tutorial |
| Choose a Minecraft version (LATEST, SNAPSHOT, specific) | [Versions](versions.md) | Guide + Reference |
| Pick a server type (VANILLA, FORGE, FABRIC, PAPER, etc.) | [Server Types](server-types.md) | Reference |
| Install a modpack (CurseForge, Modrinth, FTB, ZIP) | [Modpacks](modpacks.md) | Guide + Reference |
| Add individual mods or plugins | [Mods and Plugins](mods-and-plugins.md) | Guide + Reference |
| Configure server.properties via environment variables | [Configuration](configuration.md) | Reference |
| Look up every environment variable | [Environment Variables](environment-variables.md) | Reference |
| Deploy with Docker Compose, Kubernetes, Helm, Ansible | [Deployment](deployment.md) | Guide + Reference |
| See ready-to-use examples (GeyserMC, mc-router, Lazymc) | [Examples](examples.md) | Reference |
| Operate the server (auto-upgrade, RCON, JVM, icons) | [Operations](operations.md) | Guide |
| Solve a problem (EULA, Forge, Fabric, RCON, etc.) | [Troubleshooting](troubleshooting.md) | Guide |
| Review security considerations (EULA, RCON, whitelist) | [Security](security.md) | Concept + Guide |
| Find the meaning of a term | [Glossary](GLOSSARY.md) | Reference |
| Understand documentation decisions | [ADR directory](adr/) | Records |

## Reading paths by role

- **Beginner (new to Minecraft servers).** Start with [Introduction](introduction.md) for the quick start and persistent data basics. Then read [Versions](versions.md) to understand the `VERSION` variable, and [Examples](examples.md) for copy-paste Docker Compose snippets. Consult [Glossary](GLOSSARY.md) whenever a term is unfamiliar.

- **Operator (running servers in production).** Begin with [Server Types](server-types.md) and [Configuration](configuration.md) to set up the server correctly. Use [Environment Variables](environment-variables.md) as your day-to-day reference. Read [Deployment](deployment.md) for Kubernetes/Helm/Ansible patterns, [Operations](operations.md) for auto-upgrade and RCON, and [Troubleshooting](troubleshooting.md) when something breaks. Review [Security](security.md) before exposing the server publicly.

- **Developer (integrating programmatically).** Use [Environment Variables](environment-variables.md) as the complete API surface for the image. Read [Configuration](configuration.md) for the full server-property mapping and [Mods and Plugins](mods-and-plugins.md) for attach points (`/mods`, `/plugins`, `/config`) and config file processing. Consult [Deployment](deployment.md) for mc-router auto-scaling and programmatic deployment patterns.

## Search by symptom

| Symptom | See |
|---------|-----|
| Container exits immediately, EULA not accepted | [Troubleshooting: EULA Not Accepted](troubleshooting.md#eula-not-accepted) |
| Forge installation fails with installer error | [Troubleshooting: Forge Installation Error](troubleshooting.md#forge-installation-error) |
| Fabric launcher jar is corrupted | [Troubleshooting: Fabric Launcher Corrupted](troubleshooting.md#fabric-launcher-corrupted) |
| Paper build not found for requested version | [Troubleshooting: Paper Build Not Found](troubleshooting.md#paper-build-not-found) |
| RCON commands not working or connection refused | [Troubleshooting: RCON Features Not Working](troubleshooting.md#rcon-features-not-working) |
| Invalid difficulty value error | [Troubleshooting: Invalid Difficulty Value](troubleshooting.md#invalid-difficulty-value) |
| Cleanroom version mismatch with Minecraft 1.12.2 | [Troubleshooting: Cleanroom Version Mismatch](troubleshooting.md#cleanroom-version-mismatch) |
| Old server jar files accumulating in data directory | [Troubleshooting: Old Server Jar Files Accumulating](troubleshooting.md#old-server-jar-files-accumulating) |
| Zip modpack not installing or extracting | [Troubleshooting: Zip Modpack Not Installing](troubleshooting.md#zip-modpack-not-installing) |

## File inventory

| File | Type | For | Description |
|------|------|-----|-------------|
| [README.md](README.md) | Index | All | This navigation index |
| [PLAN.md](PLAN.md) | Plan | Author | Exploration strategy, skill orchestration, source-to-output mapping |
| [GLOSSARY.md](GLOSSARY.md) | Reference | All | Domain terminology with cross-references |
| [introduction.md](introduction.md) | Concept + Tutorial | Beginner | Overview, quick start, persistent data, what the image provides |
| [versions.md](versions.md) | Guide + Reference | Operator | `VERSION` variable, LATEST/SNAPSHOT/specific versions, upgrades |
| [server-types.md](server-types.md) | Reference | Operator | All server types: VANILLA, FORGE, NeoForge, Cleanroom, FABRIC, PAPER, Pufferfish, Purpur, Leaf, Folia, SPIGOT, BUKKIT, QUILT |
| [modpacks.md](modpacks.md) | Guide + Reference | Operator | CurseForge, Modrinth, FTB, ZIP modpacks, generic packs, OCI registry packs |
| [mods-and-plugins.md](mods-and-plugins.md) | Guide + Reference | Operator | Mods vs plugins, attach points, `MODS`/`PLUGINS` variables, config file processing, patching |
| [configuration.md](configuration.md) | Reference | Operator | Server properties, placeholders, MOTD, difficulty, whitelist, ops, RCON, query, seed, game mode, level type, resource pack |
| [environment-variables.md](environment-variables.md) | Reference | Operator, Developer | Complete environment variable reference organized by category |
| [deployment.md](deployment.md) | Guide + Reference | Operator | Docker Compose, Kubernetes (Helm, Shulker), Ansible (MASH), CloudFormation, mc-router, Lazymc, Lazytainer |
| [examples.md](examples.md) | Reference | Beginner, Operator | Basic vanilla, Bedrock/GeyserMC, mc-router, Lazymc, Lazytainer, local mods, Cardboard plugins |
| [operations.md](operations.md) | Guide | Operator | Auto-install/upgrade, RCON, world management, JVM memory, server icon, datapacks |
| [troubleshooting.md](troubleshooting.md) | Guide | Operator | EULA, Forge, Fabric, Paper, RCON, difficulty, Cleanroom, old jars, zip modpacks |
| [security.md](security.md) | Concept + Guide | Operator | EULA acceptance, RCON security, whitelist, server port, env file sourcing |
| [adr/](adr/) | Records | Author | 5 Architecture Decision Records |

## Architecture Decision Records

| ADR | Title | Status |
|-----|-------|--------|
| [0001](adr/0001-english-language.md) | English language for all documentation | Accepted |
| [0002](adr/0002-source-bounding-enforcement.md) | Source-bounding enforcement | Accepted |
| [0003](adr/0003-separate-files-per-server-type.md) | Separate files per server type | Accepted |
| [0004](adr/0004-conditional-file-generation.md) | Conditional file generation | Accepted |
| [0005](adr/0005-gfm-callout-convention.md) | GFM callout convention | Accepted |

## Conventions

**Page types.** Each page declares its type in the metadata block below the H1 title:

| Type | Meaning |
|------|---------|
| Tutorial | Learn by doing, fixed sequence |
| Guide | Accomplish a specific task |
| Reference | Complete and neutral listing |
| Concept | Explains the "why" |
| Index | Navigation hub |
| Plan | Strategy and rationale |
| Records | Decision log |

Combinations (e.g., "Concept + Tutorial") are stated explicitly.

**Metadata block.** Every page begins with `> **Type:** … · **For:** … · **Updated:** YYYY-MM-DD`.

**Callouts.** Advisory content uses GitHub Flavored Markdown callouts:

- `> [!NOTE]` — informational note
- `> [!IMPORTANT]` — critical information
- `> [!WARNING]` — security-sensitive or destructive operation

**Code blocks.** All code blocks specify a language (`yaml`, `bash`, `json`, `properties`, `dockerfile`, `console`).

**Source-citation model.** All content is traceable to:
- **S1**: [itzg/docker-minecraft-server GitHub repository](https://github.com/itzg/docker-minecraft-server)
- **S2**: [ReadTheDocs documentation](https://docker-minecraft-server.readthedocs.io/en/latest/)

No general Docker tutorials, general Minecraft guides, general Kubernetes tutorials, tangential topics, or external blog content is used. See [ADR 0002](adr/0002-source-bounding-enforcement.md) for the source-bounding enforcement decision.

**Cross-references.** Relative Markdown links (`[text](file.md#anchor)`) point to files within this documentation set. All links have been verified to resolve to existing files.

## Omitted sections

No planned documentation files were omitted. All conditional files (`operations.md`, `troubleshooting.md`, `security.md`) were generated because the authoritative sources (S1/S2) contained sufficient content for each topic. See [ADR 0004](adr/0004-conditional-file-generation.md) for the conditional generation decision.
