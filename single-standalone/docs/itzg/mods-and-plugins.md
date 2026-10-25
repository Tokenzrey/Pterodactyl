# Working with Mods and Plugins

> **Type:** Guide + Reference · **For:** Operator · **Updated:** 2026-10-23

## Mods vs Plugins

The terms "mods" and "plugins" can be quite confusing. Generally:

- **Mods** are used by types that run client-side to modify rendering, add new blocks, and add server behaviors — such as [Forge](server-types.md#forge) and [Fabric](server-types.md#fabric). Typically, mods need to be installed on both the client and server; however, there are some cases when only the server needs a mod.
- **Plugins** are used by types that **only run on servers** to add behaviors, commands, etc. — such as [Paper](server-types.md#paper) (which derives from Bukkit/Spigot). Plugins only need to be installed on the server and are never needed on the client.
- **Hybrids** (e.g., Magma) use both mods and plugins.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Optional Plugins, Mods, and Config Attach Points

There are optional volume paths that can be attached to supply content to be copied into the data area:

### /plugins

Content in this directory is synchronized into `/data/plugins` for server types that use plugins. For special cases, the source can be changed by setting `COPY_PLUGINS_SRC` and destination by setting `COPY_PLUGINS_DEST`. If using a mod-based loader (such as Forge or Fabric) but a hybrid mod like [Cardboard](https://modrinth.com/mod/cardboard), then set `USES_PLUGINS` to have the automation utilize the `/plugins` mount.

```yaml
environment:
  EULA: "TRUE"
  TYPE: "FABRIC"
  MODRINTH_PROJECTS: |
    fabric-api
    cardboard
  USES_PLUGINS: true
```

### /mods

Content in this directory is synchronized into `/data/mods` for server types that use mods. For special cases, the source can be changed by setting `COPY_MODS_SRC` and destination by setting `COPY_MODS_DEST`.

```yaml
environment:
  EULA: "TRUE"
  TYPE: "NEOFORGE"
volumes:
  - "./data:/data"
  - "./mods:/mods"
```

### /config

Contents are synchronized into `/data/config` by default, but can be changed with `COPY_CONFIG_DEST`. For example, `-v ./config:/config -e COPY_CONFIG_DEST=/data` will allow you to copy over files like `bukkit.yml` directly into the server directory. The source can be changed by setting `COPY_CONFIG_SRC`. Set `SYNC_SKIP_NEWER_IN_DESTINATION=false` if you want files from `/config` to take precedence over newer files in `/data/config`.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

### Environment Variable Processing in Synced Files

By default, environment variable processing is performed on synchronized files that match the expected suffixes in `REPLACE_ENV_SUFFIXES` (by default "yml,yaml,txt,cfg,conf,properties,hjson,json,tml,toml") and are not excluded by `REPLACE_ENV_VARIABLES_EXCLUDES` and `REPLACE_ENV_VARIABLES_EXCLUDE_PATHS`. This processing can be disabled by setting `REPLACE_ENV_DURING_SYNC` to "false".

### Removing Old Mods/Plugins

If you want old mods/plugins to be removed before content is brought over from attach points, add `-e REMOVE_OLD_MODS=TRUE`. Fine-tune with:

| Variable | Description | Default |
|----------|-------------|---------|
| `REMOVE_OLD_MODS_INCLUDE` | Comma separated list of file glob patterns to include | `*.jar` |
| `REMOVE_OLD_MODS_EXCLUDE` | Comma separated list of file glob patterns to exclude | — |
| `REMOVE_OLD_MODS_DEPTH` | Only delete files up to this level | 16 |

Example: `-e REMOVE_OLD_MODS=TRUE -e REMOVE_OLD_MODS_INCLUDE="*.jar" -e REMOVE_OLD_MODS_DEPTH=1` removes all old jar files directly inside `plugins/` or `mods/`.

To remove all files in `/data/config` before a modpack is downloaded and unpacked, set `REMOVE_OLD_CONFIGS=TRUE`:

| Variable | Description | Default |
|----------|-------------|---------|
| `REMOVE_OLD_CONFIGS_INCLUDE` | File glob patterns to include | `*` |
| `REMOVE_OLD_CONFIGS_EXCLUDE` | File glob patterns to exclude | — |
| `REMOVE_OLD_CONFIGS_DEPTH` | Only delete files up to this level | 16 |
| `CONFIG_OUT_DIR` | Target directory for config | `/data/config` |

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

### Multiple Source Directories

`COPY_PLUGINS_SRC`, `COPY_MODS_SRC`, `COPY_CONFIG_SRC` can each be set to a comma or newline delimited list of container directories:

```yaml
environment:
  TYPE: PAPER
  COPY_PLUGINS_SRC: /plugins-common,/plugins-local
volumes:
  - mc-data:/data
  - ../plugins-common:/plugins-common:ro
  - ./plugins:/plugins-local:ro
```

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Mods/Plugins List

Download or copy individual mods/plugins using the `MODS` or `PLUGINS` environment variables. Both accept a comma or newline delimited list of:

- URL of a jar file
- Container path to a jar file
- Container path to a directory containing jar files

```bash
docker run -d -e MODS=https://www.example.com/mods/mod1.jar,/plugins/common,/plugins/special/mod2.jar ...
```

Newline delimiting for compose file usage:

```yaml
environment:
  PLUGINS: |
    https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
    https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
```

> [!NOTE]
> Entries removed from the `MODS` or `PLUGINS` list will be automatically removed from the `mods` or `plugins` directory. An empty list will remove all mods/plugins. To temporarily disable processing, comment out the environment variable.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Mod/Plugin URL Listing File

As an alternative to `MODS`/`PLUGINS`, set `MODS_FILE` or `PLUGINS_FILE` with the container path or URL of a text file listing mod/plugin URLs on each line:

```bash
docker run -e MODS_FILE=/extras/mods.txt ...
```

The file might look like:

```
https://edge.forgecdn.net/files/2965/233/Bookshelf-1.15.2-5.6.40.jar
https://edge.forgecdn.net/files/2926/27/ProgressiveBosses-2.1.5-mc1.15.2.jar
# This and next line are ignored
#https://edge.forgecdn.net/files/3248/905/goblintraders-1.3.1-1.15.2.jar
https://edge.forgecdn.net/files/3272/32/jei-1.15.2-6.0.3.16.jar
```

> [!NOTE]
> Blank lines and lines that start with a `#` will be ignored.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Modifying Config Files

### Replacing Variables Inside Configs

When `REPLACE_ENV_IN_PLACE` is set to `true` (the default), the startup script replaces variables in files inside `/data` that match container environment variables. Variables can also be replaced in files synced from `/plugins`, `/mods`, and `/config` by setting `REPLACE_ENV_DURING_SYNC` to `true`.

Variables must be declared inside curly brackets prefixed with a dollar sign: `${CFG_YOUR_VARIABLE}`.

Change `REPLACE_ENV_VARIABLE_PREFIX` (default "CFG\_") to limit which environment variables are allowed. Set to empty string to match any variable name.

For file-based values (e.g., Docker Secrets), declare the placeholder normally and add an environment variable with `_FILE` suffix:

```yaml
# In a config file:
# password = ${CFG_DB_PASSWORD}

# In compose:
secrets:
  db_password:
    external: true
environment:
  CFG_DB_PASSWORD_FILE: /run/secrets/db_password
```

Variables are replaced in files with extensions: `.yml`, `.yaml`, `.txt`, `.cfg`, `.conf`, `.properties`. Exclude specific files via `REPLACE_ENV_VARIABLES_EXCLUDES` and paths via `REPLACE_ENV_VARIABLES_EXCLUDE_PATHS`.

**Source**: [S2 configuration/interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/)

### Patching Existing Files

JSON path based patches can be applied using `PATCH_DEFINITIONS` pointing to a directory of [patch definition JSON files](https://github.com/itzg/mc-image-helper#patchdefinition) or a [patch set JSON file](https://github.com/itzg/mc-image-helper#patchset).

```json
{
  "patches": [
    {
      "file": "/data/paper.yml",
      "ops": [
        {
          "$set": {
            "path": "$.verbose",
            "value": true
          }
        },
        {
          "$set": {
            "path": "$.settings['velocity-support'].enabled",
            "value": "${CFG_VELOCITY_ENABLED}",
            "value-type": "bool"
          }
        }
      ]
    }
  ]
}
```

Supports: JSON, JSON5, Yaml, TOML (processed output is not pretty).

**Source**: [S2 configuration/interpolating](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/interpolating/)

## Cross-References

- [Server Types](server-types.md) — TYPE variable and server platforms
- [Modpacks](modpacks.md) — Modpack platform usage
- [Configuration](configuration.md) — Server properties and configuration
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Glossary](GLOSSARY.md) — Domain terminology
