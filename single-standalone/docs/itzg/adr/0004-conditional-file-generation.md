# ADR-0004: Conditional File Generation

> **Status:** Accepted · **Date:** 2026-10-23

## Context

Some planned documentation files (operations.md, troubleshooting.md, security.md) may not have sufficient source material in S1/S2 to justify a full file.

## Decision

Generate these files conditionally — only if S1/S2 contain enough content on the topic. If generated, include only content sourced from S1/S2. If not generated, add an explicit omission note in README.md.

## Consequences

- All three files were generated as S1/S2 contained relevant content
- Each file contains only source-bounded content
- No files are filled with external or general-purpose content

## Alternatives Considered

- **Always generate with placeholders**: Would leave incomplete files
- **Always generate with external content**: Violates source-bounding constraint
