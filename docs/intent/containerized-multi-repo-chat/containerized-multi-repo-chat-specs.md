# EARS Specs: Containerized Multi-Repo Chat

> Testable claims for the planned multi-repo chat capability model. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r MULTI-REPO-CHAT-001`).

- [ ] **MULTI-REPO-CHAT-001** — When a chat session is created with background
  workspace support enabled, the system SHALL accept the first user message
  immediately and provision container capability asynchronously instead of
  blocking session creation on container setup.

- [ ] **MULTI-REPO-CHAT-002** — When container capability becomes ready, the
  system SHALL update the session's available tool surface without losing
  conversation history so the same chat can move from inline reasoning to
  workspace-backed actions.

- [ ] **MULTI-REPO-CHAT-003** — When a user clones additional authorized
  repositories into a chat workspace, the system SHALL persist a clone manifest
  that can be replayed when the session is reopened after container teardown.

- [ ] **MULTI-REPO-CHAT-004** — When a chat session holds multiple repositories,
  mutable workspace tools and PR-proposal flows SHALL recompute authorization
  per project instead of trusting stale clone-time access metadata.

- [D] **MULTI-REPO-CHAT-005** — Accounts MAY later opt into lazy provisioning as
  a budget-saving fallback, but the primary product contract for this segment
  is eager background provisioning with in-session capability upgrade.
