---
parent: PAID
prefix: IMMUTABLE-IMAGE
---

# Low-Level Design: Immutable Runtime Images

## Purpose

Production agent executions must not trust mutable Docker tags such as
`paid-agent:latest` as the final authority. Mutable tags are still useful as a
human-facing request shape and for local development, but production needs an
immutable digest plus enough provenance to audit exactly what executed.

## Design

The existing language-aware `Containers::ImageResolver` remains responsible for
choosing the requested image profile/tag from the project's language profile
(`paid-agent:latest`, `paid-agent:go`, `paid-agent:elixir-node-ruby`, and so
on). `Containers::RuntimeImageSelector` then decides how that request becomes a
final image reference:

- development and test keep the mutable requested tag so local Docker workflows
  can continue using `paid-agent:latest`
- production resolves the requested tag through `Containers::RuntimeImageCatalog`
  into an immutable `repository@sha256:...` reference

The catalog supports two configuration sources:

1. `config/agent_runtime_images.yml` for stable defaults
2. `PAID_AGENT_RUNTIME_DIGESTS` for deployment-specific digest material

Each catalog identity stores:

- digest
- architecture
- registry
- repository
- provenance reference
- lifecycle status (`active`, `deprecated`, `blocked`)

## Lifecycle rules

- Only `active` identities are selectable for new production runs.
- A rollback can request a prior `active` provenance reference explicitly.
- `deprecated` and `blocked` identities are rejected for new production runs.
- Missing production digest configuration fails loudly rather than silently
  falling back to a mutable tag.

## Run audit trail

`AgentRun#record_runtime_image_selection!` persists runtime image metadata in
`external_metadata["runtime_image"]` so each run records:

- requested image tag
- resolved image reference
- digest
- architecture
- registry
- repository
- provenance reference
- whether the final reference was immutable

### Warm-pool provenance

Warm-pool containers are provisioned at warm time (`PoolManager#warm_one`,
no agent run attached). The selection the warmed container was actually
provisioned with is persisted on the `ContainerPoolEntry`
(`runtime_image_metadata`). When a run claims the entry, that warm-time
selection is copied onto the run in `PoolManager#acquire`, and
`Containers::Provision` reuses it when reconnecting to the claimed container.
Claims never re-resolve against the catalog's current default — the catalog
default may have moved between warm and claim, and the run's provenance must
describe the container it actually executes in. Entries warmed before this
provenance existed (no persisted selection) keep the lazy re-resolution
fallback.

### Reconnect and re-provision provenance

`Containers::Provision#resolve_runtime_image_selection` resolves a runtime
image selection in three tiers:

1. the warm-time selection persisted on a claimed `ContainerPoolEntry`
2. the selection already recorded on the `AgentRun` itself
3. a fresh catalog resolution

Tier 2 covers non-pool reconnects: a Temporal retry or worker failover that
goes through `LocalDockerRunner#reconnect` reaches `Containers::Provision`
without a `pool_entry`, but the run already carries the digest the running
container was provisioned with. Reusing the recorded selection avoids
overwriting provenance with a catalog default that has moved in the meantime.

When an existing container is reconciled away (dead or missing) and a
replacement container is provisioned from scratch, `AgentRun#reconcile_stale_container!`
clears the recorded selection so the next `#options` resolution records the
current catalog default on the replacement container instead of inheriting
provenance from a container that no longer exists.
