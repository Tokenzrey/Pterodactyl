# Documentation Generation Plan: itzg/docker-minecraft-server

> **Type:** Plan · **For:** Documentation Author · **Updated:** 2026-10-23

## Overview

This plan documents the strategy for generating a comprehensive, standalone Markdown documentation set for the [itzg/docker-minecraft-server](https://github.com/itzg/docker-minecraft-server) Docker image. The documentation is built exclusively from two authoritative sources:

- **S1**: GitHub repository — `https://github.com/itzg/docker-minecraft-server.git`
- **S2**: ReadTheDocs site — `https://docker-minecraft-server.readthedocs.io/en/latest/`

> [!IMPORTANT]
> **Source-Bounding Constraint**: 100% of content must be traceable to S1 or S2. No general Docker tutorials, no general Minecraft guides, no tangential topics, no external blog content. Synthesis and restructuring of S1/S2 content is permitted; adding new factual claims not in S1/S2 is prohibited.

## Exploration Strategy

### S1 — GitHub Repository (8 folders explored)

| Folder | Content | Purpose |
|--------|---------|---------|
| `docs/` | Inline documentation source (Sphinx/RST) | ReadTheDocs source files |
| `examples/` | Docker Compose and command examples | Categorized by use case |
| `files/` | Reference configuration files | server.properties, ops.json, whitelist.json templates |
| `scripts/` | Startup and management scripts | Environment variable definitions, TYPE/VERSION logic |
| `build/` | Build configurations (Dockerfile, multi-arch) | Image build process |
| `kustomize/` | Kubernetes manifests | K8s deployment patterns |
| `notes/` | Release notes and changelogs | Known issues, deprecations |
| `tests/` | Test cases | Expected behavior, edge cases |
| Root `README.md` | Project overview, quick start, sponsor info | Introduction content |

### S2 — ReadTheDocs Site (7+ sections explored)

| Section | URL | Content |
|---------|-----|---------|
| Intro | `/en/latest/` | Quick start, Docker Compose, EULA |
| Versions | `/en/latest/versions/minecraft/` | VERSION variable, LATEST/SNAPSHOT/specific |
| Types & Platforms | `/en/latest/types-and-platforms/` | TYPE variable, server types, modpack platforms |
| Server Properties | `/en/latest/configuration/server-properties/` | All server.properties env var mappings |
| Interpolating | `/en/latest/configuration/interpolating/` | Config file variable replacement, patching |
| Mods & Plugins | `/en/latest/mods-and-plugins/` | Modpacks, mods, plugins, attach points |
| Deployment | `/en/latest/misc/deployment/` | Kubernetes, Ansible, CloudFormation |
| Examples | `/en/latest/misc/examples/` | GeyserMC, mc-router, Lazymc, Lazytainer |
| Forge | `/en/latest/types-and-platforms/server-types/forge/` | Forge, NeoForge, Cleanroom |
| Fabric | `/en/latest/types-and-platforms/server-types/fabric/` | Fabric, Fabric API, alternate launcher |
| Paper | `/en/latest/types-and-platforms/server-types/paper/` | Paper, Pufferfish, Purpur, Leaf, Folia |

## Skill Orchestration Plan

| Phase | Skill | Input | Output | Fallback |
|-------|-------|-------|--------|----------|
| 1 — Exploration | `research` | GitHub repo + ReadTheDocs URLs | Research findings with citations | Manual webfetch |
| 2 — Planning | `grill-with-docs` | Research findings | Refined plan, glossary, ADRs | Direct plan authoring |
| 3 — Fragments | `writing-fragments` | Research findings | Raw text fragments tagged with sources | Direct content extraction |
| 4 — Structure | `writing-shape` | Fragments + PLAN.md | Document outlines, heading hierarchy | Manual outlining |
| 5 — Content | `writing-beats` | Shapes + fragments | Complete document content | Direct writing |
| 6 — Agent Docs | `writing-for-agents` | Content (if agent-consumed) | Agent-readable docs | Skip if not needed |
| 7 — Building | `doc-expert` | All content | Formatted final documents | Manual formatting |
| 8 — QA | Verification | All output files | Verification report | Manual review |

## Documentation Structure

| File | Type | For | Content Source |
|------|------|-----|----------------|
| `README.md` | Index | All | Navigation index, role-based paths |
| `PLAN.md` | Plan | Author | This document |
| `GLOSSARY.md` | Reference | All | Domain terminology |
| `introduction.md` | Concept + Tutorial | Beginner | S2 intro + S1 README |
| `versions.md` | Guide + Reference | Operator | S2 versions/minecraft + S1 scripts |
| `server-types.md` | Reference | Operator | S2 types-and-platforms + sub-pages |
| `modpacks.md` | Guide + Reference | Operator | S2 mods-and-plugins + S1 examples |
| `mods-and-plugins.md` | Guide + Reference | Operator | S2 mods-and-plugins + S1 scripts |
| `configuration.md` | Reference | Operator | S2 server-properties + interpolating + S1 files/ |
| `environment-variables.md` | Reference | Operator, Developer | S1 scripts + S2 all sections |
| `deployment.md` | Guide + Reference | Operator | S2 misc/deployment + S1 kustomize/ |
| `examples.md` | Reference | Beginner, Operator | S2 misc/examples + S1 examples/ |
| `operations.md` | Guide | Operator | S1/S2 operational features (conditional) |
| `troubleshooting.md` | Guide | Operator | S1 tests/ + notes/ + S2 (conditional) |
| `security.md` | Concept + Guide | Operator | S1/S2 security topics (conditional) |
| `adr/` | Records | Author | Architecture Decision Records |

## Source-to-Output Mapping

| Source (S1/S2) | Target File(s) |
|----------------|----------------|
| S2 Intro + S1 README | `introduction.md` |
| S2 versions/minecraft | `versions.md` |
| S2 types-and-platforms + forge + fabric + paper | `server-types.md` |
| S2 mods-and-plugins (modpack sections) + S1 examples/ | `modpacks.md` |
| S2 mods-and-plugins (mod/plugin sections) | `mods-and-plugins.md` |
| S2 server-properties + interpolating + S1 files/ | `configuration.md` |
| S1 scripts (all env vars) + S2 all sections | `environment-variables.md` |
| S2 misc/deployment + S1 kustomize/ | `deployment.md` |
| S2 misc/examples + S1 examples/ | `examples.md` |
| S1/S2 operational topics | `operations.md` (conditional) |
| S1 tests/ + notes/ + S2 | `troubleshooting.md` (conditional) |
| S1/S2 security topics | `security.md` (conditional) |

## Quality Gates

1. **Completeness**: Every planned file exists, non-empty, has metadata block, ≥3 H2 sections
2. **Citation**: Every factual claim traceable to S1 or S2
3. **Glossary**: Every domain term defined in GLOSSARY.md
4. **Cross-Reference**: All relative Markdown links resolve to existing files
5. **Source-Bounding**: No content from outside S1 ∪ S2; no general tutorials/guides
6. **File Size**: No file exceeds 2,000 lines

## Risk Analysis

| # | Risk | Mitigation |
|---|------|------------|
| 1 | ReadTheDocs page unavailable (404) | Attempt `/en/stable/` fallback; mark "TBD — source unavailable" |
| 2 | GitHub rate limiting during exploration | Use raw.githubusercontent.com for file content; batch requests |
| 3 | Content gaps — topic not covered in S1/S2 | Omit file with explicit note in README.md (per source-bounding constraint) |
| 4 | File exceeds 2,000 lines | Split into multiple files; update cross-references |
| 5 | S1/S2 contradictions | Prefer S1 source code as authoritative; note discrepancy |
| 6 | Source-bounding violation | QA scan rejects unsourced content; trim or re-source |

## Output File List

```
docs/single-standalone/
├── README.md
├── PLAN.md
├── GLOSSARY.md
├── introduction.md
├── versions.md
├── server-types.md
├── modpacks.md
├── mods-and-plugins.md
├── configuration.md
├── environment-variables.md
├── deployment.md
├── examples.md
├── operations.md          (conditional)
├── troubleshooting.md     (conditional)
├── security.md            (conditional)
└── adr/
    ├── 0001-english-language.md
    ├── 0002-source-bounding-enforcement.md
    ├── 0003-separate-files-per-server-type.md
    ├── 0004-conditional-file-generation.md
    └── 0005-gfm-callout-convention.md
```

## Revision History

| Date | Version | Change |
|------|---------|--------|
| 2026-10-23 | 1.0 | Initial plan created |
