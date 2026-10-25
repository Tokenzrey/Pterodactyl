# ADR-0003: Separate Files per Server Type

> **Status:** Accepted · **Date:** 2026-10-23

## Context

The itzg/docker-minecraft-server image supports many server types (VANILLA, FORGE, FABRIC, PAPER, etc.) and modpack platforms. A single file would be too large and hard to navigate.

## Decision

Use a single `server-types.md` file with H2 sections per server type, cross-referenced to `environment-variables.md` for type-specific variables. Use separate files for modpacks (`modpacks.md`) and individual mods/plugins (`mods-and-plugins.md`).

## Consequences

- Each topic is in a focused, navigable file
- Cross-references connect related content
- File sizes stay within the 2,000-line limit

## Alternatives Considered

- **One file per type**: Would create too many small files (15+)
- **Single comprehensive file**: Would exceed size limits and be hard to navigate
