# RDR-058: Execution Authority, Network Policy, and Isolation

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-17
- **Status**: Implemented
- **Type**: Security + Architecture
- **Priority**: P1
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md) (Container Isolation), [RDR-006](RDR-006-secrets-proxy.md) (Secrets Proxy), [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution), [RDR-024](RDR-024-multi-tenancy-isolation-strategy.md) (Multi-Tenancy Isolation Strategy), [RDR-041](RDR-041-subscription-runner-auth-lifecycle.md) (Subscription Runner Managed Auth Lifecycle), [RDR-048](RDR-048-multi-host-docker-backend-support.md) (Multi-Host Docker Backend Support), [RDR-055](RDR-055-agent-container-egress-allowlisting.md) (Agent Container Egress Allowlisting), [RDR-057](RDR-057-remote-execution-data-contract.md) (Remote Execution Data Contract)
- **Related Issues**: [#3418](https://github.com/viamin/paid/issues/3418) (closeout), [#3402](https://github.com/viamin/paid/issues/3402), [#3404](https://github.com/viamin/paid/issues/3404), [#3405](https://github.com/viamin/paid/issues/3405), [#3341](https://github.com/viamin/paid/issues/3341), [#3343](https://github.com/viamin/paid/issues/3343), [#3356](https://github.com/viamin/paid/issues/3356), [#3599](https://github.com/viamin/paid/issues/3599) (final closeout)
- **Related Tests**: `spec/services/network_policy_spec.rb`, `spec/services/execution_runners_spec.rb`, `spec/services/execution_runners/`, `spec/models/runner_credential_spec.rb`, `spec/models/runner_auth_attempt_spec.rb`, `spec/models/agent_run_spec.rb`, `spec/requests/runner_credentials_spec.rb`, `spec/security/tenant_context_spec.rb`, `spec/requests/api/secrets_proxy_spec.rb`, `spec/services/containers/provision_spec.rb`

## Implementation Status

RDR-058 is **implemented** as of 2026-08-23. All seven criteria that belong to
this RDR's own scope — per-run authority grants, provider-neutral network
policy, no-public-ingress-by-default enforcement (including pre-provisioning
rejection), scoped preview ingress, tenant/project/run isolation invariants,
and explicit subscription-auth/direct-outbound exceptions, plus
tenant-configurable egress allowlisting — are shipped with passing test
coverage. The eighth item, RDR-055's brokered research egress with
secret-extraction guards ([#3439](https://github.com/viamin/paid/issues/3439)),
remains open, but the 2026-08-23 final closeout (issue
[#3599](https://github.com/viamin/paid/issues/3599)) determined that item is
RDR-055's own implementation scope, gated by RDR-055's own status and umbrella
issue ([#3441](https://github.com/viamin/paid/issues/3441)) — not further
RDR-058 work. See [2026-08-23 Final Closeout](#2026-08-23-final-closeout-issue-3599)
below for the reasoning.

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Per-run authority grants are explicit and secret-free by default (`direct_outbound` is the documented exception) | Implemented | `app/models/agent_run.rb` `proxy_token` and persisted `authority_grants` snapshot; `app/services/execution_runners.rb` `ExecutionRunners::AuthorityGrantSet`; `app/controllers/api/secrets_proxy_controller.rb`; RDR-006 |
| Network policy is provider-neutral and runner-validated before provisioning | Implemented | `app/services/execution_runners.rb` `NetworkingPolicy`; `app/services/containers/provision.rb` `derived_networking_policy`; `app/services/network_policy.rb` |
| Execution environments have no public ingress by default, including pre-provisioning rejection of unsupported inbound exposure | Implemented | `app/services/execution_runners.rb` `IngressPolicy.default_deny` / `validate_supported!`; `app/services/containers/provision.rb` calls `agent_run.execution_ingress_policy.validate_supported!` before provisioning; `app/services/network_policy.rb` — `paid_agent` network is `internal: true` in production (see `NetworkPolicy.create_network`); no container ports exposed; `docs/intent/execution-ingress/` (`EXEC-INGRESS-001`, `EXEC-INGRESS-002`); `spec/services/network_policy_spec.rb`, `spec/services/containers/provision_spec.rb` |
| Preview/debug ingress exceptions are scoped | Implemented | `preview_sessions` and `PreviewProvisionState` — tunnel creation requires an explicit project-owned `preview_session` record; `AgentRun.preview_execution_metadata` builds a `default_deny` policy with a single `preview` capability scoped to `paid_mediated_tunnel`; `app/models/preview_session.rb`, `app/models/agent_run.rb` |
| Tenant/project/run isolation invariants are tested | Implemented | RLS on `agent_runs`/`projects`: `spec/security/tenant_context_spec.rb`; per-run `proxy_token` scope: `spec/requests/api/secrets_proxy_spec.rb`; per-run named workspace volumes, cross-project service-container scoping, cross-account credential scoping, typed provisioning failures, and log-access authorization: `docs/intent/execution-isolation/` (`EXECUTION-ISOLATION-001..005`); `spec/services/containers/provision_spec.rb`, `spec/services/containers/service_provisioner_spec.rb`, `spec/policies/agent_run_policy_spec.rb`, `spec/requests/agent_runs_spec.rb` |
| Subscription-auth and direct-outbound remain explicit exceptions | Implemented | `NetworkPolicy` defaults to `:proxy` mode; subscription-auth and direct-outbound require explicit `subscription_auth?` / `direct_outbound_runner?` predicates; `spec/services/network_policy_spec.rb` |
| Tenant-configurable egress allowlisting | Implemented | RDR-055's `EgressAllowlistEntry` model, `AgentRuns::EgressPolicy::{Resolve,Gateway}`, and the per-host Docker egress gateway ship the account/project domain allowlist. Restricted runtimes that cannot enforce that profile fail closed, while `GatewayAdapters::{Kubernetes,ManagedMachine}` remain contract stubs pending their runtime implementations; see RDR-055 for full evidence |
| Brokered research egress with secret-extraction guards | Delegated to RDR-055 | Not RDR-058 implementation scope; tracked entirely under RDR-055's own status and [#3439](https://github.com/viamin/paid/issues/3439). Does not block RDR-058 completion — see 2026-08-23 closeout below |

### 2026-08-17 Closeout

Audit recorded against umbrella issue
[#3418](https://github.com/viamin/paid/issues/3418) without closing it. See
[`audit-report-2026-08-17-rdr-058.md`](audit-report-2026-08-17-rdr-058.md) for
full criterion-by-criterion evidence and gap analysis, and a per-dependency
reconciliation of the six blocking children of #3418.

The closeout is **partial**. The shipped implementation provides the
*enforcement* layer for the per-run authority boundary, the default-restricted
network mode, the in-production `internal: true` network (with in-container
iptables firewall fallback in other environments), the preview-session
scoped ingress exceptions, the per-run workspace volume isolation, and the
`proxy_token`-scoped secrets proxy. These correspond to the first five
checklist items from the closeout issue, with the qualifier that the
*enforcement* is shipped but several *modeled* and *pre-provision-validated*
counterparts are not:

- Runner capability modeling and pre-provisioning rejection from
  [#3356](https://github.com/viamin/paid/issues/3356) is not built.
- Pre-provision enforcement of the no-public-ingress default from
  [#3404](https://github.com/viamin/paid/issues/3404) is not built (it
  depends on #3356).
- The full isolation invariant test surface from
  [#3405](https://github.com/viamin/paid/issues/3405) is partial; RLS,
  `proxy_token` scope, per-run workspace volumes, and secret metadata
  rejection are covered, but the broader tenant/project/run/storage/log/secret/service
  matrix is not.

The remaining gap is tenant-configurable egress allowlisting (RDR-055),
tracked in the RDR-055 Draft and its planned implementation issues.

Because five of the six blocking dependencies on #3418 remain open and four
of those five represent remaining RDR-058 scope (#3356, #3402, #3404, #3405),
the umbrella status of RDR-058 stays **Partially Implemented**. Closing the
umbrella while children stay open is premature; the closeout should be
re-run after the remaining gaps land.

### 2026-08-19 Update — Per-Run Authority Grant Model (#3402)

The structured per-run authority-grant model called out as missing above is
now built. Each `agent_run` persists a secret-free `authority_grants`
snapshot (see Layer 1 below), and `ExecutionRunners::RunSpec#authority_grants`
exposes the same `AuthorityGrantSet` at the runner boundary so runner
implementations can validate support before provisioning. `#3402` is closed.

Of the six blocking children of #3418, three remain open (#3356, #3404, #3405)
plus RDR-055 itself. The umbrella status of RDR-058 stays **Partially
Implemented** until those land.

### 2026-08-23 Update — RDR-055 Egress Allowlisting Shipped

RDR-055's tenant-configurable egress allowlisting has since shipped: the `EgressAllowlistEntry` model, `AgentRuns::EgressPolicy::{Resolve,Gateway}`, the per-host Docker egress gateway, and production fail-closed rejection for runtimes that cannot enforce the restricted profile (#3434, #3435, #3436, #3437, #3438) are all merged. The Kubernetes and managed-machine adapter classes included in that work are contract stubs, not shipped enforcement implementations. This supersedes the "RDR-055 is Draft" framing in the 2026-08-17 closeout audit above, which reflected an earlier point in time. RDR-055 itself remains **Partially Implemented**, not Implemented, because its brokered research egress with secret-extraction guards ([#3439](https://github.com/viamin/paid/issues/3439)) is still open; see RDR-055's 2026-08-23 Umbrella Audit for full evidence.

> **Correction (2026-08-23 final closeout, below):** the closing sentence of
> this update as originally written claimed "#3356, #3404, and #3405 remain
> open." That was incorrect at the time it was written: [#3404](https://github.com/viamin/paid/issues/3404)
> closed 2026-08-20 (PR [#3489](https://github.com/viamin/paid/pull/3489)) and
> [#3405](https://github.com/viamin/paid/issues/3405) closed 2026-08-18 (PR
> [#3491](https://github.com/viamin/paid/pull/3491)) — both before this section's
> own dateline. Only [#3356](https://github.com/viamin/paid/issues/3356)
> remains open. See the final closeout section immediately below for the
> corrected reconciliation.

### 2026-08-23 Final Closeout (issue #3599)

Follows the [RDR Closeout Checklist](https://github.com/viamin/paid/blob/main/docs/rdrs/closeout-checklist.md).
This closeout revalidates RDR-058 against the current codebase, corrects the
stale claim above, and resolves the two open questions issue
[#3599](https://github.com/viamin/paid/issues/3599) posed: whether the
execution-authority gap has landed, and whether RDR-055's remaining egress
scope blocks RDR-058 completion. Full criterion-by-criterion evidence is in
[`audit-report-2026-08-23-rdr-058.md`](audit-report-2026-08-23-rdr-058.md).

**#3404 and #3405 are shipped, not open.** Re-checking issue state (not just
re-reading the prior audit's assumptions) shows both closed via merged PRs
before this RDR's own 2026-08-23 dateline: [#3404](https://github.com/viamin/paid/issues/3404)
via [#3489](https://github.com/viamin/paid/pull/3489) (2026-08-20), and
[#3405](https://github.com/viamin/paid/issues/3405) via
[#3491](https://github.com/viamin/paid/pull/3491) (2026-08-18). The code backs
this up: `docs/intent/execution-ingress/` (`EXEC-INGRESS-001`, `EXEC-INGRESS-002`,
both `[x]`) documents pre-provisioning ingress-capability rejection via
`ExecutionRunners::IngressPolicy#validate_supported!`, called from
`Containers::Provision` before workload provisioning — not merely the
runtime iptables enforcement the 2026-08-17 audit described. Likewise
`docs/intent/execution-isolation/` (`EXECUTION-ISOLATION-001..005`, all `[x]`)
documents isolation invariant tests beyond RLS/`proxy_token`/workspace-volume:
cross-project service-container scoping, cross-account credential scoping,
typed provisioning failures, and log-access authorization. Both closeout
issues' full scope shipped.

**Issue #3356 never actually blocked #3404 or #3405.** The 2026-08-17 audit
assumed #3404 and #3405 were "blocked behind"
[#3356](https://github.com/viamin/paid/issues/3356)'s generic
runner-capability model (`host_paths`, `browser_sidecar`,
`architecture_arm64`, etc.). In practice, both issues shipped their own
narrower, purpose-built pre-provisioning validation (`IngressPolicy#validate_supported!`
for ingress; the `EXECUTION-ISOLATION` invariant suite for isolation) without
waiting on #3356's broader capability-negotiation framework. #3356 remains
open and is worth pursuing as its own initiative (multi-runner capability
comparison, referenced from `[PER-08]` in its title — a provider-evaluation
concern, not an RDR-058-labeled issue), but it is not a blocking dependency
for any of RDR-058's shipped criteria. The "execution-authority gap" referred
to in issue #3599's title and summary has landed via #3404/#3405; #3356 itself
continues independently.

**RDR-055's remaining egress-broker gap is separate and does not block RDR-058.**
Criterion 8 (brokered research egress with secret-extraction guards) is the
sole remaining unmet item, tracked entirely by RDR-055's own umbrella issue
[#3441](https://github.com/viamin/paid/issues/3441) and its open child
[#3439](https://github.com/viamin/paid/issues/3439). RDR-055 is a separate RDR
with its own independent status (Partially Implemented) and closeout process;
RDR-058 references egress allowlisting for completeness (Layer 4) but does not
itself implement it. Holding RDR-058 open indefinitely for an item whose
design, implementation, and closeout are owned end-to-end by a different RDR
would conflate the two documents' scopes. This closeout descopes criterion 8
from RDR-058's own completion bar: RDR-058 covers execution authority, network
policy, and isolation (criteria 1-6) plus the platform/tenant-required egress
allowlist surface (criterion 7), all of which are shipped and tested; the
research-broker feature (criterion 8) stays tracked under RDR-055 alone.

**Conclusion**: RDR-058 status changes from Partially Implemented to
**Implemented**. Issue [#3599](https://github.com/viamin/paid/issues/3599) is
closed by the PR that carries this update.

## Problem Statement

Paid runs untrusted agent code in containers on behalf of multiple tenants. The
system must answer three interlocking questions for every agent run:

1. **Authority**: Which secrets and credentials does this run get, and how are they
   granted without embedding raw secrets in the execution environment?
2. **Network**: Which network destinations may the container reach, and is the policy
   provider-neutral so it can be applied consistently across Docker and future remote
   runners?
3. **Isolation**: Are tenant, project, and run boundaries enforced so that a
   compromised container cannot read another run's data, escalate to Paid
   infrastructure, or exfiltrate data to unauthorized destinations?

These three concerns are interrelated: authority determines what credentials flow into
the network path; network policy determines which outbound destinations are reachable;
isolation ensures credentials and data stay within the intended boundary.

## Context

### Existing Foundations

Several prior RDRs address parts of this problem:

- **RDR-004** (Container Isolation): Non-root execution, capability dropping, resource
  limits, read-only root filesystem, per-run workspace volumes, `paid_agent` network
  with iptables default-deny egress.
- **RDR-006** (Secrets Proxy): Provider API keys never enter containers. Agents make
  unauthenticated HTTP calls to the secrets proxy; the proxy adds provider credentials
  server-side before forwarding.
- **RDR-041** (Subscription Runner Managed Auth): Subscription-auth runners (Claude
  Code, Codex, Gemini, Copilot) use managed `RunnerCredential` records rather than
  host-forwarded credential files. The materializer registry seeds credentials into
  containers without embedding raw tokens in environment variables or images.
- **RDR-024** (Multi-Tenancy Isolation): Row-level security on core tables
  (`agent_runs`, `projects`) enforces tenant separation at the database layer.
- **RDR-055** (Egress Allowlisting, Partially Implemented): Per-tenant domain
  allowlisting on top of the base platform-required and runner-required
  destinations has shipped; brokered research egress with secret-extraction
  guards remains open ([#3439](https://github.com/viamin/paid/issues/3439)).
- **RDR-057** (Remote Execution Data Contract): `ExecutionInputManifest` and
  `ExecutionOutputManifest` keep secrets out of cross-boundary manifests by
  construction.

### What Was Missing Before This RDR

No single document described the full authority + network + isolation model as a
unified invariant set, or listed which behavioral contracts are tested and which
remain gaps. This RDR exists to audit the shipped system and record that unified view.

## Recommendation

The unified execution authority, network, and isolation model consists of four
interlocking layers:

### Layer 1 — Per-Run Authority Grants

Every container launch resolves credentials from one of three explicit modes, never
implicitly:

| Mode | Credential source | Network mode |
|------|-------------------|--------------|
| `proxy_restricted` | Secrets proxy (no raw keys in container) | Firewalled, default-deny egress |
| `subscription_auth` | Managed `RunnerCredential` materialized as native file | `paid_internal`, unrestricted egress |
| `direct_outbound` | User-provided API keys via environment | `paid_internal`, unrestricted egress |

The `proxy_token` column on `agent_runs` is the per-run authentication handle for
the secrets proxy. It is generated at run creation, stored as a unique random
token on the run record, and never logged. Containers receive only the token,
not provider API keys.

Subscription-auth materialization goes through `Runners::SubscriptionAuthMaterializers`
and is recorded as a `RunnerAuthAttempt` with telemetry but no secret values.

Each `agent_run` also carries a persisted, secret-free `authority_grants`
snapshot (`ExecutionRunners::AuthorityGrantSet`), built from the run's
resolved networking policy and credential mode. The grant model records
authority classes rather than secret payloads — Paid API proxy token, GitHub
authority, model-provider credentials (with an explicit `proxy_mode` /
`subscription_auth` / `direct_outbound` delivery mode), subscription-auth
material, MCP credentials, object-storage upload authority, and service
credentials. `subscription_auth_material` is emitted only for runs that
materially receive native subscription auth, so proxy-mode and
direct-outbound runs stay distinguishable from subscription-auth runs. The
same `AuthorityGrantSet` is exposed at the runner boundary through
`ExecutionRunners::RunSpec#authority_grants` and embedded in the
`ExecutionInputManifest`, so runner implementations and downstream
manifest/audit consumers can inspect a stable, structured grant contract
without ever seeing secrets.

### Layer 2 — Provider-Neutral Network Policy

`ExecutionRunners::NetworkingPolicy` is the runner-boundary value object that carries
the network mode and per-run `allow_destinations`. It is fully provider-neutral:
no Docker network names, no iptables syntax.

`NetworkPolicy` translates `NetworkingPolicy` to Docker-specific configuration:

- `proxy_restricted` → `paid_agent` network + in-container iptables default-deny
- `subscription_auth` / `direct_outbound` → `paid_internal` network, no firewall

The translation happens inside the private `Containers::Provision#apply_network_restrictions!`,
which is called after container creation and before the agent command is started. That
method delegates to the public `NetworkPolicy.apply_firewall_rules` (a public
`apply_firewall_rules` also exists on `ExecutionRunners::LocalDockerRunner` for
non-provisioning paths such as embedding runs). Runners validate the networking
policy before provisioning; the `RunSpec` carries the resolved policy as an
immutable value.

### Layer 3 — Container and Tenant Isolation

Container isolation (RDR-004):

- Non-root execution (`agent` user, UID 1000)
- Dropped capabilities (`--cap-drop=all`, `NET_RAW` added back only for iptables)
- Read-only root filesystem except tmpfs writable areas (`/tmp` 1 GB, `/home/agent/.cache` 512 MB)
- Resource limits: 4 GB RAM, 2 CPU quota, 500 PIDs
- Per-run workspace via named Docker volume (`paid-workspace-{agent_run_id}`)
- Internal-only `paid_agent` network in production (no public ingress); in other
  environments egress isolation relies on the in-container iptables firewall
- No published container ports

Tenant isolation (RDR-024):

- Row-level security on `agent_runs`, `projects`, and related tables
- `TenantContext.with_system_access` required for cross-tenant queries
- Per-run `proxy_token` scope — the secrets proxy rejects requests for any run other
  than the one identified by the token

### Layer 4 — Egress Policy (RDR-055; allowlisting shipped, research profile pending)

The in-container firewall allows a fixed set of destinations plus the resolved
per-run egress snapshot:

- GitHub (TCP 443 and 22, from a fetched CIDR list with static fallback)
- Secrets proxy host (TCP on `SECRETS_PROXY_PORT`)
- DNS (UDP/TCP 53)
- Service containers (validated IPs and ports)
- Loopback and established connections

Tenant-configurable domain allowlists have shipped via RDR-055:
`EgressAllowlistEntry` persists account/project domain rules, and
`AgentRuns::EgressPolicy::Resolve` merges platform-required, runner-required,
and tenant-allowlisted destinations into a per-run `Snapshot` that populates
`NetworkingPolicy#allow_destinations`. The per-host Docker egress gateway
(`AgentRuns::EgressPolicy::Gateway` and its `GatewayAdapters`) enforces the
snapshot for domain-aware HTTP(S) filtering and fails closed in production
when it cannot be installed. The remaining RDR-055 gap is brokered research
egress with secret-extraction guards
([#3439](https://github.com/viamin/paid/issues/3439)); see RDR-055 for full
evidence.

## Acceptance Criteria

1. **Per-run authority grants are explicit and secret-free by default**: Every
   container launch derives its network mode from
   `Containers::Provision#derived_networking_policy`, which is always one of
   `proxy_restricted`, `subscription_auth`, or `direct_outbound`. In
   `proxy_restricted` and `subscription_auth` mode, no raw provider API keys
   appear in container environment variables or startup scripts; the documented
   `direct_outbound` mode remains the explicit exception that injects
   user-provided API keys for runners that must reach providers directly.

2. **Network policy is provider-neutral and runner-validated before provisioning**:
   `RunSpec` carries an `ExecutionRunners::NetworkingPolicy` value object. The runner
   validates and translates it to Docker configuration; the control plane never writes
   Docker network names or iptables rules directly.

3. **Execution environments have no public ingress by default**: The `paid_agent`
   network is configured with `internal: true` in production (see
   `NetworkPolicy.create_network`); in other environments egress isolation relies on
   the in-container firewall. No container ports are published unless a
   `PreviewSession` record is created explicitly.

4. **Preview/debug ingress exceptions are scoped**: Preview tunnel creation requires
   an explicit `preview_session` record tied to a `project`, with optional
   `agent_run` linkage when the preview reuses a run-owned branch/container. There is
   no mechanism to open ingress without an associated preview-session record.

5. **Tenant/project/run isolation invariants are tested**: Database-level RLS, per-run
   `proxy_token` scope, and per-run workspace volumes all have test coverage. Cross-
   tenant access requires `TenantContext.with_system_access`.

6. **Subscription-auth and direct-outbound remain explicit exceptions**: The default
   network mode for any new run is `proxy_restricted`. Switching to
   `subscription_auth` or `direct_outbound` requires the runner to pass an explicit
   predicate (`subscription_auth?` or `direct_outbound_runner?`).

7. **Tenant-configurable egress allowlisting**: Production tenants can add
   project/account-specific destinations to the egress allowlist beyond the
   platform-required set via RDR-055's `EgressAllowlistEntry` model. The
   resolved policy snapshot for each run is stored on
   `agent_runs.external_metadata["egress_policy"]` for audit.

8. **Brokered research egress with secret-extraction guards** *(gap — RDR-055,
   [#3439](https://github.com/viamin/paid/issues/3439))*: A research-enabled
   run can fetch approved web evidence through Paid without broad direct
   container egress, and outbound requests are scanned for credential-looking
   content before the call is made. Not yet built.

## Implementation Notes

### Secret-Safety Invariants

`RunnerAuthAttempt` enforces secret-safety at the model layer: the `metadata` JSONB
column rejects any key whose name or value matches known secret patterns (token,
refresh_token, access_token, api_key, high-entropy strings, known token shapes). This
prevents telemetry from accidentally capturing a credential value even if a caller
passes the wrong data.

### GitHub IP Fetching

`NetworkPolicy` fetches current GitHub CIDR ranges from the GitHub API meta endpoint
at network setup time, with a hardcoded `DEFAULT_GITHUB_IPS` fallback. This keeps the
allowlist accurate as GitHub changes its infrastructure without requiring a code
deploy.

### Remote Runners

`LocalDockerRunner` is currently the only concrete runner implementation. For a remote
runner, the `ExecutionInputManifest` (RDR-057) carries the networking policy as a
lane reference rather than Docker-specific configuration, keeping the boundary clean.
The remote side translates the manifest into whatever isolation primitives the target
platform offers.

### Codex Remote Placement

Codex managed subscription auth is fully implemented but remote placement remains
gated at `remote_safe: false` in `Runners::SubscriptionAuthMaterializers` until
the refresh/writeback path is validated by telemetry. This is a deliberate constraint,
not a gap.
