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
