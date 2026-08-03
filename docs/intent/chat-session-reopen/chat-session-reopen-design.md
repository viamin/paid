---
parent: PAID
prefix: CHAT-SESSION-REOPEN
---

# Low-Level Design: Chat Session Reopen

> Companion to the high-level design (`docs/high-level-design.md`) and
> [RDR-037](../../rdrs/RDR-037-containerized-multi-repo-chat.md). This segment
> covers reopening a stopped chat workspace and the live capability indicator
> that keeps the user informed while the workspace is restored.

## Purpose

RDR-037 requires chat sessions to outlive their containers. When the idle
reaper or an explicit close tears down a workspace, the conversation must stay
readable and the user must be able to request a fresh container that restores
the saved clone manifest. The same surface must expose capability state in the
chat header so the user can see whether the workspace is unavailable, warming,
ready, or partially degraded.

## Reopen flow

`ChatSessions::Reopen` is the user entry point for stopped container-backed
sessions. It:

1. Treats active `ready` / `pending` / `provisioning` sessions as a no-op.
2. Rejects inline-only sessions because they have no workspace to recreate.
3. Reactivates the session, clears close-snapshot metadata, marks
   `container_capability: "pending"`, and enqueues
   `ChatSessions::ProvisionContainerJob`.

The provision job reuses the existing background provisioning path, but when the
reopen metadata marker is present it provisions without seeding the legacy
single-project workspace path and instead replays `clone_manifest` through
`ChatSessions::RestoreCloneManifest`.

## Clone-manifest restore

Manifest replay attempts each saved clone path independently:

- successful clones clear any stale markers and keep the manifest entry live
- missing projects, missing tokens, or failed clone commands mark only that
  entry stale
- stale entries stay in the manifest; they are never dropped silently

If any clone fails, the service persists a system message naming the failed
repo(s) so the resumed conversation starts with explicit workspace state.

## Live capability indicator

The chat header renders a capability panel with:

- the current capability label (`none`, `pending`, `provisioning`, `ready`,
  `failed`, `stopped`)
- cloned repos, their workspace paths, and the GitHub identity recorded for
  each clone
- a reopen action for stopped sessions
- a "Clone another project" form for ready sessions

Capability changes and clone-manifest updates broadcast over the existing
`chat_session:<id>` ActionCable stream. The Stimulus chat controller updates the
badge, label, action visibility, and repo list in place without reloading the
conversation.
