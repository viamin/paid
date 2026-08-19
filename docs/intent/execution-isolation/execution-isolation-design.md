---
parent: PAID
prefix: EXECUTION-ISOLATION
---

# Low-Level Design: Execution Isolation

> Companion to the high-level design (`docs/high-level-design.md`) and
> `docs/rdrs/RDR-058-execution-authority-network-and-isolation.md`. This
> segment closes the isolation-invariant test-coverage gap tracked by
> issue #3405: it verifies (and documents) the execution-time guarantees
> that already exist across `Containers::Provision`,
> `Containers::ServiceProvisioner`, `AgentRunPolicy`, and `RunnerCredential`,
> rather than introducing a new capability-grant model. The broader
> capability-declaration and per-run authority-grant work referenced by
> RDR-058 belongs to the still-open #3356/#3402/#3404 and is out of scope
> here.

## Purpose

An agent run's execution environment (workspace volume, logs, secrets,
and any shared service containers) must never leak across accounts,
projects, or other runs — except for service-container sharing that a
project has explicitly opted into. This segment states those invariants
as testable claims and points at the code and tests that already enforce
them.

## Shipped Behavior

- **Workspace/storage isolation.** Each run's writable workspace is a
  Docker named volume keyed to the run's own `agent_run.id`
  (`paid-workspace-{agent_run_id}`), never shared with another run.
  Pooled containers use a pool-entry-scoped volume instead, which is
  reused only through the pool's own reconnect path — never assigned to
  an unrelated run.
- **Log isolation.** `AgentRunLog` rows have no direct account/project
  foreign key; they are reachable only by traversing
  `agent_run → project → account`. `Projects::AgentRunsController#show`
  is the only code path that exposes `agent_run_logs`, and it is gated by
  `authorize @agent_run` (Pundit), which in turn is scoped by
  `AgentRunPolicy#account_for_record` resolving through
  `record.project.account`. A user outside that account cannot reach the
  logs.
- **Secret isolation.** Managed subscription credentials
  (`RunnerCredential`) are looked up through
  `Containers::Provision#managed_subscription_credential_scope_for`,
  which is scoped to `project.account.runner_credentials` — a credential
  belonging to a different account is never resolvable for this run,
  regardless of `runner_key` collisions.
- **Explicit safe service sharing.** `Containers::ServiceProvisioner`
  only ever provisions `ServiceContainer` records reachable through the
  run's own `project.service_containers` association (a
  `ProjectServiceContainer` join). A service container linked only to
  another project is invisible to this run. Within a shared service
  container, each run additionally gets its own per-run database
  (`per_run_db_name`), so even a project-level shared service does not
  leak data between runs.
- **Capability validation, not generic failure.** Backends that cannot
  satisfy a run's mount requirements (e.g. a host-forwarded worktree or
  subscription-auth bind mount on a backend without host-path support)
  are rejected through `Containers::Provision.compatibility_for`, which
  returns a typed `CompatibilityResult` (or raises the more specific
  `ProvisionError` during actual provisioning) instead of surfacing as an
  undifferentiated agent failure.

## What This Is Not

- **Not a capability-declaration system.** Runner/backend capability
  modeling beyond `remote?` / `supports_host_paths?` / `owns_host?`
  belongs to #3356.
- **Not per-run authority grants.** Structured, explicitly-scoped secret
  grants per run (`RunSpec#secrets_config`) belong to #3402/#3404.
- **Not network/egress policy.** Provider-neutral network policy and
  egress control are covered separately by RDR-058's networking layer
  and `NetworkPolicy`.
