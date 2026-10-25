# Troubleshooting

> **Type:** Guide · **For:** Operator · **Updated:** 2026-10-23

## EULA Not Accepted

**Symptom**: Server does not start; logs show EULA acceptance required.

**Cause**: The `EULA` environment variable is not set to "TRUE".

**Solution**: Always include `-e EULA=TRUE` in your commands and container definitions.

```bash
docker run -d -e EULA=TRUE -p 25565:25565 itzg/minecraft-server
```

**Source**: [S2 Intro](https://docker-minecraft-server.readthedocs.io/en/latest/)

## Forge Installation Error

**Symptom**: Error occurred while installing Forge.

**Cause**: Forge installation may fail due to corrupted or incomplete downloads.

**Solution**: Temporarily set `FORGE_FORCE_REINSTALL` to "true" to force reinstallation. Remove the variable after successfully starting the server.

```bash
docker run -e TYPE=FORGE -e FORGE_FORCE_REINSTALL=true ...
```

**Source**: [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/)

## Fabric Launcher Corrupted

**Symptom**: Fabric launcher jar is corrupted or missing.

**Cause**: Corrupted download or incomplete installation.

**Solution**: Temporarily set `FABRIC_FORCE_REINSTALL` to "true" to re-install on next startup.

```bash
docker run -e TYPE=FABRIC -e FABRIC_FORCE_REINSTALL=true ...
```

**Source**: [S2 fabric](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/fabric/)

## Paper Build Not Found

**Symptom**: `No build found for version 1.21 with channel 'default'`

**Cause**: The requested version may only have experimental builds available.

**Solution**: Set `PAPER_CHANNEL` to "experimental".

```bash
docker run -e TYPE=PAPER -e PAPER_CHANNEL=experimental ...
```

**Source**: [S2 paper](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/paper/)

## RCON Features Not Working

**Symptom**: Interactive console, color console, or graceful shutdown not working.

**Cause**: RCON has been disabled by setting `ENABLE_RCON` to "false".

**Solution**: Re-enable RCON by removing `ENABLE_RCON=false` or setting it to "true". RCON is enabled by default.

> [!WARNING]
> Do not change `rcon.port` via `server.properties` or integrations will break. Use `RCON_PORT` environment variable instead.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Invalid Difficulty Value

**Symptom**: Error message in logs about invalid difficulty.

**Cause**: The `DIFFICULTY` environment variable is set to an invalid value.

**Solution**: Use one of the valid values: `peaceful`, `easy`, `normal`, or `hard`.

**Source**: [S2 configuration/server-properties](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)

## Cleanroom Version Mismatch

**Symptom**: Cleanroom fails to work with the selected Minecraft version.

**Cause**: Cleanroom **only works with Minecraft 1.12.2**.

**Solution**: Set `VERSION` to "1.12.2" when using Cleanroom with Forge or NeoForge types.

```yaml
environment:
  TYPE: FORGE
  VERSION: "1.12.2"
  APPLY_CLEANROOM: true
```

**Source**: [S2 forge](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/server-types/forge/)

## Old Server Jar Files Accumulating

**Symptom**: Multiple server jar versions in `/data` directory.

**Cause**: When upgrading versions, older jar files are not automatically removed.

**Solution**: It is safe to manually remove old jar files from the `/data` directory.

**Source**: [S2 versions/minecraft](https://docker-minecraft-server.readthedocs.io/en/latest/versions/minecraft/)

## Zip Modpack Not Installing

**Symptom**: Mods from a zip modpack are not being installed.

**Cause**: The zip file may not have jar files at the top level, or the jars may not be compatible with the server `TYPE`.

**Solution**: Ensure the zip file has one or more jar files at the top level of the archive and that the jars are compatible with the `TYPE` of server you are running.

**Source**: [S2 mods-and-plugins](https://docker-minecraft-server.readthedocs.io/en/latest/mods-and-plugins/)

## Cross-References

- [Configuration](configuration.md) — Full configuration reference
- [Operations](operations.md) — Server operational features
- [Environment Variables](environment-variables.md) — Complete variable reference
- [Glossary](GLOSSARY.md) — Domain terminology
