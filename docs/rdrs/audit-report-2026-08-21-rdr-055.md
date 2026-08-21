# RDR-055 Audit Report — 2026-08-21 Closeout

- **RDR**: [RDR-055: Agent Container Egress Allowlisting](RDR-055-agent-container-egress-allowlisting.md)
- **Audit date**: 2026-08-21
- **Umbrella issue**: [#3441](https://github.com/viamin/paid/issues/3441) (remains open pending the remaining RDR-055 gaps)
- **Follow-up issues**:
  - [#3438](https://github.com/viamin/paid/issues/3438) — production enforcement adapters and fail-closed runtime eligibility
  - [#3439](https://github.com/viamin/paid/issues/3439) — brokered research access with secret-extraction guards
- **Conclusion**: Partially Implemented. The tenant-managed allowlist model, required-destination registry, per-run policy resolution and persistence, provider-neutral runner contract propagation, and tenant UI/run-audit surface are shipped. Domain-aware gateway enforcement and brokered research egress remain open follow-up gaps, so the umbrella should stay open.

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: Tenant-managed account/project allowlist entries exist with server-side host-pattern validation

**Status**: Implemented.

**Shipped**:

- `EgressAllowlistEntry` and the `egress_allowlist_entries` table provide the
  account/project-scoped allowlist model.
- Shared host-pattern validation enforces the RDR-055 domain-rule constraints.

**Trace**:

- `EGRESS-POLICY-001`
- [#3434](https://github.com/viamin/paid/issues/3434)

### Criterion 2: Platform and runner/provider required destinations are resolved from code, not tenant settings

**Status**: Implemented.

**Shipped**:

- `AgentRuns::EgressPolicy::RequiredDestinations` defines the platform, GitHub,
  and runner/provider destination registry.
- The registry raises on configuration drift rather than silently widening
  egress.

**Trace**:

- `EGRESS-POLICY-002`
- [#3435](https://github.com/viamin/paid/issues/3435)

### Criterion 3: Each run gets a deterministic egress snapshot persisted before provisioning

**Status**: Implemented.

**Shipped**:

- `AgentRuns::EgressPolicy::Resolve` builds the per-run snapshot with
  merge/dedupe/provenance handling.
- `Snapshot#persist!` stores the resolved policy on
  `agent_runs.external_metadata["egress_policy"]` before provisioning.

**Trace**:

- `EGRESS-POLICY-003`
- `EGRESS-POLICY-005`
- `EGRESS-POLICY-006`
- [#3436](https://github.com/viamin/paid/issues/3436)

### Criterion 4: The egress policy stays provider-neutral at the runner contract boundary

**Status**: Implemented.

**Shipped**:

- `ExecutionRunners::NetworkingPolicy#egress_profile` carries the locked,
  research, and open profiles without binding orchestration to Docker internals.
- `Containers::Provision#networking_policy_with_egress_profile` propagates the
  policy through provisioning.

**Trace**:

- `CONTAINER-RUNTIME-020`
- [#3437](https://github.com/viamin/paid/issues/3437)

### Criterion 5: Tenant settings and run-detail UI expose the allowlist and audit snapshot

**Status**: Implemented.

**Shipped**:

- Account/project allowlist CRUD is exposed through the settings controllers.
- Run detail renders the persisted egress snapshot plus denied/redacted
  `EgressSecurityEvent` rows.

**Trace**:

- [#3440](https://github.com/viamin/paid/issues/3440)

### Criterion 6: Restricted runs enforce domain-aware outbound access and fail closed in production

**Status**: Gap.

**Missing**:

- The per-host egress gateway that observes the resolved snapshot.
- Production fail-closed runtime eligibility checks when gateway enforcement is
  unavailable.

**Follow-up**:

- [#3438](https://github.com/viamin/paid/issues/3438)

### Criterion 7: Research egress is brokered and guarded against secret extraction

**Status**: Gap.

**Missing**:

- A Paid-side URL fetch/search broker for the `:research` profile.
- Secret-extraction request blocking and fetched-content redaction/quarantine
  behavior.

**Follow-up**:

- [#3439](https://github.com/viamin/paid/issues/3439)

## Summary

What shipped by 2026-08-21:

- tenant-managed allowlist entries and validation
- required-destination registry
- per-run resolution, persistence, and audit snapshot visibility
- provider-neutral `egress_profile` propagation
- denied/redacted egress security event visibility in the run UI

What remains open:

- per-host egress gateway and fail-closed production enforcement
- brokered research egress with secret-extraction guards

Because those two missing pieces still map directly to RDR-055 acceptance
criteria, RDR-055 should remain **Partially Implemented** and umbrella issue
[#3441](https://github.com/viamin/paid/issues/3441) should stay open until they
land.
