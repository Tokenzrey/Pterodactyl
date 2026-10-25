# Operations

> **Type:** Guide · **For:** Operator · **Updated:** 2026-10-23

## Auto-Install and Auto-Upgrade

The image automatically downloads and installs the correct Minecraft server version, modloader, or modpack at container startup. When using `VERSION=LATEST` or `VERSION=SNAPSHOT`, an upgrade can be performed by simply restarting the container — the new server jar is downloaded and used on next startup.

> [!NOTE]
> Over time, older versions of the server jar may remain in the `/data` directory. It is safe to remove those.

**Source**: [S2 versions/minecraft](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/)

## RCON Remote Console

RCON is **enabled by default** on port 25575 within the container for graceful shutdown and backup coordination. The default password is randomly generated on each startup.

- Set `RCON_PASSWORD` for a specific password
- Set `RCON_PASSWORD_FILE` for file-based password (recommended for Docker Secrets)
- Set `ENABLE_RCON` to "false" to disable

> [!WARNING]
> Disabling RCON will remove and limit some features, such as interactive and color console support. **DO NOT change `rcon.port` via `server.properties`** or integrations will break.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## World Management

### World Save Name

Switch between world saves using `LEVEL` (default: "world"):

```bash
docker run -d -e LEVEL=bonus ...
```

### World Seed

Set `SEED` to create the world with a specific seed:

```bash
docker run -e SEED="-1785852800490497919" ...
```

### Level Type and Generator Settings

Configure world generation with `LEVEL_TYPE` and `GENERATOR_SETTINGS`:

```yaml
environment:
  LEVEL_TYPE: FLAT
  GENERATOR_SETTINGS: >-
      {
          "layers": [
              { "block": "minecraft:bedrock", "height": 1 },
              { "block": "minecraft:stone", "height": 2 },
              { "block": "minecraft:sandstone", "height": 15 }
          ],
          "biome": "minecraft:desert"
      }
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## JVM Memory Configuration

Set JVM memory using the `MEMORY` environment variable:

```yaml
environment:
  MEMORY: 4G
```

**Source**: [S2 misc/examples](https://docker-minecraft-server.readthedocs.io/en/latest/misc/examples/)

## Server Icon Management

Configure a server icon by setting `ICON` to a URL or container path. The image is automatically downloaded (if URL), scaled, and converted. Set `OVERRIDE_ICON` to "true" to replace an existing icon.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Datapack Management

Control datapacks with feature flags before initial world creation:

- `INITIAL_ENABLED_PACKS` — comma separated list (e.g., "update_1_20,bundle")
- `INITIAL_DISABLED_PACKS` — comma separated list

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Force Re-install

For corrupted installations, several types support force re-install:

- Forge: `FORGE_FORCE_REINSTALL=true`
- Fabric: `FABRIC_FORCE_REINSTALL=true`
- Pufferfish/Purpur: `FORCE_REDOWNLOAD=true`

**Sources**: [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/), [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/), [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/)

## Dump Server Properties

To see what `server.properties` will be used, set `DUMP_SERVER_PROPERTIES` to "true" and the contents will be output before the server starts.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Cross-References

- [Configuration](configuration.md) — Full configuration reference
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Troubleshooting](troubleshooting.md) — Common problems and solutions
- [Glossary](GLOSSARY.md) — Domain terminology
