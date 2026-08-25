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

The repo now ships the multi-repo capability model itself (capability state,
background provisioning, clone manifests, and container-only mutation tools),
with cross-repo PR-proposal tooling as the remaining open gap.

## Existing Foundations

The missing feature can build on already-shipped chat infrastructure:

- interactive chat sessions and tool dispatch
- chat container provisioning for workspace-backed sessions
- repo-read tools and authorization surfaces
- session reopen/container lifecycle work in adjacent chat segments

## Current State

The capability model is now **partially implemented**. The capability-state
tracking, background provisioning, clone manifests, container-only mutation
tools, and shell execution all shipped (see the segment's EARS specs and the
RDR-037 audit). The remaining open gap is PR-proposal tooling.

What is in place:

- capability-state tracking (`none`, `pending`, `provisioning`, `ready`,
  `failed`, `stopped`) instead of a fixed workspace decision at create time
- background provisioning that accepts the first message immediately
- clone manifests that persist which repos were added to a session
- container-only mutation tools (`write_repo_file`, `apply_patch`, `git_*`,
  `run_shell`) that recompute multi-repo authorization per project
- a container-only read tool (`grep_workspace`) that searches a cloned repo's
  local checkout instead of falling back to GitHub Code Search

## Remaining Gap

- `propose_pull_request` — the cross-repo PR-proposal tool that pushes branches
  via the resolved GitHub identity and opens `Depends on owner/repo#N` PRs for
  coordinated dependent changes. This is the headline cross-repo coordination
  use case for this segment and the single RDR-037 requirement that did not ship.

## What this is not

- **Not a replacement for the existing chat-container-provisioning segment.**
  That segment covers the current single-workspace lifecycle.
- **Not unrestricted cross-account repo access.** Authorization remains
  project-scoped and Pundit-checked per clone and per mutable action.
- **Not a promise of unlimited workspace scale.** Repo-count and disk/resource
  caps remain part of the design contract.
