# RDR-058 Audit Report — 2026-08-17 Closeout

- **RDR**: [RDR-058: Execution Authority, Network Policy, and Isolation](RDR-058-execution-authority-network-and-isolation.md)
- **Audit date**: 2026-08-17
- **Closeout issue**: [#3418](https://github.com/viamin/paid/issues/3418)
- **Conclusion**: Partially Implemented — core authority, network, and isolation invariants are shipped and tested; tenant-configurable egress allowlisting (criterion 7) is deferred to RDR-055.

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: Per-run authority grants are explicit and secret-free

**Shipped**:

- `proxy_token` on `agent_runs` is generated at run creation as a unique random token. Containers receive the token; the proxy adds provider API keys server-side. Raw keys never appear in container environment variables.
- `Containers::Provision#derived_networking_policy` selects exactly one of three modes (`proxy_restricted`, `subscription_auth`, `direct_outbound`) before container launch. The mode is stored on the provisioned `RunnerHandle`.
- Subscription-auth credential materialization goes through `Runners::SubscriptionAuthMaterializers`, which writes native credential files (`.credentials.json`, `auth.json`, etc.) into the container filesystem. No token values appear in environment variables or startup command lines.
- `RunnerAuthAttempt` records telemetry for every materialization attempt without storing secret values. The `secret_like?` guard rejects metadata keys whose names or values match known credential patterns.

**Evidence**:

- `app/models/agent_run.rb` — `proxy_token` column; `before_create :generate_proxy_token`
- `app/services/containers/provision.rb` — `derived_networking_policy`, `seed_claude_credentials!`, `seed_codex_credentials!`, `seed_gemini_credentials!`, `seed_copilot_credentials!`
- `app/services/runners/subscription_auth_materializers.rb` — provider-neutral materializer registry; `remote_safe` flags
- `app/models/runner_auth_attempt.rb:109-148` — `FORBIDDEN_METADATA_KEYS`, `SECRET_VALUE_PATTERNS`, `secret_like?`
- `app/controllers/api/secrets_proxy_controller.rb` — proxy-mode key injection

**Tests**:

- `spec/models/runner_auth_attempt_spec.rb` — secret metadata rejection, stage/source/mode tracking
- `spec/models/runner_credential_spec.rb` — encrypted storage, active/revoked/expired state
- `spec/services/containers/provision_runner_auth_attempt_telemetry_2960_spec.rb` — telemetry-without-secrets invariant
- `spec/services/containers/provision_managed_subscription_auth_2964_spec.rb` — Gemini/Copilot managed materialization

**Verdict**: Satisfied.

---

### Criterion 2: Network policy is provider-neutral and runner-validated before provisioning

**Shipped**:

- `ExecutionRunners::NetworkingPolicy` is a Data value object with three factory methods (`proxy_restricted`, `subscription_auth`, `direct_outbound`) and two predicates (`restricted?`, `firewall?`). It carries no Docker-specific identifiers.
- `ExecutionRunners::RunSpec` holds the resolved `networking_policy` as an immutable field. The spec is built from `AgentRun` data before any runner is invoked.
- `LocalDockerRunner#provision` reads `run_spec.networking_policy` and delegates firewall and network selection to `NetworkPolicy`. Docker network names (`paid_agent`, `paid_internal`) exist only inside `NetworkPolicy`, not in the runner contract.
- `Containers::Provision#derived_networking_policy` returns a `NetworkingPolicy` value based on `subscription_auth?` and `direct_outbound_runner?` predicates. This derivation happens before `ensure_network!` and `apply_firewall_rules`.

**Evidence**:

- `app/services/execution_runners.rb:323-345` — `NetworkingPolicy` Data class
- `app/services/execution_runners.rb:178-237` — `RunSpec` with `networking_policy` field
- `app/services/execution_runners/local_docker_runner.rb` — `provision` method delegating to `NetworkPolicy`
- `app/services/containers/provision.rb:379-392` — `derived_networking_policy`
- `app/services/network_policy.rb:27-80` — `NetworkContract` and network selection

**Tests**:

- `spec/services/execution_runners_spec.rb` — `NetworkingPolicy` factory methods, `RunSpec` construction
- `spec/services/network_policy_spec.rb` — network mode selection, firewall rule application
- `spec/support/shared_examples/execution_runner_contract.rb` — runner interface contract

**Verdict**: Satisfied.

---

### Criterion 3: Execution environments have no public ingress by default

**Shipped**:

- The `paid_agent` Docker network is created with `internal: true`, which prevents the Docker bridge from adding a default route to the host network. Containers on this network cannot initiate outbound connections except through the configured firewall rules.
- `NetworkPolicy#build_network_create_opts` sets `"Internal" => true` for the `paid_agent` network in production.
- No container ports are published in the Docker `create` call. The `LocalDockerRunner` creates containers without `-p` / `--publish` flags.
- The default iptables OUTPUT policy inside containers is `DROP`; only the explicitly listed destinations (GitHub, secrets proxy, DNS, service containers, loopback, established) are allowed.

**Evidence**:

- `app/services/network_policy.rb:329-353` — `build_network_create_opts` with `"Internal" => true`
- `app/services/network_policy.rb:400-439` — `build_firewall_script` with explicit allowlist and final `iptables -P OUTPUT DROP`
- `app/services/execution_runners/local_docker_runner.rb` — no port publish in create options

**Tests**:

- `spec/services/network_policy_spec.rb` — `ensure_network!`, `build_firewall_script`, GitHub IP fetching

**Verdict**: Satisfied.

---

### Criterion 4: Preview/debug ingress exceptions are scoped

**Shipped**:

- Preview tunnel creation is gated on the existence of a `preview_session` record with an `agent_run_id` foreign key. `PreviewProvisionState` records the current tunnel state per run.
- No code path in the provisioning layer opens ingress ports outside of an explicit `preview_session`.

**Evidence**:

- `app/models/preview_session.rb` — belongs_to `:agent_run`; `agent_run_id` foreign key
- `app/models/preview_provision_state.rb` — per-run tunnel state
- `db/schema.rb` — `preview_sessions` table with `agent_run_id` not-null foreign key

**Tests**:

- Preview session specs cover the `agent_run` association and scoping.

**Verdict**: Satisfied.

---

### Criterion 5: Tenant/project/run isolation invariants are tested

**Shipped**:

- Row-level security on `agent_runs`, `projects`, and `issues` enforces that queries outside a `TenantContext` return only the current account's rows. `TenantContext.with_system_access` is required for cross-tenant reads.
- Per-run `proxy_token` scope: `Api::SecretsProxyController` looks up the run by `proxy_token` and rejects requests for any other run. The token is unique per run and generated at creation.
- Per-run workspace volumes: `LocalDockerRunner` uses `paid-workspace-{agent_run_id}` as the volume name. Each run gets its own volume; there is no shared workspace between runs of different projects.
- `RunnerAuthAttempt` records are scoped to `account_id`, `project_id`, and `agent_run_id` with foreign-key constraints.

**Evidence**:

- `db/schema.rb` — `agent_runs` RLS policy; `proxy_token` unique index
- `app/models/concerns/tenant_scoped.rb` (or equivalent RLS enforcement)
- `app/services/containers/provision.rb` — workspace volume naming
- `app/models/runner_auth_attempt.rb` — `account_id`, `project_id`, `agent_run_id` associations
- `app/controllers/api/secrets_proxy_controller.rb` — `proxy_token` lookup

**Tests**:

- `spec/requests/runner_credentials_spec.rb` — tenant scoping of credential access
- `spec/policies/runner_credential_policy_spec.rb` — authorization boundaries
- `spec/models/runner_auth_attempt_spec.rb` — account/project/run scoping

**Verdict**: Satisfied.

---

### Criterion 6: Subscription-auth and direct-outbound remain explicit exceptions

**Shipped**:

- `Containers::Provision#derived_networking_policy` returns `proxy_restricted` by default. It returns `subscription_auth` only when `subscription_auth?` returns true, and `direct_outbound` only when `direct_outbound_runner?` returns true.
- `NetworkPolicy` translates `proxy_restricted` to the `paid_agent` network with firewall enabled; any non-`proxy_restricted` mode uses `paid_internal` without firewall. No implicit escalation is possible.
- Feature-flag `managed_subscription_runner_auth` guards the subscription-auth materialization path (RDR-041). Disabling the flag falls back to host-forwarded credential detection.

**Evidence**:

- `app/services/containers/provision.rb:379-392` — `derived_networking_policy` with explicit conditional branches
- `app/services/network_policy.rb:72-80` — mode-to-network mapping; default is `paid_agent` with firewall
- `app/services/feature_flags.rb` — `managed_subscription_runner_auth` flag definition

**Tests**:

- `spec/services/network_policy_spec.rb` — proxy mode is the default; subscription_auth and direct_outbound require explicit conditions
- `spec/services/execution_runners_spec.rb` — `NetworkingPolicy` factory methods preserve mode isolation

**Verdict**: Satisfied.

---

### Criterion 7: Tenant-configurable egress allowlisting _(gap)_

**Status**: Not shipped.

**What is missing**: There is no mechanism for a tenant or project owner to add
domain-specific destinations to the egress allowlist beyond the fixed platform-required
set (GitHub, secrets proxy, DNS, service containers). The `allow_destinations` field on
`ExecutionRunners::NetworkingPolicy` exists in the data model but is not populated from
any tenant or project configuration. Per-run policy snapshots are not stored for audit.

**Where this is tracked**: [RDR-055](RDR-055-agent-container-egress-allowlisting.md)
(Draft). RDR-055 describes the egress-policy layer that resolves per-run allowlists
from platform-required, runner-required, account, and project entries and stores a
snapshot per run.

**Child issue**: No new issue is filed for this gap — it is already tracked as the
entirety of RDR-055's implementation scope. RDR-055's status (Draft) accurately
reflects that the work has not started.

**Verdict**: Gap — deferred to RDR-055 implementation.

---

## Gaps

One gap remains:

1. **Tenant-configurable egress allowlisting** — tracked in
   [RDR-055](RDR-055-agent-container-egress-allowlisting.md). No new child issue
   is filed; RDR-055 already covers this gap completely.

## Child Issues

None filed. The only gap (egress allowlisting) is fully covered by the existing
RDR-055 Draft and its planned implementation issues.
