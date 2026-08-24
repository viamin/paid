# RDR-058 Audit Report — 2026-08-23 Final Closeout

- **RDR**: [RDR-058: Execution Authority, Network Policy, and Isolation](RDR-058-execution-authority-network-and-isolation.md)
- **Audit date**: 2026-08-23
- **Closeout issue**: [#3599](https://github.com/viamin/paid/issues/3599) (final closeout after runner capability validation lands)
- **Prior audit**: [`audit-report-2026-08-17-rdr-058.md`](audit-report-2026-08-17-rdr-058.md) (2026-08-17 closeout, Partially Implemented)
- **Conclusion**: **Implemented**. All seven criteria that are RDR-058's own implementation scope are shipped with test coverage. The eighth criterion (brokered research egress with secret-extraction guards) is descoped from RDR-058's completion bar because it is RDR-055's own implementation scope, tracked entirely under RDR-055's independent status and umbrella issue. Issue #3599 is closed by this closeout.

## Why this closeout runs now

Issue #3599 named `Depends on #3356` and stated the RDR should be revalidated
"once #3356 is closed." As of this audit, [#3356](https://github.com/viamin/paid/issues/3356)
(`[PER-08] Runner capability modeling for pre-provisioning validation`) is
**still open**. This closeout runs anyway, per the issue's own "Work" section,
to (a) revalidate RDR-058 against the current codebase regardless of #3356's
state, and (b) explicitly determine whether #3356 and RDR-055's remaining
egress-broker gap actually block RDR-058 completion — they turn out not to.

## Correcting the prior record

The 2026-08-17 audit assumed [#3404](https://github.com/viamin/paid/issues/3404)
(no-public-ingress pre-provisioning enforcement) and
[#3405](https://github.com/viamin/paid/issues/3405) (isolation invariant
checks) were both blocked behind #3356's generic capability model, and
recorded them as open, load-bearing gaps. A later narrative update in the RDR
document (dated 2026-08-23, written before this closeout) repeated that claim.
**Both claims were stale.** Re-checking issue state directly shows:

| Issue | State | Closed via | Closed date |
|-------|-------|-----------|-------------|
| [#3404](https://github.com/viamin/paid/issues/3404) | Closed | PR [#3489](https://github.com/viamin/paid/pull/3489) | 2026-08-20 |
| [#3405](https://github.com/viamin/paid/issues/3405) | Closed | PR [#3491](https://github.com/viamin/paid/pull/3491) | 2026-08-18 |
| [#3356](https://github.com/viamin/paid/issues/3356) | Open | — | — |

Both #3404 and #3405 closed *before* the RDR document's own 2026-08-23
narrative update was written, which means that update's "remain open" claim
was incorrect at the time it was written, not just stale by the time of this
audit. The RDR document has been corrected in place (see the "Correction"
callout and the "2026-08-23 Final Closeout" section it links to).

## Acceptance Criteria vs. Shipped Implementation

### Criteria 1, 2, 5, 6: unchanged from the 2026-08-17 audit

Per-run authority grants (criterion 1), provider-neutral network policy
(criterion 2), the credential-scoping portion of tenant/project/run isolation
(criterion 5), and explicit subscription-auth/direct-outbound exceptions
(criterion 6) were already verified **Satisfied** in the 2026-08-17 audit and
have not regressed. `app/services/execution_runners.rb` (1597 lines),
`app/services/containers/provision.rb` (5003 lines), and
`app/services/network_policy.rb` (477 lines) all still exist and carry the
cited methods (`AuthorityGrantSet`, `NetworkingPolicy`,
`derived_networking_policy`, `create_network` with `internal: true`). See the
prior audit for full evidence; this closeout does not re-litigate those
criteria.

### Criterion 3: Execution environments have no public ingress by default (updated)

**Status**: Implemented — now including the pre-provisioning validation the
2026-08-17 audit flagged as missing.

**Shipped** (new since the prior audit, via #3404/PR #3489):

- `ExecutionRunners::IngressPolicy` (`app/services/execution_runners.rb:272-320`)
  — `self.default_deny(capabilities: [])` builds a `public_inbound: false`
  policy; `validate_supported!` raises when a run requests an ingress kind the
  runner cannot support (e.g. `callback`), rather than silently degrading.
- `ExecutionRunners::IngressCapability` (`app/services/execution_runners.rb:181-267`)
  models scoped/authenticated/time-bounded exceptions explicitly.
- `Containers::Provision` calls `agent_run.execution_ingress_policy.validate_supported!`
  before workload provisioning (two call sites, general provisioning and the
  preview-launch path).
- `ExecutionRunners::LocalDockerRunner` raises `ExecutionRunners::ProvisionError`
  if a `RunSpec` carries no `IngressPolicy` or an invalid one.

**Trace**: `docs/intent/execution-ingress/execution-ingress-specs.md` —
`EXEC-INGRESS-001` and `EXEC-INGRESS-002`, both `[x]`.

**Tests**: `spec/services/containers/provision_spec.rb` (rejects unsupported
`callback` exposure pre-provisioning); `spec/services/execution_runners_spec.rb`
and `spec/services/execution_runners/local_docker_runner_spec.rb` (tagged
`@spec EXEC-INGRESS-001` / `@spec EXEC-INGRESS-002`).

**Verdict**: Satisfied. This closes gap 3 from the 2026-08-17 audit.

### Criterion 4: Preview/debug ingress exceptions are scoped (updated)

**Status**: Implemented — unchanged conclusion, additional evidence.

**Shipped**: `AgentRun#execution_ingress_policy` and
`AgentRun.preview_execution_metadata` (`app/models/agent_run.rb:420-446`) build
a `default_deny` `IngressPolicy` with a single `preview` capability scoped to
`paid_mediated_tunnel` and `authentication: { required: true, type: "authenticated_proxy" }`
— preview ingress is mediated by Paid's tunnel/proxy, not open exposure, and
is only ever granted through an explicit `preview_session` record.

**Tests**: `spec/jobs/preview_sessions/provision_job_spec.rb` (preview grant
and audit trail).

**Verdict**: Satisfied (reconfirms the 2026-08-17 verdict with the added
ingress-policy evidence).

### Criterion 5 (isolation invariant breadth): now covers the #3405 scope

**Status**: Implemented — the 2026-08-17 audit's gap 4 (isolation invariants
beyond RLS/`proxy_token`/workspace-volume) is now closed.

**Shipped** (via #3405/PR #3491), `docs/intent/execution-isolation/execution-isolation-specs.md`
— five EARS claims, all `[x]`:

- `EXECUTION-ISOLATION-001` — workspace volume named after the run's own ID.
  `Containers::Provision#workspace_volume`; `spec/services/containers/provision_spec.rb:1354`.
- `EXECUTION-ISOLATION-002` — service containers scoped to the run's own
  project; cross-project containers are not started.
  `Containers::ServiceProvisioner#selected_service_containers`;
  `spec/services/containers/service_provisioner_spec.rb:83`.
- `EXECUTION-ISOLATION-003` — managed subscription credential lookup scoped to
  the run's own account. `Containers::Provision#managed_subscription_credential_scope_for`;
  `spec/services/containers/provision_spec.rb:5282`.
- `EXECUTION-ISOLATION-004` — incompatible mount requirements fail with a
  typed `ProvisionError`/`CompatibilityResult`, not a generic failure;
  `spec/services/containers/provision_spec.rb:322`.
- `EXECUTION-ISOLATION-005` — agent run log access scoped to
  `record.project.account`. `AgentRunPolicy`;
  `spec/policies/agent_run_policy_spec.rb:9`, `spec/requests/agent_runs_spec.rb:1064`.

**Verdict**: Satisfied. This closes gap 4 from the 2026-08-17 audit.

### Criterion 7: Tenant-configurable egress allowlisting

**Status**: Implemented (unchanged from the 2026-08-23 RDR-055-shipped update
already in the RDR document). `EgressAllowlistEntry`,
`AgentRuns::EgressPolicy::{Resolve,Gateway}`, and the per-host Docker egress
gateway ship the account/project domain allowlist with production fail-closed
behavior. See RDR-055 for full evidence.

### Criterion 8: Brokered research egress with secret-extraction guards

**Status**: Gap — but descoped from RDR-058's completion bar (see below).

**Missing**: The brokered fetch/search service, request-budgeting, and
secret-extraction guards for the `:research` egress profile. Tracked
end-to-end by [#3439](https://github.com/viamin/paid/issues/3439), a child of
RDR-055's own umbrella issue [#3441](https://github.com/viamin/paid/issues/3441).

## The #3356 question: does it block RDR-058?

**No.** The 2026-08-17 audit treated issue #3356 (generic runner-capability
declarations: `host_paths`, `browser_sidecar`, `architecture_arm64`,
`persistent_workspace`, etc.) as the "load-bearing gap" behind issues #3404
and #3405. In practice, both issues shipped their own narrower,
purpose-built pre-provisioning validation — `IngressPolicy#validate_supported!`
for ingress, the `EXECUTION-ISOLATION` invariant suite for isolation —
without depending on issue #3356's broader capability-negotiation framework.
Issue #3356's own title (`[PER-08] Runner capability modeling for
pre-provisioning validation`) and its own "Proposed scope" (coordinating with
issue #3338, a runner-contracts issue, for multi-runner capability comparison
generally) mark it as a
provider-evaluation initiative that happens to be adjacent to RDR-058, not an
RDR-058-labeled issue in the same series as #3402/#3404/#3405 (which all carry
an `RDR-058:` title prefix). #3356 remains open and worth pursuing on its own
timeline; it is not a blocking dependency for any RDR-058 acceptance
criterion.

## The RDR-055 question: does the remaining egress-broker gap block RDR-058?

**No — it is separate.** Criterion 8 is the only unmet item, and its design,
implementation, and closeout are owned end-to-end by RDR-055 (own status:
Partially Implemented; own umbrella issue #3441; own open child #3439).
RDR-058 references egress allowlisting for completeness under "Layer 4" but
implements none of it directly — RDR-055 does. Holding RDR-058 open
indefinitely for a feature whose lifecycle is entirely tracked in a different
RDR document would conflate the two RDRs' scopes and give closeout
maintainers no way to ever mark RDR-058 "Implemented" short of also finishing
RDR-055. This closeout descopes criterion 8 from RDR-058's own completion bar:
RDR-058 covers execution authority, network policy, and isolation (criteria
1-6) plus the platform/tenant-required egress allowlist surface (criterion 7),
all shipped and tested. The research-broker feature stays tracked under
RDR-055 alone, and RDR-055's own status continues to reflect that it is not
yet implemented.

## Summary

What shipped since the 2026-08-17 audit (all already merged before this
closeout ran):

- Pre-provisioning ingress-capability validation (`IngressPolicy`,
  `EXEC-INGRESS-001/002`) — closes gap 3.
- Broader isolation invariant test coverage across workspace, service
  containers, credentials, provisioning failures, and log access
  (`EXECUTION-ISOLATION-001..005`) — closes gap 4.

What remains open, and why it does not block RDR-058:

- [#3356](https://github.com/viamin/paid/issues/3356) — a separate,
  broader runner-capability-modeling initiative that never actually blocked
  RDR-058's shipped criteria.
- [#3439](https://github.com/viamin/paid/issues/3439) — RDR-055's own
  remaining scope, tracked and gated independently under RDR-055.

RDR-058 status changes from **Partially Implemented** to **Implemented**.
Issue [#3599](https://github.com/viamin/paid/issues/3599) is closed by the PR
carrying this audit and the corresponding RDR/README updates.
