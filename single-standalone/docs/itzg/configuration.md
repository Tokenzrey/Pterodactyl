# Configuration

> **Type:** Reference · **For:** Operator · **Updated:** 2026-10-23

## Server Properties

To unify management of the Minecraft server container, all known [`server.properties`](https://minecraft.wiki/w/Server.properties) entries can be managed by environment variables. Some mappings provide additional functionality above and beyond the properties file.

> [!NOTE]
> Not all server properties are supported by all versions of Minecraft. Consult the [server properties documentation](https://minecraft.wiki/w/Server.properties) for your version.

If you prefer to manually manage `server.properties`, set `OVERRIDE_SERVER_PROPERTIES` to "false". To skip creation entirely, set `SKIP_SERVER_PROPERTIES` to "true".

To clear a server property, set the variable to an empty string (e.g., `-e RESOURCE_PACK=""`). An unset variable is ignored and the existing property is left unchanged.

To see what `server.properties` will be used, set `DUMP_SERVER_PROPERTIES` to "true" and the contents will be output before the server starts.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Placeholders

When declaring server properties via environment variables, values may contain placeholders processed when `server.properties` is updated. The syntax is DOS-style `%VAR%` to avoid being processed by Docker or the shell:

| Syntax | Description |
|--------|-------------|
| `%VAR%` or `%env:VAR%` | Replaced with the resolved value of environment variable `VAR` |
| `%date:FMT%` | Formats current date/time with `FMT` using [Java's DateTimeFormatter](https://docs.oracle.com/en/java/javase/11/docs/api/java.base/java/time/format/DateTimeFormatter.html) |

Any declared or resolved environment variable may be referenced (e.g., `VERSION` and `TYPE`). Modrinth and Auto CurseForge modpacks expose `MODPACK_NAME` and `MODPACK_VERSION`. The originally declared version is available in `DECLARED_VERSION`.

```yaml
environment:
  MOTD: Running %MODPACK_NAME% version %env:MODPACK_VERSION%
  LEVEL: world-%date:yyyy-MM-dd%
```

> [!WARNING]
> Placeholders are not supported when manually managing `server.properties`.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Message of the Day (MOTD)

The MOTD, shown below each server entry in the client UI, can be changed with the `MOTD` environment variable. A default is computed from the server type and version (e.g., "A Paper Minecraft Server powered by Docker").

The section symbol (§) and other unicode characters are automatically converted for [formatting codes](https://minecraft.wiki/w/Formatting_codes). For Minecraft versions less than 1.20, unicode characters in `server.properties` are escaped as `\uXXXX` by default. Alter with `SERVER_PROPERTIES_ESCAPE_UNICODE` set to "true" or "false".

```bash
docker run -e MOTD="A §l§cMinecraft§r §nserver" ...
```

Multi-line MOTD using `\n`:

```bash
docker run -e MOTD="Line one\nLine two" ...
```

```yaml
environment:
  MOTD: |
    line one
    line two
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Difficulty

The difficulty level (default: `easy`):

```bash
docker run -d -e DIFFICULTY=hard ...
```

Valid values: `peaceful`, `easy`, `normal`, `hard`.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Whitelist Players

> [!IMPORTANT]
> For public servers, it is very important to consider setting a whitelist of expected players.

To whitelist players:

- Provide usernames and/or UUIDs separated by commas or newlines via `WHITELIST`
- Provide a URL or container path to a whitelist file via `WHITELIST_FILE`

```yaml
environment:
  WHITELIST: |
    user1
    user2
    user3
```

When either is set, whitelisting is enabled. To change behavior when the whitelist file already exists, set `EXISTING_WHITELIST_FILE`:

| Value | Description |
|-------|-------------|
| `SKIP` | Skip processing when file already present |
| `SYNCHRONIZE` | Synchronize users with WHITELIST/WHITELIST_FILE |
| `MERGE` | Merge WHITELIST users into existing file |
| `SYNC_FILE_MERGE_LIST` (default) | WHITELIST_FILE overwrites existing; WHITELIST users merged |

To enforce whitelist changes immediately, set `ENFORCE_WHITELIST` to "true". To enable whitelist when managing the file manually, set `ENABLE_WHITELIST` to "true".

Usernames are resolved using [PlayerDB](https://playerdb.co/) (default) or [Mojang's API](https://wiki.vg/Mojang_API#Username_to_UUID) by setting `USER_API_PROVIDER` to "mojang".

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Op/Administrator Players

Provision operators via:

- `OPS` — list of usernames and/or UUIDs separated by commas or newlines
- `OPS_FILE` — URL or container path to an ops file

```yaml
environment:
  OPS: |
    user1
    user2
    user3
```

Set `EXISTING_OPS_FILE` to `SKIP`, `SYNCHRONIZE`, `MERGE`, or `SYNC_FILE_MERGE_LIST` (default) to control behavior when the ops file already exists.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Server Icon

Configure a server icon by setting `ICON` to a URL or container path. The image is automatically downloaded (if URL), scaled, and converted:

```bash
docker run -d -e ICON=http://..../some/image.png ...
```

Using a file from host filesystem:

```yaml
environment:
  ICON: /icon.png
  OVERRIDE_ICON: true
volumes:
  - ./icon.png:/icon.png
```

By default, an existing `server-icon.png` will not be replaced. Set `OVERRIDE_ICON` to "true" to override.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## RCON

RCON is **enabled by default** to allow graceful shutdown and backup coordination. Disable by setting `ENABLE_RCON` to "false".

> [!WARNING]
> Disabling RCON will remove and limit some features, such as interactive and color console support.

### RCON Password

The default password is randomly generated on each startup. Specify a password using:

- `RCON_PASSWORD` — your desired password
- `RCON_PASSWORD_FILE` — path to a file containing the password (recommended for [Docker Secrets](https://docs.docker.com/compose/how-tos/use-secrets/))

```yaml
services:
  mc:
    image: itzg/minecraft-server:latest
    environment:
      EULA: "TRUE"
      RCON_PASSWORD_FILE: /run/secrets/rcon_pass
    volumes:
      - ./data:/data
    secrets:
      - rcon_pass

secrets:
  rcon_pass:
    file: ./rcon_password
```

> [!WARNING]
> **BE CAUTIOUS OF MAPPING THE RCON PORT EXTERNALLY** unless you are aware of all consequences and have set a **secure password**.

By default, the server listens for RCON on port 25575 within the container. Change with `RCON_PORT` (only if necessary). **DO NOT change `rcon.port` via `server.properties`** or integrations will break.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Query

Set `ENABLE_QUERY` to "true" to enable the gamespy query protocol. Default query port is `25565` (UDP), changeable with `QUERY_PORT`.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Level Seed

Set `SEED` to create the world with a specific seed:

```bash
docker run -e SEED="-1785852800490497919" ...
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Game Mode

Change the mode using `MODE`:

| Value | Description |
|-------|-------------|
| `creative` | Creative mode |
| `survival` | Survival mode (default) |
| `adventure` | Adventure mode |
| `spectator` | Spectator mode (Minecraft 1.8+) |

```bash
docker run -d -e MODE=creative ...
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Level Type and Generator Settings

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

## Custom Server Resource Pack

Set a link and checksum:

```bash
docker run -d -e 'RESOURCE_PACK=http://link.com/to/pack.zip?=1' -e 'RESOURCE_PACK_SHA1=d5db29cd03a2ed055086cef9c31c252b4587d6d0' ...
```

Enforce on clients with `RESOURCE_PACK_ENFORCE` set to `TRUE` (default: `FALSE`).

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Level / World Save Name

Switch between world saves using `LEVEL` (default: "world"):

```bash
docker run -d -e LEVEL=bonus ...
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Server Port

> [!WARNING]
> Only change this if you know what you're doing. It only needs to be changed when using host-networking. Use `-p` port mappings instead.

```bash
docker run -d -e SERVER_PORT=25566 ...
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Custom Server Properties

Some mods/plugins utilize custom `server.properties` entries via `CUSTOM_SERVER_PROPERTIES`:

```yaml
environment:
  CUSTOM_SERVER_PROPERTIES: |
    custom1=value1
    defaultworldgenerator-port=f8c04631-f744-11ec-b260-f02f74b094e0
```

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Datapacks

Control datapacks with feature flags before initial world creation:

- `INITIAL_ENABLED_PACKS` — comma separated list (e.g., "update_1_20,bundle")
- `INITIAL_DISABLED_PACKS` — comma separated list

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Other Server Property Mappings

| Environment Variable | Server Property |
|----------------------|-----------------|
| `ACCEPTS_TRANSFERS` | accepts-transfers |
| `ALLOW_FLIGHT` | allow-flight |
| `ALLOW_NETHER` | allow-nether |
| `ANNOUNCE_PLAYER_ACHIEVEMENTS` | announce-player-achievements |
| `BROADCAST_CONSOLE_TO_OPS` | broadcast-console-to-ops |
| `BROADCAST_RCON_TO_OPS` | broadcast-rcon-to-ops |
| `BUG_REPORT_LINK` | bug-report-link |
| `ENABLE_COMMAND_BLOCK` | enable-command-block |
| `ENABLE_STATUS` | enable-status |
| `ENFORCE_SECURE_PROFILE` | enforce-secure-profile |
| `ENTITY_BROADCAST_RANGE_PERCENTAGE` | entity-broadcast-range-percentage |
| `FORCE_GAMEMODE` | force-gamemode |
| `FUNCTION_PERMISSION_LEVEL` | function-permission-level |
| `GENERATE_STRUCTURES` | generate-structures |
| `GENERATOR_SETTINGS` | generator-settings |
| `HARDCORE` | hardcore |
| `HIDE_ONLINE_PLAYERS` | hide-online-players |
| `LOG_IPS` | log-ips |
| `MAX_BUILD_HEIGHT` | max-build-height |
| `MAX_COMMAND_CHAIN_LENGTH` | max-command-chain-length |
| `MAX_ENTITY_CRAMMING` | max-entity-cramming |
| `MAX_ENTITY_COLLISION_RADIUS` | max-entity-collision-radius |
| `MAX_FUNCTION_CHAIN_DEPTH` | max-function-chain-depth |
| `MAX_NEIGHBORS` | max-neighbors |
| `MAX_CHAINED_NEIGHBOR_UPDATES` | max-chained-neighbor-updates |
| `MAX_PLAYERS` | max-players |
| `MAX_TICK_TIME` | max-tick-time |
| `MAX_WORLD_SIZE` | max-world-size |
| `NETWORK_COMPRESSION_THRESHOLD` | network-compression-threshold |
| `ONLINE_MODE` | online-mode |
| `OP_PERMISSION_LEVEL` | op-permission-level |
| `PAUSE_WHEN_EMPTY_SECONDS` | pause-when-empty-seconds |
| `PLAYER_IDLE_TIMEOUT` | player-idle-timeout |
| `PREVENT_PROXY_CONNECTIONS` | prevent-proxy-connections |
| `PVP` | pvp |
| `RATE_LIMIT` | rate-limit |
| `REGION_FILE_COMPRESSION` | region-file-compression |
| `RESOURCE_PACK_ID` | resource-pack-id |
| `RESOURCE_PACK_PROMPT` | resource-pack-prompt |
| `SERVER_NAME` | server-name |
| `SIMULATION_DISTANCE` | simulation-distance |
| `SPAWN_ANIMALS` | spawn-animals |
| `SPAWN_MONSTERS` | spawn-monsters |
| `SPAWN_NPCS` | spawn-npcs |
| `SPAWN_PROTECTION` | spawn-protection |
| `STATUS_HEARTBEAT_INTERVAL` | status-heartbeat-interval |
| `SYNC_CHUNK_WRITES` | sync-chunk-writes |
| `USE_NATIVE_TRANSPORT` | use-native-transport |
| `VIEW_DISTANCE` | view-distance |

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Cross-References

- [Environment Variables](environment-variables.md) — Complete variable reference
- [Mods and Plugins](mods-and-plugins.md) — Config file variable replacement and patching
- [Glossary](GLOSSARY.md) — Domain terminology
