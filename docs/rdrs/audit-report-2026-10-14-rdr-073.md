# RDR-073 Closeout Audit — 2026-10-14

- **RDR:** [RDR-073](RDR-073-marketplace-tool-sidecars.md)
- **Closeout issue:** #4268
- **Conclusion:** **Partially Implemented**
- **Epic disposition:** #4263 remains open. This audit and its follow-ups use
  tracking language only; the epic's final acceptance audit is the only work
  that may close it.

## Evidence reviewed

The audit reviewed the current checkout's implementation, permanent specs,
LID artifacts, and RDR validation criteria. Closed implementation issues were
not used as implementation evidence.

| Criterion | Shipped evidence | Result |
| --- | --- | --- |
| TOOL-SIDECAR-001: tool attachments contribute a validated provisioning definition | `app/services/marketplace_entries/renderer.rb:57-62` maps a `tool` entry to `prompt_append`; `app/services/marketplace_entries/runtime_attachments.rb:37-57` accepts only `mcp_server`; `app/models/marketplace_entry_version.rb:12-17` only validates that the artifact is an object. No TOOL-SIDECAR-001 EARS spec or permanent spec exists. | Gap — [#4445](https://github.com/viamin/paid/issues/4445) |
| TOOL-SIDECAR-002: flag-off behavior | `app/services/feature_flags.rb:81-87` defines `marketplace_tool_sidecars`; `app/services/containers/mcp_provisioner.rb:246-305` checks it before creating a tool container; `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb:515-537` covers the disabled path. | Implemented for directly supplied tool snapshot definitions; end-to-end marketplace attachment remains blocked by TOOL-SIDECAR-001. |
| TOOL-SIDECAR-003/004: labels, languages, and repo-file rule conditions | `app/services/marketplace_entries/resolver.rb:133-141` evaluates existing constraints and task text only. The three required keys have no implementation, EARS specification, or permanent test. | Gap — [#4446](https://github.com/viamin/paid/issues/4446) |
| TOOL-SIDECAR-005: hardened, aliased, per-run sidecar | `app/services/containers/mcp_provisioner.rb:98-116,246-299,350-401` has the tool arm, network alias, health probe, resource limits, baseline/profile hardening, and persistence. `db/migrate/20261012023127_add_tool_sidecar_container_ids_to_agent_runs.rb:7-13` persists IDs. `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb:5-603` and `spec/services/accounts/operations/auto_capacity_observer_spec.rb:169-190` cover provisioning and capacity recognition. | Implemented |
| TOOL-SIDECAR-006: image and override gates fail closed | `app/services/containers/mcp_provisioner.rb:310-347` checks the account allowlist and delegates hardening override validation to `ServiceProvisioner`; `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb:213-249,321-399` covers rejection paths. | Implemented |
| TOOL-SIDECAR-007: retry-safe lifecycle and agent exposure | `app/services/containers/mcp_provisioner.rb:139-170,350-401` and `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb:417-588` demonstrate adoption, cleanup, and partial-failure cleanup. The tool result returns only `container_id` (`mcp_provisioner.rb:299`) and does not register an MCP URL; no alternate prompt/environment handoff exposes the alias/endpoint to the agent. No TOOL-SIDECAR-007 EARS spec exists. | Partially implemented — [#4447](https://github.com/viamin/paid/issues/4447) |

## Outcome and rollout guard

The desired user outcome is not realized: marketplace publishers cannot yet
produce a validated tool provisioning definition, rule scoping is incomplete,
and agents receive no tool endpoint. The hardened provisioner alone is not
sufficient evidence of a project owner successfully publishing and using a
rule-scoped tool.

No pilot evidence was found in the reviewed source, permanent specs, or LID
artifacts. Database-backed operational evidence could not be inspected in this
environment because `DATABASE_URL` was absent and PostgreSQL was unavailable
at closeout time. The feature flag therefore remains in place: its cleanup
criteria require hardened provisioning, enforced image gating, and incident-free
pilot tool-attached runs; the final condition is unproven.

The RDR brief supplied no reconsideration conditions. A future closeout must
record pilot tenant/run evidence, incident results, and any user-outcome
reconsideration before changing the guard disposition.

## Follow-up issues and label hygiene

- #4445 — marketplace tool attachment contract
- #4446 — marketplace rule-scoping predicates
- #4447 — agent-facing tool endpoint exposure

Each issue was filed after source verification, carries no labels, and thus
does not carry any of the effective built-in auto-pick skip labels (`planning`,
`research`, `waiting`, `tracking`, `needs-manual-setup`). Closeout issue #4268
also has no labels. No issue in this audit uses closing language for #4263.
