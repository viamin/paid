# RDR-059: Immutable Agent Runtime Images

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-12
- **Status**: Draft
- **Type**: Architecture + Operations
- **Priority**: P1
- **Related RDRs**: [RDR-007](RDR-007-agent-cli-abstraction.md), [RDR-038](RDR-038-free-models-catalog-and-runner.md), [RDR-040](RDR-040-runner-model-compatibility-contracts.md), [RDR-046](RDR-046-polyglot-language-detection-and-test-execution.md), [RDR-048](RDR-048-multi-host-docker-backend-support.md), [RDR-057](RDR-057-remote-execution-data-contract.md) (image identity in RunSpec and execution manifest), [RDR-061](RDR-061-infrastructure-safety-and-audit.md) (image digest in audit events)
- **Related Issues**: #3336, #3354, #3358

## Problem Statement

Production executions must be reproducible months later. Today the default image identity is usually `paid-agent:latest`, and language-specific images resolve to mutable tags such as `paid-agent:elixir-node-python-ruby`. That is fine for local development, but not authoritative enough for production cloud execution or security audit.

## Context

### Current Implementation

- `Containers::ImageResolver::BASE_IMAGE` is `paid-agent:latest`.
- `Containers::Provision::DEFAULTS[:image]` uses that base image unless project languages resolve to a combo tag.
- `scripts/build-agent-image.sh` builds `IMAGE_NAME:IMAGE_TAG`, defaulting to `paid-agent:latest`, and extracts pinned runner install contracts from `agent-harness`.
- `docker/agent/Dockerfile` pins major runtime versions and verifies several upstream checksums.
- `.github/workflows/agent-image.yml` builds and smoke-tests `paid-agent:latest`.
- `ContainerPoolEntry#image` stores an image tag, but `AgentRun` does not record an immutable image digest as the execution identity.

### Forces and Constraints

- Preserve `paid-agent:latest` for local Docker development.
- Production runs need immutable image identity, including architecture.
- Paid and agent image versions are related but not identical: a control-plane deploy may use a previously built agent image during rollback.
- Runners may cache images, but cache hits must still refer to a digest.
- Avoid provider-specific registry assumptions.

## Research Findings

- The current image workflow already distinguishes local development defaults from production concerns, but it does not record an authoritative runtime identity for an executed run.
- Mutable tags are convenient operator labels, yet they are insufficient evidence for security investigation or reproducibility.
- Multi-architecture support makes digest-only recording incomplete unless platform identity is recorded alongside the digest.
- The existing CI image pipeline provides a natural place to publish and validate immutable image identities before runner activation.

## Proposed Solution

Production agent executions must resolve an image tag/profile to an immutable image digest before provisioning. Paid records both:

- **Requested image reference**: human-facing tag/profile requested by config (`paid-agent:standard`, `paid-agent:elixir-node-python-ruby`, etc.).
- **Resolved image identity**: registry, repository, digest, architecture, and optional provenance metadata used for the actual run.

Mutable tags may remain defaults for development, but a production runner must not treat `latest` as the authoritative execution identity.

### Recommended Direction

1. Introduce an `AgentImage` or equivalent registry record with:
   - logical name/profile;
   - tag;
   - digest;
   - architecture;
   - registry/repository;
   - built from Paid commit SHA and `Gemfile.lock`/`agent-harness` identity;
   - build timestamp and CI provenance URL when available;
   - status (`active`, `deprecated`, `blocked`).
2. `Containers::ImageResolver` resolves a project to a logical profile; production runner selection resolves that profile to an active digest for the target architecture.
3. `RunSpec` carries the resolved immutable image identity.
4. `AgentRun` records the resolved image identity and architecture for every attempt.
5. Rollback means selecting a previous active digest, not moving `latest`.
6. Runner/provider image caches are optimization only; cache contents must be validated against the requested digest.

## Alternatives Considered

### Continue using mutable tags

- **Pros**: Simple and matches local development.
- **Cons**: Cannot prove which runtime executed a run after tag movement.
- **Decision**: Reject for production authoritative identity.

### Pin only semantic tags

Use `paid-agent:v1.2.3`.

- **Pros**: Human readable; rollback-friendly.
- **Cons**: Registry tags are still mutable unless policy enforces immutability.
- **Decision**: Use as a label, not the authority.

### Pin image digests

Use `registry.example.com/paid-agent@sha256:...`.

- **Pros**: Exact runtime identity.
- **Cons**: Less readable; multi-arch manifests require recording platform too.
- **Decision**: Adopt.

### Build image per run

- **Pros**: Maximum source coupling.
- **Cons**: Slow, costly, harder to audit supply chain.
- **Decision**: Reject.

## Security Implications

- Digest pinning reduces supply-chain ambiguity and supports incident response.
- Blocked image identities can prevent scheduling after a vulnerable image is discovered.
- Provenance metadata should be audit data, not a substitute for digest identity.

## Operational Implications

- Production deploys need a registry reachable by all configured runners.
- Multi-arch support requires separate identities or a manifest-list digest plus recorded platform.
- CI should publish immutable digests and smoke-test them before activation.

## Migration and Compatibility

- Local Docker keeps `paid-agent:latest`.
- Existing language tag behavior can continue as a logical resolver layer.
- Backfill historical runs with tag-only identity where digest was not recorded; mark as non-reproducible rather than guessing.
- First cloud runner can start with one architecture if the lack of another architecture is declared as a capability limitation.

## Trade-offs and Consequences

- Operators must manage image activation, but the model avoids accidental tag drift.
- A digest-first model makes provider comparisons fairer: benchmark results can point to the same runtime bits.
- Image cleanup needs a retention policy so rollback digests are not deleted too early.

## Implementation Plan

1. Add an image registry record or equivalent configuration source that maps logical profiles to active immutable image digests per architecture.
2. Resolve production `RunSpec` image references to a digest before provisioning and persist that resolved identity on `AgentRun`.
3. Update CI/publish flows so built images emit digest, platform, and provenance metadata before they can be marked active.
4. Keep mutable tags such as `paid-agent:latest` as local-development defaults only, not authoritative production identities.
5. Define retention and blocking workflows so rollback digests remain available and vulnerable digests can be prevented from scheduling.

## Validation

- Verify every production-bound run records both the requested image profile and the resolved digest plus architecture.
- Verify runner provisioning fails closed when a production profile cannot resolve to an active digest.
- Verify rollback selects a prior active digest without moving a mutable tag.
- Verify CI smoke tests and provenance data attach to the same digest later used by runners.

## Open Questions

- Should the control-plane app boot fail in production if no active agent image digest is configured?
- How long should production image digests remain retained for audit?
- Should language-combo images be separate image records or variants under one logical image family?

## Relationship to Existing Work

RDR-046 decides which language profile a run needs. This RDR decides how that profile becomes an immutable production runtime identity. The runner extraction effort (#3336) should carry that identity in `RunSpec`; RDR-057 records it in the execution result/manifest.
