# EARS Specs: Execution Isolation

> Testable claims for the isolation invariants an agent run's execution
> environment must uphold, per
> `docs/rdrs/RDR-058-execution-authority-network-and-isolation.md` and
> issue #3405. Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r EXECUTION-ISOLATION-001`).

- [x] **EXECUTION-ISOLATION-001** — When a run's container is provisioned,
  the workspace volume SHALL be named after that run's own
  `agent_run.id` (or, for pooled containers, the pool entry), so no two
  runs are ever assigned the same writable workspace volume.
  *Tests:* `spec/services/containers/provision_spec.rb`.
  *Code:* `Containers::Provision#workspace_volume`.

- [x] **EXECUTION-ISOLATION-002** — When a run is provisioned, only
  service containers reachable through the run's own project association
  SHALL be started for that run; a service container linked to a
  different project SHALL NOT be provisioned or exposed to the run.
  *Tests:* `spec/services/containers/service_provisioner_spec.rb`.
  *Code:* `Containers::ServiceProvisioner#selected_service_containers`.

- [x] **EXECUTION-ISOLATION-003** — When a run resolves a managed
  subscription credential for a runner, the lookup SHALL be scoped to the
  run's own account and SHALL NOT resolve a credential belonging to a
  different account, even for the same `runner_key`.
  *Tests:* `spec/services/containers/provision_spec.rb`.
  *Code:* `Containers::Provision#managed_subscription_credential_scope_for`.

- [x] **EXECUTION-ISOLATION-004** — When a backend cannot satisfy a run's
  mount requirements (e.g. it does not support host-path bind mounts for
  a host-forwarded worktree or subscription auth source), capability
  validation SHALL reject the run with a named, typed result
  (`CompatibilityResult#compatible == false` with an `error_message`,
  or a `ProvisionError` during provisioning) rather than letting the run
  fail as a generic agent error.
  *Tests:* `spec/services/containers/provision_spec.rb`.
  *Code:* `Containers::Provision.compatibility_for`,
  `Containers::Provision#validate_backend_mount_support!`.

- [x] **EXECUTION-ISOLATION-005** — When a user requests an agent run's
  detail page (the only surface that exposes `agent_run_logs`),
  authorization SHALL be scoped to the run's own account via
  `record.project.account`, so a user outside that account is denied
  even if they hold a role on the same project.
  *Tests:* `spec/policies/agent_run_policy_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `AgentRunPolicy`, `Projects::AgentRunsController#show`.
