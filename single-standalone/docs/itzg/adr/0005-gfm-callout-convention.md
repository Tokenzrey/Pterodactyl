# ADR-0005: GFM Callout Convention

> **Status:** Accepted · **Date:** 2026-10-23

## Context

The documentation needs consistent advisory content formatting that works across standard Markdown renderers.

## Decision

Use GitHub-Flavored Markdown (GFM) callouts consistently:
- `> [!NOTE]` for informational notes
- `> [!IMPORTANT]` for critical information
- `> [!WARNING]` for warnings about potential problems
- `> [!TIP]` for helpful tips
- `> [!INFO]` for general information

## Consequences

- Consistent visual distinction for advisory content
- Works in GitHub, VS Code, Obsidian, and other GFM renderers
- No renderer-specific extensions beyond GFM

## Alternatives Considered

- **Custom HTML callouts**: Would not render in all Markdown viewers
- **Plain text prefixes**: Less visually distinct
