# RDR-059: Immutable Agent Runtime Images

Date: 2026-08-17
Status: Implemented
Related Issues: #3419, #3406, #3407, #3408, #3354, #3358

## Context

Paid's language-aware runtime selection (`Containers::ImageResolver`) already
chooses the requested agent image tag for a project, but mutable tags such as
`paid-agent:latest` are not a safe production authority. Production executions
need immutable digests, audit metadata on each run, and an explicit way to keep
deprecated or blocked identities out of future runs while still allowing
rollback to an earlier approved digest.

At the same time, local Docker development still benefits from mutable tags
because the developer workflow is iterative and image rebuilds are intentionally
fast.

## Decision

Introduce a second-stage runtime image selection layer:

- `Containers::ImageResolver` remains the requested tag/profile resolver
- `Containers::RuntimeImageSelector` turns that request into the final image
  reference
- `Containers::RuntimeImageCatalog` is the immutable authority for production
  digests and lifecycle state

Production behavior:

- resolve requested tags to `registry/repository@sha256:...`
- reject `deprecated` and `blocked` identities for new runs
- allow rollback to a prior `active` provenance reference
- persist runtime image metadata on the `AgentRun`

Local development/test behavior:

- keep mutable requested tags such as `paid-agent:latest`

## Validation

The closeout implementation is validated by:

- `spec/services/containers/runtime_image_selector_spec.rb`
- `spec/models/agent_run_runtime_image_spec.rb`
- `spec/services/containers/provision_spec.rb`

These cover:

- production digest resolution
- persisted run metadata
- local mutable-tag behavior
- blocked/deprecated selection rejection
- rollback to a prior active digest

## Implementation Status

Implemented as of 2026-08-17.

The shipped implementation resolves production runs through an immutable image
catalog and persists runtime image provenance on each run. The repository keeps
the digest catalog source generic: `config/agent_runtime_images.yml` defines the
catalog contract and deployments can inject concrete digest data with
`PAID_AGENT_RUNTIME_DIGESTS` so production does not depend on checked-in mutable
tags.

## 2026-08-17 Closeout

Closeout issue: #3419

Shipped behavior:

- Production image requests resolve through `Containers::RuntimeImageSelector`
  and `Containers::RuntimeImageCatalog` to immutable digest references.
- `AgentRun#record_runtime_image_selection!` persists runtime image provenance
  in `external_metadata["runtime_image"]`.
- Warm-pool claims carry warm-time provenance: the selection the warmed
  container was provisioned with is persisted on the `ContainerPoolEntry` and
  copied onto the claiming run, so a catalog default that moves between warm
  and claim never misattributes the run's image.
- Development/test continue using mutable tags.
- Catalog lifecycle status blocks `deprecated` and `blocked` identities.
- Rollback is supported by selecting a prior `active` provenance reference.
