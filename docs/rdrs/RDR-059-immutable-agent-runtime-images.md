# RDR-059: Immutable Agent Runtime Images

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-17
- **Status**: Implemented
- **Type**: Architecture + Data
- **Priority**: P1
- **Related Issues**: #3406 (this issue), #3336 (RD-057 prerequisite), RDR-059 follow-ups TBD
- **Related RDRs**:
  - [RDR-004](RDR-004-container-isolation.md) (Container Isolation)
  - [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution)
  - [RDR-046](RDR-046-polyglot-language-detection-and-test-execution.md) (Polyglot Language Detection and Test Execution)
  - [RDR-048](RDR-048-multi-host-docker-backend-support.md) (Multi-Host Docker Backend Support)
  - [RDR-057](RDR-057-remote-execution-data-contract.md) (Remote Execution Data Contract)

## Implementation Status

RDR-059 is implemented as of 2026-08-17. The `AgentImage` model and
`agent_images` table are the system of record for what image actually runs in
production. Local development and single-backend deployments continue to use
the literal `paid-agent:latest` reference from `Containers::ImageResolver`;
the registry composes with the resolver rather than replacing it. The shipped
implementation:

- persists immutable `(account_id, registry, repository, digest, architecture)`
  identities with multi-arch awareness;
- supports a `status` state machine (`active` / `deprecated` / `blocked`) with
  idempotent transitions;
- retains all historical records for audit and rollback;
- keeps the existing `paid-agent:latest` workflow intact.

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Image records represent immutable digest identities by architecture | Implemented | `app/models/agent_image.rb`; `db/migrate/20260817195654_create_agent_images.rb` |
| Blocked/deprecated images can be excluded from future scheduling | Implemented | `AgentImage#schedulable?`, `AgentImage.schedulable` scope |
| Historical records are retained for audit and rollback | Implemented | No `dependent: :destroy`; `AgentImage.historical` scope |
| Tests cover validation, activation, and blocked-image behavior | Implemented | `spec/models/agent_image_spec.rb` |

## Problem Statement

Today the agent runtime is identified by tag: `Containers::ImageResolver` maps
a project's detected language set to a tag like `paid-agent:latest` or
`paid-agent:elixir-node-python-ruby`, and `Containers::Provision` runs that
literal reference. There is no system of record for which content-addressed
image the production host actually pulled, when it was built, where it came
from, or whether it has been retired.

This leaves three concrete gaps:

1. **No production identity.** When a run fails because the image is bad, the
   control plane can only point at `paid-agent:latest` — a mutable tag that
   may already mean something different. There is no row that says
   "this run used `paid-agent@sha256:7e1c…` built at 2026-08-12 by workflow
   run 12_345."
2. **No blocking surface.** When a CVE is discovered in a base image, the
   only way to stop new runs from using it today is to update the resolver
   constant and roll the app. There is no operator-visible "blocked" state
   that survives restarts and is auditable after the fact.
3. **No deprecation trail.** When an image is superseded, there is no record
   that the old one existed or why it was retired. Rolling back means
   remembering what the previous tag referred to.

These gaps block the next round of multi-host rollout work, which needs to
attest that every remote host is running the same image the control plane
intended, and to roll back to a previous image when a new one is
regressing.

## Context

### Current Image Resolution

`Containers::ImageResolver` decides the image tag for a run based on the
project's detected language profile. It returns the literal string
`paid-agent:latest` (or a combo tag) and `Containers::Provision` consumes
that string verbatim when starting the container. The resolver is the
source of truth for "what tag should be used for this project right now."
It is not a system of record for "what image ran at 14:32 yesterday."

### Current Backend Tag Model

`DockerHost#image_tag` stores the expected agent image tag for readiness
checks and setup guidance (default `paid-agent:latest`). This is a
single-host convenience for the legacy single-backend mode; it is not a
production identity and it is not multi-host aware.

### The Multi-Host Pressure

RDR-048 made Docker placement multi-host. RDR-057 defined the
provider-neutral contract that crosses the control-plane/runner boundary.
The remaining gap is: how does the control plane know which content-addressed
image each host actually ran, and how does it decide which image is
acceptable for the next run?

## Recommendation

Introduce an `AgentImage` model that records the immutable production
identity of each agent container image the system has run. The registry
is the system of record for the *what*, not the *when* (the resolver keeps
its job) and not the *where* (the host keeps its job).

Core decisions:

> **Identity is content-addressed.** A row is uniquely identified by
> `(account_id, registry, repository, digest, architecture)`. The same
> digest on a different architecture is a separate row; the same identity
> may be recorded independently by different accounts.
>
> **Identity is immutable after creation.** A new build produces a new
> digest, which is a new row. There is no in-place edit. This is the only
> way to keep history accurate — editing an existing row would silently
> rewrite what the registry claims was running on a prior run.
>
> **Status is the only mutating lifecycle surface.** `active` is
> schedulable; `deprecated` is still runnable but superseded; `blocked`
> is excluded from new placements. Transitions are idempotent. Records
> are never deleted.
>
> **Local development and single-backend deployments are unchanged.**
> The literal `paid-agent:latest` reference still flows through
> `Containers::ImageResolver`; the registry composes with the resolver
> rather than replacing it. The two layers will eventually be wired
> together (a `resolve!` check that the resolver's output is backed by an
> active registry row), but that wiring is out of scope for this RDR.

## Proposed Design

### Data Model

```text
AgentImage
  account_id    bigint   not null   # per-account scope, like docker_hosts
  name          string   not null   # logical profile (base, elixir-node, …)
  tag           string   not null   # upstream tag at the time the image was recorded
  registry      string   not null   # docker.io (default), ghcr.io, registry.example.test
  repository    string   not null   # paid-agent, paid-agent-extra, organization/paid-agent
  digest        string   not null   # sha256:<64-hex> or 64-hex
  architecture  string   not null   # amd64 (default), arm64, …
  built_at      datetime not null   # wall-clock from the build pipeline
  status        string   not null   # active (default), deprecated, blocked
  deprecated_at datetime            # stamp on active -> deprecated transition
  deprecation_reason text            # free-text reason captured at deprecation
  blocked_at    datetime            # stamp on active/deprecated -> blocked transition
  blocked_reason text               # free-text reason captured at blocking (CVE id, …)
  provenance    jsonb    not null   # build provenance (git SHA, workflow run id, …)
  metadata      jsonb    not null   # operations metadata (build log URL, runbook)
  created_at    datetime not null
  updated_at    datetime not null
```

Indexes:

- `idx_agent_images_identity` — unique on
  `(account_id, registry, repository, digest, architecture)`. The
  content-addressed identity must be unique within an account.
- `idx_agent_images_profile_arch` — non-unique on
  `(account_id, name, architecture)`. Supports the (profile, architecture)
  scheduling decision without going through the full content-addressed
  tuple.
- `idx_agent_images_inactive` — partial on `status` where
  `status <> 'active'`. Keeps audit and rollback queries fast as the
  active set grows.

### State Machine

```text
   +---------+   deprecate!   +------------+    block!    +---------+
   | active  | ─────────────▶ | deprecated | ───────────▶ | blocked |
   +---------+                +------------+              +---------+
        │                          ▲
        │         block!           │
        └──────────────────────────┘
```

- `deprecate!(reason:)` — stamps `deprecated_at` and stores the reason.
  Idempotent: re-applying on a deprecated image does not re-stamp the
  timestamp or replace the reason. Raises if the image is already blocked
  (a blocked image is already excluded from scheduling; deprecating it
  would obscure the stronger signal).
- `block!(reason:)` — stamps `blocked_at` and stores the reason. Idempotent
  on already-blocked images. An active or deprecated image can be
  blocked. A non-empty reason is required.
- `schedulable?` — single gate for new placements. Today this is the
  same as `active?`, but exposing the predicate means future states
  (e.g. `quarantined`) do not have to be repeated at every call site.

### Composition With Existing Code

The registry does not replace any existing code. `Containers::ImageResolver`
keeps deciding the logical profile; `Containers::Provision` keeps
consuming the literal tag it returns; `DockerHost#image_tag` keeps being
the single-host readiness check input. The new layer is a parallel system
of record that future changes can build on without forcing an immediate
cascading edit through every caller.

A future change (out of scope here) will add an `ImageResolver#resolve!`
that crosses the resolver output with the active registry rows and fails
loudly when the resolver asks for an image the registry has never seen
or has already blocked.

## Acceptance Criteria

The implementation is complete when:

- [x] An `AgentImage` record can represent a production image by
      `(account_id, registry, repository, digest, architecture)`.
- [x] Identity fields are immutable after creation; a new build produces
      a new row.
- [x] Status transitions are idempotent and cover
      `active -> deprecated -> blocked` and `active -> blocked`.
- [x] Blocked and deprecated images are excluded from `AgentImage.schedulable`.
- [x] All historical records are retained for audit and rollback (no
      `dependent: :destroy`, no archive/cleanup job).
- [x] `Containers::ImageResolver::BASE_IMAGE` (`paid-agent:latest`)
      continues to flow unchanged through local development.
- [x] Tests cover validation, activation, and blocked-image behavior.
- [x] EARS specs `CONTAINER-RUNTIME-019` through `CONTAINER-RUNTIME-022`
      are added to `docs/intent/container-runtime/container-runtime-specs.md`
      with `@spec` annotations on the implementation and tests.

## Dependencies

- **#3336** — RDR-057 prerequisite. Ships the provider-neutral
  `ExecutionRunners` value objects that this registry composes with.
- Future work (out of scope here): wire the resolver to the registry
  via `ImageResolver#resolve!`; add a `BlockedImageDetector` that
  watches upstream registry webhooks; add an Avo resource for operator
  management of the registry.

## References

- `app/models/agent_image.rb`
- `db/migrate/20260817195654_create_agent_images.rb`
- `spec/models/agent_image_spec.rb`
- `spec/factories/agent_images.rb`
- `docs/intent/container-runtime/container-runtime-design.md`
- `docs/intent/container-runtime/container-runtime-specs.md`
  (CONTAINER-RUNTIME-019..-022)
- `app/services/containers/image_resolver.rb`
- `app/services/containers/provision.rb`
- `app/models/docker_host.rb`
