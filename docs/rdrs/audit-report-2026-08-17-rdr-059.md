# RDR-059 Audit Report

Date: 2026-08-17
RDR: `docs/rdrs/RDR-059-immutable-agent-runtime-images.md`
Closeout issue: #3419
Conclusion: Implemented

## Shipped behavior

### 1. Production executions resolve mutable requests to immutable digests

- `app/services/containers/runtime_image_catalog.rb:36` resolves configured
  identities, enforces `active` lifecycle state, and returns the final
  `registry/repository@sha256:...` reference.
- `app/services/containers/runtime_image_selector.rb:42` keeps mutable tags in
  non-production environments and switches production to catalog-backed digest
  resolution.
- `app/services/containers/provision.rb:270` and
  `app/services/containers/provision.rb:1298` route the final container image
  selection through the selector before provisioning.

Evidence:

- `spec/services/containers/runtime_image_selector_spec.rb:70`
- `spec/services/containers/provision_spec.rb:303`

### 2. Each run records requested image plus immutable provenance

- `app/models/agent_run.rb:2324` persists runtime image metadata under
  `external_metadata["runtime_image"]`.
- `app/services/containers/runtime_image_selector.rb:15` emits the metadata
  shape with requested image, resolved image, digest, architecture, registry,
  repository, provenance reference, and immutability flag.
- `app/services/containers/provision.rb:1306` records that metadata on the run
  as part of option resolution.
- Warm-pool claims attribute the digest the warmed container actually runs:
  `app/services/containers/pool_manager.rb` persists the warm-time selection on
  the `ContainerPoolEntry` (`runtime_image_metadata`) at warm time and copies it
  onto the claiming run in `#acquire`; `Containers::Provision` reuses the
  persisted selection when reconnecting to a claimed entry instead of
  re-resolving against the catalog's current default, which may have moved
  between warm and claim.

Evidence:

- `spec/models/agent_run_runtime_image_spec.rb:7`
- `spec/services/containers/provision_spec.rb:303`
- `spec/services/containers/provision_spec.rb` ("reuses the warm-time selection
  persisted on a claimed pool entry instead of re-resolving")
- `spec/services/containers/pool_manager_spec.rb` ("persists the warm-time
  runtime image selection on the warmed entry", "records the warm-time runtime
  image selection on the claiming run")

### 3. Local Docker development still uses mutable tags

- `app/services/containers/runtime_image_selector.rb:62` returns the requested
  mutable tag unchanged outside production.

Evidence:

- `spec/services/containers/runtime_image_selector_spec.rb:54`

### 4. Blocked and deprecated identities cannot be selected for new production runs

- `app/services/containers/runtime_image_catalog.rb:43` rejects any identity
  whose lifecycle status is not `active`.

Evidence:

- `spec/services/containers/runtime_image_selector_spec.rb:101`
- `spec/services/containers/runtime_image_selector_spec.rb:112`

### 5. Rollback can target a prior active digest without moving `latest`

- `app/services/containers/runtime_image_catalog.rb:39` accepts an explicit
  provenance reference, allowing callers to select a prior active digest while
  leaving the profile's default mutable tag authority unchanged.

Evidence:

- `spec/services/containers/runtime_image_selector_spec.rb:89`

## Validation commands

- `bundle exec rubocop` — passed
- `bin/coherence-check.mjs` — completed; reported pre-existing repo-wide
  reverse-orphan/staleness findings unrelated to RDR-059
- Focused runtime-image specs passed:
  - `spec/services/containers/runtime_image_selector_spec.rb`
  - `spec/models/agent_run_runtime_image_spec.rb`
  - `spec/services/containers/provision_spec.rb:303`
  - `spec/services/containers/image_resolver_spec.rb`
  - `spec/services/containers/pool_manager_spec.rb` (warm-time persistence and
    claim-time attribution)

## Gaps

None in the shipped contract audited for RDR-059.
