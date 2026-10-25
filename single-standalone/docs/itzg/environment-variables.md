# Environment Variables Reference

> **Type:** Reference · **For:** Operator, Developer · **Updated:** 2026-10-23

This is the complete environment variable reference for the itzg/docker-minecraft-server image, sourced from the [ReadTheDocs](https://docker-minecraft-server.readthedocs.io/en/latest/) documentation and [GitHub](https://github.com/itzg/docker-minecraft-server) repository.

> [!NOTE]
> Variables not found in the authoritative sources (GitHub repo or ReadTheDocs) are not documented here, per the source-bounding constraint.

## Core / Required

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `EULA` | Accept Mojang's EULA. Must be set to "TRUE" for the server to start. | — | [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/) |

## Version Management

| Variable | Description | Default | Accepted Values | Source |
|----------|-------------|---------|-----------------|--------|
| `VERSION` | Minecraft version to use (case sensitive) | `LATEST` | `LATEST`, `SNAPSHOT`, specific version (e.g., `1.20.4`), alpha/beta (e.g., `b1.7.3`) | [S2 versions](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/) |

## Server Types

| Variable | Description | Default | Accepted Values | Source |
|----------|-------------|---------|-----------------|--------|
| `TYPE` | Server platform type | `VANILLA` | `VANILLA`, `FORGE`, `FABRIC`, `SPIGOT`, `PAPER`, `NEOFORGE`, `QUILT`, `PUFFERFISH`, `PURPUR`, `LEAF`, `FOLIA`, `BUKKIT`, `AUTO_CURSEFORGE`, etc. | [S2 types](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/) |
| `MODPACK_PLATFORM` | Modpack platform selection | — | `AUTO_CURSEFORGE`, `MODRINTH`, etc. | [S2 types](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/) |
| `MOD_PLATFORM` | Alias for MODPACK_PLATFORM (backward compat) | — | Same as MODPACK_PLATFORM | [S2 types](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/) |

### Forge-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `FORGE_VERSION` | Forge version or "latest" | Recommended for MC version | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |
| `FORGE_INSTALLER` | Path to pre-downloaded installer jar | — | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |
| `FORGE_INSTALLER_URL` | URL to custom installer | — | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |
| `FORGE_FORCE_REINSTALL` | Force reinstallation | — | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |
| `FORGE_PROMOTIONS_URL` | Promotions JSON URL | `https://files.minecraftforge.net/...` | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |
| `FORGE_MAVEN_REPO_URL` | Maven repo URL | `https://maven.minecraftforge.net` | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |
| `APPLY_CLEANROOM` | Apply Cleanroom loader (1.12.2 only) | — | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |

### NeoForge-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `NEOFORGE_VERSION` | NeoForge version, "latest", or "beta" | Latest non-beta | [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/) |

### Fabric-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `FABRIC_LOADER_VERSION` | Fabric loader version | Latest | [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/) |
| `FABRIC_LAUNCHER_VERSION` | Fabric launcher version | Latest | [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/) |
| `FABRIC_LAUNCHER` | Custom launcher jar path | — | [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/) |
| `FABRIC_LAUNCHER_URL` | Custom launcher URL | — | [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/) |
| `FABRIC_FORCE_REINSTALL` | Force re-install | — | [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/) |
| `FABRIC_META_BASE_URL` | Fabric meta API base URL | `https://meta.fabricmc.net` | [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/) |

### Paper-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `PAPER_BUILD` | Specific Paper build | Latest | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `PAPER_CHANNEL` | Release channel | `default` | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `PAPER_DOWNLOAD_URL` | Custom download URL | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `PAPER_CONFIG_REPO` | Config repository URL | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `SKIP_DOWNLOAD_DEFAULTS` | Skip default config download | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |

### Pufferfish-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `PUFFERFISH_BUILD` | Pufferfish build | `lastSuccessfulBuild` | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `PUFFERFISH_CONFIG_REPO` | Config repository URL | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |

### Purpur-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `PURPUR_BUILD` | Purpur build | `LATEST` | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `PURPUR_DOWNLOAD_URL` | Custom download URL | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `PURPUR_CONFIG_REPO` | Config repository URL | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |

### Leaf-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `LEAF_BUILD` | Leaf build number | Latest | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |

### Folia-specific

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `FOLIABUILD` | Folia build number | Latest experimental | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `FOLIA_CHANNEL` | Release channel | `experimental` | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `FOLIA_DOWNLOAD_URL` | Custom download URL | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |

## Modpacks

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `MODPACK` | URL/path of zip modpack | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `GENERIC_PACK` | URL/path of generic pack archive | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `GENERIC_PACKS` | Comma separated list of archives | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `GENERIC_PACKS_PREFIX` | Prefix for GENERIC_PACKS entries | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `GENERIC_PACKS_SUFFIX` | Suffix for GENERIC_PACKS entries | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `GENERIC_PACKS_DISABLE_MODS` | Mods to disable | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `SKIP_GENERIC_PACK_UPDATE_CHECK` | Skip update check | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `FORCE_GENERIC_PACK_UPDATE` | Force apply | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `SKIP_GENERIC_PACK_CHECKSUM` | Skip SHA1 checksum | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `GENERIC_PACKS_OCI_AUTH_FILE` | OCI registry auth file | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `LOAD_ENV_FROM_GENERIC_PACK` | Load .env from generic packs | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `LOAD_ENV_FROM_FILE` | Load env from file/URL | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `LOAD_ENV_FROM_ARCHIVE` | Load env from archive | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `LOAD_ENV_FROM_ARCHIVE_ENTRY` | Env file path in archive | `.env` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `APPLY_EXTRA_FILES` | Extra files to apply before start | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |

## Mods

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `MODS` | Comma/newline delimited list of mod URLs/paths | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `MODS_FILE` | File listing mod URLs | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `COPY_MODS_SRC` | Source dir(s) for mod sync | `/mods` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `COPY_MODS_DEST` | Destination for mod sync | `/data/mods` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_MODS` | Remove old mods before install | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_MODS_INCLUDE` | Glob patterns to include | `*.jar` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_MODS_EXCLUDE` | Glob patterns to exclude | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_MODS_DEPTH` | Deletion depth | 16 | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |

## Plugins

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `PLUGINS` | Comma/newline delimited list of plugin URLs/paths | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `PLUGINS_FILE` | File listing plugin URLs | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `COPY_PLUGINS_SRC` | Source dir(s) for plugin sync | `/plugins` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `COPY_PLUGINS_DEST` | Destination for plugin sync | `/data/plugins` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `USES_PLUGINS` | Enable /plugins for mod-based loaders | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |

## Config Sync

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `COPY_CONFIG_SRC` | Source dir(s) for config sync | `/config` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `COPY_CONFIG_DEST` | Destination for config sync | `/data/config` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `SYNC_SKIP_NEWER_IN_DESTINATION` | Skip newer files in destination | `true` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_CONFIGS` | Remove old configs before modpack | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_CONFIGS_INCLUDE` | Glob patterns to include | `*` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_CONFIGS_EXCLUDE` | Glob patterns to exclude | — | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REMOVE_OLD_CONFIGS_DEPTH` | Deletion depth | 16 | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `CONFIG_OUT_DIR` | Config output directory | `/data/config` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |

## Server Properties

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `MOTD` | Message of the day | Computed from type/version | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `DIFFICULTY` | Difficulty level | `easy` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `MODE` | Game mode | `survival` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `LEVEL` | World save name | `world` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `LEVEL_TYPE` | World generation type | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `GENERATOR_SETTINGS` | World generation settings JSON | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `SEED` | Level seed | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `SERVER_PORT` | Server port | 25565 | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `ICON` | Server icon URL/path | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `OVERRIDE_ICON` | Override existing server icon | `false` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `RESOURCE_PACK` | Resource pack URL | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `RESOURCE_PACK_SHA1` | Resource pack checksum | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `RESOURCE_PACK_ENFORCE` | Enforce resource pack | `FALSE` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `CUSTOM_SERVER_PROPERTIES` | Custom server.properties entries | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `OVERRIDE_SERVER_PROPERTIES` | Manage server.properties via env vars | `true` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `SKIP_SERVER_PROPERTIES` | Skip server.properties creation | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `DUMP_SERVER_PROPERTIES` | Output server.properties before start | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `SERVER_PROPERTIES_ESCAPE_UNICODE` | Escape unicode in server.properties | Auto (true for <1.20) | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `SERVER_PROPERTIES_REPO_URL` | Download base server.properties | — | [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/) |
| `INITIAL_ENABLED_PACKS` | Enabled datapacks | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `INITIAL_DISABLED_PACKS` | Disabled datapacks | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |

## Whitelist

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `WHITELIST` | Player usernames/UUIDs | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `WHITELIST_FILE` | URL/path to whitelist file | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `EXISTING_WHITELIST_FILE` | Behavior when file exists | `SYNC_FILE_MERGE_LIST` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `ENFORCE_WHITELIST` | Enforce whitelist changes | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `ENABLE_WHITELIST` | Enable whitelist property | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `USER_API_PROVIDER` | Username resolution provider | `playerdb` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |

## Ops

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `OPS` | Operator usernames/UUIDs | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `OPS_FILE` | URL/path to ops file | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `EXISTING_OPS_FILE` | Behavior when file exists | `SYNC_FILE_MERGE_LIST` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |

## RCON

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `ENABLE_RCON` | Enable RCON | `true` | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `RCON_PASSWORD` | RCON password | Random per startup | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `RCON_PASSWORD_FILE` | File containing RCON password | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `RCON_PORT` | RCON port | 25575 | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |

## Query

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `ENABLE_QUERY` | Enable gamespy query | — | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |
| `QUERY_PORT` | Query port | 25565 (UDP) | [S2 config](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/) |

## Config File Processing

| Variable | Description | Default | Source |
|----------|-------------|---------|--------|
| `REPLACE_ENV_IN_PLACE` | Replace env vars in /data files | `true` | [S2 interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/) |
| `REPLACE_ENV_DURING_SYNC` | Replace env vars during sync | `false` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REPLACE_ENV_VARIABLE_PREFIX` | Prefix for replaceable vars | `CFG_` | [S2 interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/) |
| `REPLACE_ENV_SUFFIXES` | File suffixes to process | `yml,yaml,txt,cfg,conf,properties,hjson,json,tml,toml` | [S2 mods](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/) |
| `REPLACE_ENV_VARIABLES_EXCLUDES` | Files to exclude | — | [S2 interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/) |
| `REPLACE_ENV_VARIABLES_EXCLUDE_PATHS` | Paths to exclude | — | [S2 interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/) |
| `PATCH_DEFINITIONS` | Patch definition files/dir | — | [S2 interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/) |

## Other Server Property Mappings

See [configuration.md](configuration.md#other-server-property-mappings) for the complete table of environment variable to server property mappings (50+ variables including `ALLOW_FLIGHT`, `ALLOW_NETHER`, `MAX_PLAYERS`, `ONLINE_MODE`, `PVP`, `VIEW_DISTANCE`, etc.).

## Cross-References

- [Configuration](configuration.md) — Server properties and configuration details
- [Server Types](server-types.md) — TYPE variable and type-specific variables
- [Mods and Plugins](mods-and-plugins.md) — Mod/plugin variables in context
- [Glossary](GLOSSARY.md) — Domain terminology
