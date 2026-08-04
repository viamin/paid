---
parent: PAID
prefix: MULTI-REPO-CHAT
---

# Low-Level Design: Containerized Multi-Repo Chat

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the planned evolution from single-repo or API-only chat into
> capability-based chat sessions that can provision a workspace in the
> background and clone multiple repositories on demand.

## Purpose

RDR-037 turns several chat limitations into explicit future intent:

- first message should not wait for container provisioning
- one chat session should be able to reason across multiple repositories
- workspace capability should upgrade in place rather than forcing a new
  session
- cloned-repo state should survive container teardown and session reopen

The current repo ships chat and single-repo container foundations, but not the
multi-repo capability model itself.

## Existing Foundations

The missing feature can build on already-shipped chat infrastructure:

- interactive chat sessions and tool dispatch
- chat container provisioning for workspace-backed sessions
- repo-read tools and authorization surfaces
- session reopen/container lifecycle work in adjacent chat segments

## Active Gap

The feature remains unimplemented end-to-end. In particular, the system still
needs:

- capability-state tracking (`none`, `pending`, `provisioning`, `ready`,
  `failed`, `stopped`) instead of a fixed workspace decision at create time
- background provisioning that accepts the first message immediately
- clone manifests that persist which repos were added to a session
- container-only mutation tools and PR-proposal flows that understand
  multi-repo authorization and dependency coordination

## What this is not

- **Not a replacement for the existing chat-container-provisioning segment.**
  That segment covers the current single-workspace lifecycle.
- **Not unrestricted cross-account repo access.** Authorization remains
  project-scoped and Pundit-checked per clone and per mutable action.
- **Not a promise of unlimited workspace scale.** Repo-count and disk/resource
  caps remain part of the design contract.
