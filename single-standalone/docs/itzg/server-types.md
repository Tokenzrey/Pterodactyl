# Server Types and Platforms

> **Type:** Reference · **For:** Operator · **Updated:** 2026-10-23

## Overview

Server types are selected by setting the `TYPE` environment variable. The default server type is the [official software provided by Mojang](https://www.minecraft.net/en-us/download/server), which can be explicitly selected by setting `TYPE` to `VANILLA`.

The **modpack platforms** take a modpack identifier, file, etc. and use that to select and download the appropriate version of a mod loader (such as Forge or Fabric), download declared mods/plugins, and apply any additional files. Modpack platforms are selected by setting `MODPACK_PLATFORM`; however, for ease of use and backward compatibility, the selection can be set in `TYPE` or `MOD_PLATFORM`.

> [!IMPORTANT]
> For all server types, the `VERSION` environment variable is used to declare the Minecraft version itself, such as 1.19.4. Each server type will have specific variables for qualifying their version in addition to the Minecraft version.

**Source**: [S2 types-and-platforms](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/)

## VANILLA

The default type. Downloads and runs the official Minecraft Java Edition server provided by Mojang.

```bash
docker run -d -e EULA=TRUE -e TYPE=VANILLA -p 25565:25565 itzg/minecraft-server
```

**Source**: [S2 types-and-platforms](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/)

## FORGE

A [Forge server](http://www.minecraftforge.net/) can be automatically downloaded, upgraded, and run by setting `TYPE` to `FORGE`.

```bash
docker run -e TYPE=FORGE ...
```

```yaml
environment:
  TYPE: FORGE
```

By default, the recommended version of Forge for the given Minecraft version is selected. The latest version can be selected by setting `FORGE_VERSION` to "latest". A specific Forge version can be set with `FORGE_VERSION`, such as "14.23.5.2854".

```bash
docker run -e TYPE=FORGE -e VERSION=1.12.2 -e FORGE_VERSION=14.23.5.2854 ...
```

### Forge-specific Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FORGE_VERSION` | Specific Forge version or "latest" | Recommended for Minecraft version |
| `FORGE_INSTALLER` | Container path to a pre-downloaded Forge installer jar | — |
| `FORGE_INSTALLER_URL` | URL to download a Forge installer from a custom location | — |
| `FORGE_FORCE_REINSTALL` | Set to "true" to force reinstallation (temporary) | — |
| `FORGE_PROMOTIONS_URL` | URL for Forge promotions JSON | `https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json` |
| `FORGE_MAVEN_REPO_URL` | URL for Forge Maven repository | `https://maven.minecraftforge.net` |

> [!NOTE]
> If an error occurred while installing Forge, it might be possible to resolve by temporarily setting `FORGE_FORCE_REINSTALL` to "true". Be sure to remove that variable after successfully starting the server.

**Source**: [S2 types-and-platforms/server-types/forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/)

### NeoForge

Support for [NeoForge](https://neoforged.net/) is provided by setting `TYPE` to `NEOFORGE`. `VERSION` specifies the Minecraft version and `NEOFORGE_VERSION` can be set to select a specific version, "latest", or "beta". By default, the latest non-beta NeoForge version for the requested Minecraft version is used.

```bash
docker run -e TYPE=NEOFORGE -e VERSION=1.20.1 -e NEOFORGE_VERSION=47.1.79 ...
```

```yaml
environment:
  TYPE: NEOFORGE
  VERSION: "1.20.4"
  NEOFORGE_VERSION: "beta"
```

**Source**: [S2 types-and-platforms/server-types/forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/)

### Cleanroom

[Cleanroom](https://github.com/CleanroomMC/Cleanroom) is a Forge alternative for Minecraft 1.12.2. It is not fully automated:

1. Choose the desired release at https://github.com/CleanroomMC/Cleanroom/releases
2. Grab the link to the `*-installer.jar` file
3. With `TYPE` set to `FORGE`, set `FORGE_INSTALLER_URL` to the installer jar's link

```yaml
environment:
  TYPE: FORGE
  FORGE_INSTALLER_URL: https://github.com/CleanroomMC/Cleanroom/releases/download/0.2.4-alpha/cleanroom-0.2.4-alpha-installer.jar
```

Alternatively, set `APPLY_CLEANROOM` to "true" with any Forge-like type:

```yaml
environment:
  EULA: true
  TYPE: AUTO_CURSEFORGE
  CF_PAGE_URL: https://www.curseforge.com/minecraft/modpacks/enigmatica2expert/files/9088147
  APPLY_CLEANROOM: true
```

> [!WARNING]
> Cleanroom **only works with 1.12.2**. Be sure to set `VERSION` to "1.12.2" when using Forge or NeoForge types with Cleanroom.

**Source**: [S2 types-and-platforms/server-types/forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/)

## FABRIC

A [Fabric server](https://fabricmc.net/) can be automatically downloaded, upgraded, and run by setting `TYPE` to `FABRIC`.

```bash
docker run -d --pull=always -e EULA=TRUE -e TYPE=FABRIC -p 25565:25565 itzg/minecraft-server
```

```yaml
environment:
  EULA: TRUE
  TYPE: FABRIC
```

By default, the container installs the latest [fabric server launcher](https://fabricmc.net/use/server/), using the latest [fabric-loader](https://fabricmc.net/wiki/documentation:fabric_loader) against the Minecraft version defined by `VERSION`.

### Fabric-specific Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FABRIC_LOADER_VERSION` | Specific Fabric loader version | Latest |
| `FABRIC_LAUNCHER_VERSION` | Specific Fabric server launcher version | Latest |
| `FABRIC_LAUNCHER` | Container path to a custom launcher jar (relative to /data) | — |
| `FABRIC_LAUNCHER_URL` | URL to a custom launcher jar | — |
| `FABRIC_FORCE_REINSTALL` | Set to "true" to force re-install on next startup | — |
| `FABRIC_META_BASE_URL` | Base URL for Fabric meta API | `https://meta.fabricmc.net` |

### Fabric API

Most Fabric mods require the Fabric API mod. Install it using the Modrinth downloads feature:

```yaml
environment:
  TYPE: FABRIC
  MODRINTH_PROJECTS: |
    fabric-api
```

**Source**: [S2 types-and-platforms/server-types/fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/)

## PAPER

A [PaperMC server](https://papermc.io/) can be automatically downloaded, upgraded, and run by setting `TYPE` to `PAPER`.

By default, the container finds and downloads the latest build for the `VERSION` chosen. If `VERSION` is not specified, the latest Minecraft version released by PaperMC is selected.

```bash
docker run ... -e TYPE=PAPER ...
docker run ... -e TYPE=PAPER -e VERSION=1.20.6 ...
docker run ... -e TYPE=PAPER -e VERSION=1.20.6 -e PAPER_BUILD=140 ...
docker run ... -e TYPE=PAPER -e PAPER_CHANNEL=experimental ...
```

### Paper-specific Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PAPER_BUILD` | Specific Paper build number | Latest |
| `PAPER_CHANNEL` | Release channel ("default" or "experimental") | "default" |
| `PAPER_DOWNLOAD_URL` | Custom URL to download Paper from | — |
| `SKIP_DOWNLOAD_DEFAULTS` | Skip checking for default config files | — |
| `PAPER_CONFIG_REPO` | Repository URL for optimized config files | — |

> [!TIP]
> If you see `No build found for version 1.21 with channel 'default'`, set `PAPER_CHANNEL` to "experimental".

### Configuration Repositories

Automatically download optimized or custom configuration files (e.g., `bukkit.yml`, `spigot.yml`, `paper-global.yml`, `purpur.yml`) by setting a repository URL. The container appends the Minecraft version to the URL (e.g., `<REPO_URL>/1.21.1/<FILE>`).

| Server Type | Variable |
|-------------|----------|
| Paper | `PAPER_CONFIG_REPO` |
| Pufferfish | `PUFFERFISH_CONFIG_REPO` |
| Purpur | `PURPUR_CONFIG_REPO` |

A base `server.properties` file can be downloaded using `SERVER_PROPERTIES_REPO_URL`:
- **Smart Mode**: If the URL does not end in `.properties`, the script appends `/${VERSION}/server.properties`
- **Direct Mode**: If the URL ends in `.properties`, it downloads that specific file

Environment variables defined in Docker configuration **override** values in the downloaded `server.properties` file.

**Source**: [S2 types-and-platforms/server-types/paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/)

### Pufferfish

A [Pufferfish](https://github.com/pufferfish-gg/Pufferfish) server — "a highly optimized Paper fork designed for large servers requiring both maximum performance, stability, and 'enterprise' features."

```bash
-e TYPE=PUFFERFISH
```

| Variable | Description | Default |
|----------|-------------|---------|
| `PUFFERFISH_BUILD` | Specific Pufferfish build | `lastSuccessfulBuild` |
| `FORCE_REDOWNLOAD` | Force re-download of server jar | `false` |
| `USE_FLARE_FLAGS` | Add flags for built-in Flare profiler | `false` |
| `PUFFERFISH_CONFIG_REPO` | Repository URL for config files | — |

### Purpur

A [Purpur](https://purpurmc.org/) server — "a drop-in replacement for Paper servers designed for configurability and new, fun, exciting gameplay features."

```bash
-e TYPE=PURPUR
```

| Variable | Description | Default |
|----------|-------------|---------|
| `PURPUR_BUILD` | Specific Purpur build | `LATEST` |
| `FORCE_REDOWNLOAD` | Force re-download of server jar | `false` |
| `USE_FLARE_FLAGS` | Add flags for built-in Flare profiler | `false` |
| `PURPUR_DOWNLOAD_URL` | Custom URL to download Purpur from | — |
| `PURPUR_CONFIG_REPO` | Repository URL for config files | — |

### Leaf

A [Leaf server](https://www.leafmc.one/) — a Paper fork focused on performance improvements and low-level optimizations.

```bash
-e TYPE=LEAF
```

| Variable | Description | Default |
|----------|-------------|---------|
| `LEAF_BUILD` | Specific Leaf build number | Latest |

### Folia

A [Folia server](https://papermc.io/software/folia) — a regionized multithreaded server fork of Paper.

```bash
docker run -d --pull=always \
    -v /path/on/host:/data -e TYPE=FOLIA \
    -p 25565:25565 -e EULA=TRUE --name mc itzg/minecraft-server
```

| Variable | Description | Default |
|----------|-------------|---------|
| `FOLIABUILD` | Specific Folia build number | Latest experimental |
| `FOLIA_CHANNEL` | Release channel | "experimental" |
| `FOLIA_DOWNLOAD_URL` | Custom URL to download Folia from | — |

> [!NOTE]
> Folia inherits from Paper. Paper's variables will override the Folia ones.

**Source**: [S2 types-and-platforms/server-types/paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/)

## SPIGOT / BUKKIT

Spigot and Bukkit are server platforms that support plugins. Set `TYPE` to `SPIGOT` or `BUKKIT` to use these platforms. See [mods-and-plugins.md](mods-and-plugins.md) for plugin management.

**Source**: [S2 types-and-platforms](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/)

## QUilt

Quilt is a modloader compatible with Fabric mods, selected by setting `TYPE` to `QUILT`.

**Source**: [S2 types-and-platforms](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/)

## Mods vs Plugins

The terms "mods" and "plugins" can be confusing:

- **Mods** are used by types that run client-side to modify rendering, add new blocks, and add behaviors — such as Forge and Fabric. Typically, mods need to be installed on both client and server.
- **Plugins** are used by types that **only run on servers** to add behaviors, commands, etc. — such as Paper (which derives from Bukkit/Spigot). Plugins only need to be installed on the server.
- **Hybrids** (e.g., Magma) use both mods and plugins.

See [mods-and-plugins.md](mods-and-plugins.md) for detailed installation guidance.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Cross-References

- [Versions](versions.md) — VERSION variable for Minecraft version selection
- [Mods and Plugins](mods-and-plugins.md) — Individual mod/plugin installation
- [Modpacks](modpacks.md) — Modpack platform usage
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Glossary](GLOSSARY.md) — Domain terminology
