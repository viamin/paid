# RDR-058 Audit Report — 2026-08-17 Closeout

- **RDR**: [RDR-058: Execution Authority, Network Policy, and Isolation](RDR-058-execution-authority-network-and-isolation.md)
- **Audit date**: 2026-08-17
- **Umbrella issue**: [#3418](https://github.com/viamin/paid/issues/3418) (remains open pending the remaining RDR-058 gaps)
- **Conclusion**: Partially Implemented. The enforcement machinery for the
  default authority, network, and isolation invariants is shipped and covered by
  passing spec suites (see [Validation Evidence](#validation-evidence)). The
  per-criterion verdicts below qualify *what is currently enforced*; several
  open blocking dependencies ([#3402](https://github.com/viamin/paid/issues/3402),
  [#3356](https://github.com/viamin/paid/issues/3356),
  [#3404](https://github.com/viamin/paid/issues/3404),
  [#3405](https://github.com/viamin/paid/issues/3405)) describe modeled
  structures and pre-provision validation that is *not* yet implemented — see
  [Blocking Dependencies Reconciliation](#blocking-dependencies-reconciliation).
  Tenant-configurable egress allowlisting (criterion 7) is deferred to
  [RDR-055](RDR-055-agent-container-egress-allowlisting.md).

## Validation Evidence

Executed during the 2026-08-17 closeout audit recorded against umbrella issue
[#3418](https://github.com/viamin/paid/issues/3418). The umbrella remains open
because the remaining RDR-058 gaps are still tracked in its blocking
dependencies. Both batches passed in full; no failures, no pending examples.

```console
$ bin/rspec spec/services/network_policy_spec.rb \
    spec/services/execution_runners_spec.rb \
    spec/services/execution_runners/ \
    spec/models/runner_credential_spec.rb \
    spec/models/runner_auth_attempt_spec.rb \
    spec/requests/runner_credentials_spec.rb \
    spec/policies/runner_credential_policy_spec.rb \
    spec/services/containers/provision_runner_auth_attempt_telemetry_2960_spec.rb \
    spec/services/containers/provision_managed_subscription_auth_2964_spec.rb
281 examples, 0 failures

$ bin/rspec spec/models/preview_session_spec.rb \
    spec/policies/preview_session_policy_spec.rb \
    spec/requests/previews_spec.rb
74 examples, 0 failures
```

The first batch covers criteria 1, 2, 3, 5, and 6 (network policy, runner
contract, credential/auth-attempt models and requests, subscription-auth
materialization telemetry). The second batch covers criterion 4
(preview-session scoping). Criterion 7 has no tests to run — the feature is
not shipped (see below).

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: Per-run authority grants are explicit and secret-free by default

**Shipped**:

- `proxy_token` on `agent_runs` is generated at run creation as a unique random token. Containers receive the token; the proxy adds provider API keys server-side. In `proxy_restricted` and `subscription_auth` mode no raw provider API keys appear in container environment variables.
- `Containers::Provision#derived_networking_policy` selects exactly one of three modes (`proxy_restricted`, `subscription_auth`, `direct_outbound`) before container launch. The mode is stored on the provisioned `RunnerHandle`. The documented `direct_outbound` mode is the explicit exception: it injects user-provided API keys via environment variables for runners that must reach providers directly.
- Subscription-auth credential materialization goes through `Runners::SubscriptionAuthMaterializers`, which writes native credential files (`.credentials.json`, `auth.json`, etc.) into the container filesystem. No token values appear in environment variables or startup command lines.
- `RunnerAuthAttempt` records telemetry for every materialization attempt without storing secret values. The `secret_like?` guard rejects metadata keys whose names or values match known credential patterns.

**Evidence**:

- `app/models/agent_run.rb` — `proxy_token` column; `before_create :generate_proxy_token`
- `app/services/containers/provision.rb` — `derived_networking_policy`, `seed_claude_credentials!`, `seed_codex_credentials!`, `seed_gemini_credentials!`, `seed_copilot_credentials!`
- `app/services/runners/subscription_auth_materializers.rb` — provider-neutral materializer registry; `remote_safe` flags
- `app/models/runner_auth_attempt.rb:109-148` — `FORBIDDEN_METADATA_KEYS`, `SECRET_VALUE_PATTERNS`, `secret_like?`
- `app/controllers/api/secrets_proxy_controller.rb` — proxy-mode key injection

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

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
- `Containers::Provision#derived_networking_policy` returns a `NetworkingPolicy` value based on `subscription_auth?` and `direct_outbound_runner?` predicates. This derivation happens before `ensure_network!` and `apply_network_restrictions!` (which delegates to `NetworkPolicy.apply_firewall_rules`).

**Evidence**:

- `app/services/execution_runners.rb:323-345` — `NetworkingPolicy` Data class
- `app/services/execution_runners.rb:178-237` — `RunSpec` with `networking_policy` field
- `app/services/execution_runners/local_docker_runner.rb` — `provision` method delegating to `NetworkPolicy`
- `app/services/containers/provision.rb:379-392` — `derived_networking_policy`
- `app/services/network_policy.rb:27-80` — `NetworkContract` and network selection

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/services/execution_runners_spec.rb` — `NetworkingPolicy` factory methods, `RunSpec` construction
- `spec/services/network_policy_spec.rb` — network mode selection, firewall rule application
- `spec/support/shared_examples/execution_runner_contract.rb` — runner interface contract

**Verdict**: Satisfied.

---

### Criterion 3: Execution environments have no public ingress by default

**Shipped**:

- The `paid_agent` Docker network is created with `internal: true`, which prevents the Docker bridge from adding a default route to the host network. Containers on this network cannot initiate outbound connections except through the configured firewall rules.
- `NetworkPolicy.create_network` sets `"Internal" => true` for the `paid_agent` network in production.
- No container ports are published in the Docker `create` call. The `LocalDockerRunner` creates containers without `-p` / `--publish` flags.
- The default iptables OUTPUT policy inside containers is `DROP`; only the explicitly listed destinations (GitHub, secrets proxy, DNS, service containers, loopback, established) are allowed.

**Evidence**:

- `app/services/network_policy.rb:329-353` — `create_network` with `"Internal" => true`
- `app/services/network_policy.rb:400-439` — `build_firewall_script` with explicit allowlist and final `iptables -P OUTPUT DROP`
- `app/services/execution_runners/local_docker_runner.rb` — no port publish in create options

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/services/network_policy_spec.rb` — `ensure_network!`, `build_firewall_script`, GitHub IP fetching

**Verdict**: Satisfied.

---

### Criterion 4: Preview/debug ingress exceptions are scoped

**Shipped**:

- Preview tunnel creation is gated on the existence of an explicit `preview_session` record tied to a `project`. Some sessions are also associated with an `agent_run`, but that link is optional.
- `PreviewProvisionState` records tunnel/provision lifecycle state for previews that are launched from agent-run verification flows.
- No code path in the provisioning layer opens ingress ports outside of an explicit `preview_session`.

**Evidence**:

- `app/models/preview_session.rb` — `belongs_to :project`; `belongs_to :agent_run, optional: true`; `build_for(...)` accepts `agent_run: nil`
- `app/controllers/projects_controller.rb` — `queue_preview_provision!` creates and provisions a preview session without requiring an `agent_run`
- `app/models/preview_provision_state.rb` — per-run tunnel state for verification-launched previews
- `db/schema.rb` — `preview_sessions` table documents `agent_run_id` as an optional originating run

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/models/preview_session_spec.rb` — project-owned session creation, optional `agent_run` linkage
- `spec/policies/preview_session_policy_spec.rb` — preview-session authorization boundaries
- `spec/requests/previews_spec.rb` — preview request flow through the project-owned preview path

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

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

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

**Tests** (executed — see [Validation Evidence](#validation-evidence)):

- `spec/services/network_policy_spec.rb` — proxy mode is the default; subscription_auth and direct_outbound require explicit conditions
- `spec/services/execution_runners_spec.rb` — `NetworkingPolicy` factory methods preserve mode isolation

**Verdict**: Satisfied.

---

### Criterion 7: Tenant-configurable egress allowlisting *(gap)*

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

The following gaps remain after this audit. Each is owned by an open issue or
RDR — none is "implicitly satisfied" by the shipped code, and each is
documented here so the umbrella closeout does not overstate the state of its
children.

1. **Structured per-run authority-grant model** — covered by the open
   [issue #3402](https://github.com/viamin/paid/issues/3402). Today the
   authority boundary is enforced (secrets proxy, default-restricted networking,
   subscription-auth materialization) but the authority is implicit in
   `proxy_token` + `derived_networking_policy` rather than modeled as a
   structured grant object that callers can inspect for credential class
   (proxy, GitHub, provider-proxy, provider-direct, subscription-auth, MCP,
   artifact-upload, services). `ExecutionRunners::RunSpec#secrets_config` is
   `nil` in every `from_agent_run` construction path. Building the grant model
   is the remaining scope of #3402; this audit cannot close it.
2. **Runner capability declarations and pre-provisioning validation** —
   covered by the open
   [issue #3356](https://github.com/viamin/paid/issues/3356). The current
   `Containers::Backends::Base` carries only minimal capability signaling
   (`supports_host_paths?`, `remote?`, `owns_host?`); there is no structured
   capability declaration the orchestrator can consult to reject a run
   requesting an unsupported feature (e.g. browser sidecar, ARM64) before
   provisioning. The criterion-1 verdict above is honest about the *enforced*
   default boundary but does not cover the pre-provision validation #3356
   describes. #3404 and #3405 depend on #3356 and remain open for the same
   reason.
3. **Pre-provision enforcement of no-public-ingress with scoped exceptions** —
   covered by the open
   [issue #3404](https://github.com/viamin/paid/issues/3404). The shipped
   enforcement is correct (no published ports, `internal: true` in
   production, preview ingress scoped to `preview_session` records), but the
   runner/pre-provision validation that would *reject* a run asking for
   unsupported inbound exposure is not implemented. This is a sibling of #3356
   and unblocks when capability modeling lands.
4. **Automated isolation invariant checks for execution resources** — covered
   by the open
   [issue #3405](https://github.com/viamin/paid/issues/3405). Some isolation
   invariants are tested today (RLS, per-run `proxy_token` scope, per-run
   workspace volumes, secret metadata rejection), but the broader set from
   #3405 — covering tenant/project/run/storage/log/secret/service isolation
   end-to-end — is not. The criterion-5 verdict above lists what is currently
   tested; #3405 is the remaining scope.
5. **Tenant-configurable egress allowlisting** — tracked in
   [RDR-055](RDR-055-agent-container-egress-allowlisting.md). No new child
   issue is filed; RDR-055 already covers this gap completely.

Items 1–4 are tracked in their respective issues; this audit does not file
new child issues for them because each already names the RDR-058 work item.
The umbrella status of [RDR-058](RDR-058-execution-authority-network-and-isolation.md)
remains **Partially Implemented** as long as any of these gaps is open.

## Child Issues

None filed by this audit. Existing blocking dependencies on the closeout
issue [#3418](https://github.com/viamin/paid/issues/3418) are:

- [#3402](https://github.com/viamin/paid/issues/3402) — Model per-run
  execution authority grants. **Open**. See gap 1 above.
- [#3404](https://github.com/viamin/paid/issues/3404) — Enforce no-public-
  ingress default with scoped exceptions. **Open**. See gap 3 above.
- [#3405](https://github.com/viamin/paid/issues/3405) — Add isolation
  invariant checks for execution resources. **Open**. See gap 4 above.
- [#3341](https://github.com/viamin/paid/issues/3341) — Isolate networking
  policy from Docker network implementation. **Closed**. Its work
  (`ExecutionRunners::NetworkingPolicy`, the runner-boundary translation in
  `NetworkPolicy`) is the shipped evidence for criterion 2.
- [#3343](https://github.com/viamin/paid/issues/3343) — Abstract supporting
  services and sidecars behind the runner boundary. **Open**, but this is
  RDR-054 scope (services and sidecars, not the primary agent container's
  authority/network/isolation invariants). The RDR-058 closeout does not
  block on #3343; the two RDRs cover different boundaries.
- [#3356](https://github.com/viamin/paid/issues/3356) — Runner capability
  modeling for pre-provisioning validation. **Open**. See gap 2 above.
  This is the load-bearing gap: #3404 and #3405 are blocked behind it.

## Blocking Dependencies Reconciliation

The closeout issue [#3418](https://github.com/viamin/paid/issues/3418) lists
six blocking dependencies. This section reconciles each against the
2026-08-17 audit, so the "Partially Implemented" verdict reflects the
real remainder rather than a five-criterion pass.

| Dependency | State | Reconciliation |
|------------|-------|----------------|
| [#3341](https://github.com/viamin/paid/issues/3341) — isolate networking policy from Docker | Closed | Satisfied. The shipped `ExecutionRunners::NetworkingPolicy` and `NetworkPolicy` translation are the evidence cited under criterion 2. |
| [#3343](https://github.com/viamin/paid/issues/3343) — abstract services and sidecars behind the runner boundary | Open | Out of RDR-058 scope. RDR-058 audits the primary agent container's authority, network, and isolation invariants; service/sidecar abstraction is a separate RDR-054 workstream. The RDR-058 closeout does not block on #3343 because the two RDRs cover different boundaries. |
| [#3356](https://github.com/viamin/paid/issues/3356) — runner capability modeling | Open | Remaining RDR-058 scope (gap 2). Capability declarations and pre-provisioning rejection are not implemented. This is the load-bearing gap: #3404 and #3405 are blocked behind it. |
| [#3402](https://github.com/viamin/paid/issues/3402) — model per-run execution authority grants | Open | Remaining RDR-058 scope (gap 1). The shipped enforcement is the *transport* and *application* of a default-restricted authority boundary; the *modeled grant object* #3402 requires is not implemented (`RunSpec#secrets_config` is `nil` in every `from_agent_run` path). |
| [#3404](https://github.com/viamin/paid/issues/3404) — enforce no-public-ingress default with scoped exceptions | Open | Partially satisfied. The shipped network policy and `preview_session` scoping enforce the default; the runner/pre-provision *validation* that rejects unsupported inbound exposure is not implemented (depends on #3356). |
| [#3405](https://github.com/viamin/paid/issues/3405) — isolation invariant checks for execution resources | Open | Partially satisfied. The isolation invariants that *are* implemented (RLS, `proxy_token` scope, per-run workspace volumes, secret metadata rejection) have spec coverage and are reported under criterion 5. The full set from #3405 is the remaining scope. |

Because five of the six blocking dependencies are open and four of those
five represent remaining RDR-058 scope (#3356, #3402, #3404, #3405), the
"Partially Implemented" verdict is load-bearing rather than advisory: the
shipped code closes the *enforcement* layer of RDR-058, but the *modeled
grants*, *capability validation*, *pre-provision enforcement*, and
*end-to-end isolation invariant tests* the children describe are not
complete. Closing the umbrella while children stay open is therefore
premature; this audit recommends keeping the umbrella open and re-running
the closeout after the remaining gaps land.
