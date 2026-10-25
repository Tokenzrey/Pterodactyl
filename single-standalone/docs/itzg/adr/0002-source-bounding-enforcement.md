# ADR-0002: Source-Bounding Enforcement Strategy

> **Status:** Accepted · **Date:** 2026-10-23

## Context

The user requested documentation that is strictly bounded to content from the two authoritative sources (GitHub repo and ReadTheDocs). No deviation to unrelated topics is permitted.

## Decision

Enforce a strict source-bounding constraint: 100% of content must be traceable to S1 (GitHub) or S2 (ReadTheDocs). Files with no source material are omitted entirely with an explicit note. No general Docker tutorials, Minecraft guides, or external content is used to fill gaps.

## Consequences

- All content is verifiable against authoritative sources
- No speculative or unsourced content
- Some files may be omitted if topics aren't covered in S1/S2
- Documentation stays focused on the itzg/docker-minecraft-server image specifically

## Alternatives Considered

- **Augmented documentation**: Supplement with general Docker/Minecraft knowledge — rejected per user's explicit request
- **Selective augmentation**: Add external content only for gaps — rejected as it violates the source-bounding principle
