# Modpack Installation and Management

> **Type:** Guide + Reference · **For:** Operator · **Updated:** 2026-10-23

## Overview

By far the easiest way to work with mods and plugins, especially large numbers of them, is to utilize modpacks with one of the supported modpack platforms. Modpack platforms take a modpack identifier, file, etc. and use that to select and download the appropriate version of a mod loader (such as Forge or Fabric), download declared mods/plugins, and apply any additional files.

Modpack platforms are selected by setting `MODPACK_PLATFORM`; however, for ease of use and backward compatibility, the selection can be set in `TYPE` or `MOD_PLATFORM`.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Supported Modpack Platforms

The following modpack platforms are documented in the authoritative sources:

- [Modrinth](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/modrinth-modpacks/)
- [CurseForge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/auto-curseforge/)
- [Feed the Beast](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/ftb/)

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Zip File Modpack

You can specify the URL or container path of a "mod pack" to download and install into `mods` for Forge/Fabric or `plugins` for Bukkit/Spigot. Pass the environment variable `MODPACK`:

```bash
docker run -d -e MODPACK=http://www.example.com/mods/modpack.zip ...
```

> [!NOTE]
> The referenced URL/file must be a zip file with one or more jar files at the top level of the zip archive. Make sure the jars are compatible with the particular `TYPE` of server you are running.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Generic Pack Files

To install all server content (jars, mods, plugins, configs, etc.) from a zip or tgz file, set `GENERIC_PACK` to the container path or URL of the archive file. This can also be used to apply a CurseForge modpack that is missing a server start script and/or Forge installer.

For multiple generic packs, set `GENERIC_PACKS` with a comma separated list:

```yaml
environment:
  GENERIC_PACKS: configs-v9.0.1,mods-v4.3.6
  GENERIC_PACKS_PREFIX: https://cdn.example.org/
  GENERIC_PACKS_SUFFIX: .zip
```

This expands to `https://cdn.example.org/configs-v9.0.1.zip,https://cdn.example.org/mods-v4.3.6.zip`.

### Generic Pack Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GENERIC_PACK` | Container path or URL of a single archive | — |
| `GENERIC_PACKS` | Comma separated list of archive paths/URLs | — |
| `GENERIC_PACKS_PREFIX` | Prefix for each entry in GENERIC_PACKS | — |
| `GENERIC_PACKS_SUFFIX` | Suffix for each entry in GENERIC_PACKS | — |
| `GENERIC_PACKS_DISABLE_MODS` | Mods to disable (space or newline separated) | — |
| `SKIP_GENERIC_PACK_UPDATE_CHECK` | Skip update check | — |
| `FORCE_GENERIC_PACK_UPDATE` | Force apply generic pack(s) | — |
| `SKIP_GENERIC_PACK_CHECKSUM` | Skip SHA1 checksum generation | — |
| `GENERIC_PACKS_OCI_AUTH_FILE` | Registry login file for private OCI registry | — |

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

### Generic Packs from an OCI Registry

An entry can reference a pack stored as an [OCI](https://opencontainers.org/) artifact in a container registry by prefixing it with `oci://`:

```yaml
environment:
  GENERIC_PACKS: oci://ghcr.io/itzg/oci-modpack-template/tech:latest,oci://ghcr.io/itzg/oci-modpack-template/magic:latest
```

OCI, URL, and local-path entries can be mixed and are applied in the order given. Each artifact's layers are pulled into a content-addressed cache under `/data/packs/oci`.

The artifact must be a Minecraft modpack artifact (artifact type `application/vnd.itzg.minecraft.modpack.v1+json` with `…modpack.layer.v1.tar+gzip` layers). Validation and registry authentication are handled by `mc-image-helper`.

For a private registry:

```yaml
environment:
  GENERIC_PACKS_OCI_AUTH_FILE: /run/secrets/registry-auth.json
```

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

### Loading Container Configuration from a Pack

A pack can ship its own container configuration so that the server type, version, and other variables travel with the pack:

| Variable | Description |
|----------|-------------|
| `LOAD_ENV_FROM_GENERIC_PACK` | When "true", probes each GENERIC_PACKS entry for a top-level `.env` |
| `LOAD_ENV_FROM_FILE` | Container path or URL of a shell-style env file |
| `LOAD_ENV_FROM_ARCHIVE` | Container path or URL of a zip/tar archive containing an env file |
| `LOAD_ENV_FROM_ARCHIVE_ENTRY` | Relative path of the env file inside the archive (default: `.env`) |

Load order: generic packs first → `LOAD_ENV_FROM_FILE` → `LOAD_ENV_FROM_ARCHIVE`. Later loads override earlier ones, and all override values passed via `docker run -e`.

```bash
docker run -d \
  -e EULA=TRUE \
  -e GENERIC_PACK=https://cdn.example.org/my-pack.zip \
  -e LOAD_ENV_FROM_GENERIC_PACK=true \
  itzg/minecraft-server
```

> [!WARNING]
> The env file is sourced by `bash`, so any shell syntax it contains will be evaluated. Only point these variables at sources you trust. `EULA` cannot be set this way — it is checked before the env file is loaded.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Applying Extra Configuration Files

Download or copy additional configuration files before the server starts using `APPLY_EXTRA_FILES`. The format uses a `<` separator between destination and source:

```bash
docker run -e APPLY_EXTRA_FILES=destination<source_url[,destination2<source_url2,...] ...
```

```yaml
environment:
  APPLY_EXTRA_FILES: |
    destination<source1_url
    destination2<source2_path
```

The destination path is relative to `/data`. The `APPLY_EXTRA_FILES` feature is processed prior to patch processing, so it can be used for baseline files to be patched further at runtime.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Remove Old Mods/Plugins

When `MODPACK` is specified, you can instruct the script to delete old mods/plugins before installing new ones:

```bash
docker run -d -e REMOVE_OLD_MODS=TRUE -e MODPACK=http://www.example.com/mods/modpack.zip ...
```

> [!WARNING]
> All content of the `mods` or `plugins` directory will be deleted before unpacking new content from the MODPACK or MODS.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Cross-References

- [Server Types](server-types.md) — TYPE variable and server platforms
- [Mods and Plugins](mods-and-plugins.md) — Individual mod/plugin installation
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Examples](examples.md) — Usage examples
- [Glossary](GLOSSARY.md) — Domain terminology
