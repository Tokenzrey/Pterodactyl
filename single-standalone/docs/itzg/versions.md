# Minecraft Version Selection and Management

> **Type:** Guide + Reference · **For:** Operator · **Updated:** 2026-10-23

## The VERSION Environment Variable

To use a different Minecraft version, pass the `VERSION` environment variable (case sensitive). The following values are accepted:

| Value | Description |
|-------|-------------|
| `LATEST` | Latest release (the default) |
| `SNAPSHOT` | Latest snapshot |
| Specific legacy version | e.g., `1.7.9`, `25w35a`, `1.15.2-pre2`, `1.21.11-rc1` |
| New version numbering | e.g., `26.1`, `26.1-snapshot-1`, `26.1-pre-1`, `26.1-rc-1` (see [new version numbering system](https://www.minecraft.net/en-us/article/minecraft-new-version-numbering-system)) |
| Alpha/beta version | e.g., `b1.7.3` (server download might not exist) |

**Source**: [S2 versions/minecraft](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/)

## Examples

### Using the latest snapshot

```bash
docker run -d -e VERSION=SNAPSHOT ...
```

### Using a specific version

```bash
docker run -d -e VERSION=1.7.9 ...
```

### In a Docker Compose file

```yaml
services:
  mc:
    image: itzg/minecraft-server:latest
    environment:
      EULA: "TRUE"
      VERSION: "1.20.4"
    ports:
      - "25565:25565"
    volumes:
      - ./data:/data
```

**Source**: [S2 versions/minecraft](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/)

## Version Upgrades

When using `LATEST` or `SNAPSHOT`, an upgrade can be performed by simply restarting the container. During the next startup, if a newer version is available from the respective release channel, the new server jar file is downloaded and used.

> [!NOTE]
> Over time you might see older versions of the server jar remain in the `/data` directory. It is safe to remove those.

**Source**: [S2 versions/minecraft](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/)

## VERSION and Server Types

For all server types, the `VERSION` environment variable is used to declare the Minecraft version itself, such as `1.19.4`. Each server type has specific variables for qualifying their version in addition to the Minecraft version. See [server-types.md](server-types.md) for type-specific version variables.

> [!IMPORTANT]
> The `VERSION` variable is used by all server types. Setting `VERSION` alone selects the Minecraft version; the server type's own version (e.g., Forge version, Fabric loader version) is controlled by type-specific variables.

**Source**: [S2 types-and-platforms](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/)

## Cross-References

- [Server Types](server-types.md) — TYPE variable and type-specific version variables
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Glossary](GLOSSARY.md) — Domain terminology
