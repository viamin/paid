# RDR-073 Epic Final-Acceptance Audit — 2026-10-20

- **RDR**: [RDR-073: Marketplace Tool Sidecars — Per-Run Hardened Tool
  Provisioning](RDR-073-marketplace-tool-sidecars.md)
- **Umbrella**: [#4263](https://github.com/viamin/paid/issues/4263)
- **Result**: **Final acceptance is eligible. #4263 may be closed.** All four
  delivery phases are shipped against the RDR validation criteria with passing
  permanent tests and EARS coverage. The rollout guard remains in place (no
  enablement change), per the RDR's own cleanup criteria.

This audit refreshes the
[2026-10-14 closeout audit](audit-report-2026-10-14-rdr-073.md),
the [2026-10-14 umbrella final-acceptance audit](audit-report-2026-10-14-rdr-073-epic-final-acceptance.md),
and the
[2026-10-20 attachment-contract audit](audit-report-2026-10-20-rdr-073.md)
against the [RDR Closeout Checklist](closeout-checklist.md). It verifies the
shipping implementation, the EARS artifacts, and the LLD/EARS annotation
discipline rather than relying on closed-issue state.

## Acceptance criteria and evidence

| RDR validation criterion (RDR-073 §Validation) | Verdict | Evidence |
| --- | --- | --- |
| 1. A `tool` entry with a conforming canonical artifact attaches (automatic/team_default/manual) and contributes a `tool_sidecar` provisioning definition to the run snapshot. (`TOOL-SIDECAR-001`) | **Satisfied.** | `MarketplaceEntries::Renderer#inferred_attachment_strategy` at `app/services/marketplace_entries/renderer.rb:57-63` infers `tool_sidecar` for `entry_type: "tool"`. `MarketplaceEntries::RuntimeAttachments` at `app/services/marketplace_entries/runtime_attachments.rb:65-77,123-135` writes the normalized, validated definition to `AgentRun#tool_sidecar_snapshot` (never `mcp_server_snapshot`) for automatic, team-default, and manual attachments. `MarketplaceEntries::AttachToRun` at `app/services/marketplace_entries/attach_to_run.rb:20-54` resolves all three selection modes through the same `Resolver` → `Renderer` → `synchronize_tool_sidecar_snapshot!` path. Canonical-artifact and provider-renderer validation of `install_type == "tool"`, non-empty `image`, integer `port` in 1..65535, and optional `env`/`hardening`/`alias` shapes is enforced at `app/models/marketplace_entry_version.rb:25-36,51-65`. Permanent specs cover the renderer (`spec/services/marketplace_entries/renderer_dbless_spec.rb`), runtime attachments (`spec/services/marketplace_entries/runtime_attachments_dbless_spec.rb`), entry-version validation (`spec/models/marketplace_entry_version_spec.rb`), and automatic/team-default/manual attachment (`spec/services/marketplace_entries/attach_to_run_spec.rb`). |
| 2. With the flag off, no tool sidecar containers are created; run behavior matches pre-feature. (`TOOL-SIDECAR-002`) | **Satisfied.** | The `marketplace_tool_sidecars` flag is defined in `app/services/feature_flags.rb:81-87`. `Containers::McpProvisioner#tool_sidecars_enabled?` is called at `app/services/containers/mcp_provisioner.rb:303` before the tool arm runs; it consults `FeatureFlags.enabled?(:marketplace_tool_sidecars, project:)`. When disabled, `provision_tool_sidecar` returns without creating or recording any container ID (`mcp_provisioner.rb:308-313`). `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb:515-537` covers the disabled-flag path. The flag defaults off; per-tenant opt-in is via `tenant_settings.features`; disabling is the documented rollback action. |
| 3. Rule matching honors `issue_labels_includes_any`, `languages_include_any`, and `repo_files_include_any`, each independently optional, conjunctive with existing conditions; empty arrays behave as "no constraint". (`TOOL-SIDECAR-003/004`) | **Satisfied (this audit's contribution).** | `MarketplaceEntries::Resolver#rule_matches?` at `app/services/marketplace_entries/resolver.rb:133-144` now adds `match_issue_labels_constraint` and two `match_repo_profile_constraint` invocations on top of the existing provider/agent/goal/project/repository/task-text predicates. `match_issue_labels_constraint` (`resolver.rb:167-172`) evaluates `issue_labels_includes_any` as any-of intersection against `agent_run.issue.labels`, returning `true` on absent/empty values and `false` when the rule's set is non-empty but the issue labels don't intersect. `match_repo_profile_constraint` (`resolver.rb:174-179`) does the same for `languages_include_any` against `project.effective_repo_profile["languages"]` and for `repo_files_include_any` against `project.effective_repo_profile["marker_files"]`. `repo_profile_values` (`resolver.rb:188-191`) reads `project.effective_repo_profile` at most once per resolution and only when a rule declares one of the two keys, and `issue_labels` (`resolver.rb:184-186`) does the same for `agent_run.issue.labels`, so evaluating a rule never adds a query of its own. Permanent specs cover absent/empty/match/no-match paths for each key in `spec/services/marketplace_entries/resolver_dbless_spec.rb:289-543` (dbless, 15 cases, including the once-per-resolution read assertions) and `spec/services/marketplace_entries/resolver_spec.rb:120-257` (database, 8 cases). |
| 4. A matching attached tool provisions exactly one sidecar on `paid_agent` with: capabilities dropped, `no-new-privileges`, resource limits, image-family hardening profile where applicable, and a stable per-run DNS alias reachable from the agent container. (`TOOL-SIDECAR-005`) | **Satisfied.** | `Containers::McpProvisioner#provision_tool_sidecar` (`app/services/containers/mcp_provisioner.rb` tool arm) attaches the container to `NetworkPolicy::NETWORK_NAME` (`paid_agent`), builds it through `compute_hardening_profile` (`Containers::ServiceProvisioner`) so `CapDrop: ["ALL"]` and `SecurityOpt: ["no-new-privileges:true"]` are set, applies image-family `HARDENING_PROFILES` where one matches and `DEFAULT_HARDENING_PROFILE` otherwise, and gives the container a stable per-run alias of the form `paid-tool-<sanitized-name>-run<agent_run_id>` (computed by `tool_sidecar_hostname`). Container IDs are recorded on `AgentRun#tool_sidecar_container_ids` so retries adopt existing sidecars and cleanup removes them. `db/migrate/20261012023127_add_tool_sidecar_container_ids_to_agent_runs.rb` adds the column with `@spec TOOL-SIDECAR-005`. `Capacity::DockerContainerInventory#sidecar?` (`app/services/capacity/docker_container_inventory.rb`) recognizes the `paid.tool_sidecar` label and the persisted IDs as sidecars, excluding them from the running-agent count while retaining resource usage in the paid-agent bucket. Permanent specs: `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb` (alias + HostConfig + hardening profile + retry adoption + cleanup), `spec/services/accounts/operations/auto_capacity_observer_spec.rb` (sidecar capacity inventory). |
| 5. Provisioning fails closed for images not permitted for the account, and for hardening overrides that violate the service-container override rules. (`TOOL-SIDECAR-006`) | **Satisfied.** | `Containers::McpProvisioner#provision_tool_sidecar` first validates the image via `image_allowed_for_account?` against `account_allowed_images` (the `UserSetting#allowed_service_images` surface for the run's account's admin/owner membership — the same surface `ServiceContainer#image_in_allowlist` uses). A non-allowlisted image raises `Containers::McpProvisioner::Error` (non-retryable) and is logged with `component = "container_manager"` action `image_gate_rejected`. Hardening overrides pass through `Containers::ServiceProvisioner#hardening_overrides_for`, so the same rules apply as service containers: `readonly_rootfs`/`user` overrides refused for built-in image families, `cap_add` restricted to `SAFE_OVERRIDE_CAPABILITIES`. Permanent specs: `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb` (rejection paths for image, invalid override shapes). |
| 6. Sidecar container IDs are persisted on the run; retries adopt existing sidecars idempotently; run cleanup and orphan cleanup remove them; failed provisioning cleans up partially created containers. (`TOOL-SIDECAR-007`) | **Satisfied.** | Container IDs persist via `db/migrate/20261012023127_add_tool_sidecar_container_ids_to_agent_runs.rb` onto `AgentRun#tool_sidecar_container_ids`. `Containers::McpProvisioner#provision_tool_sidecar` adopts existing sidecars on retry (no duplicates). `Containers::McpProvisioner#cleanup_tool_sidecars` removes persisted IDs on both success and failure paths. Successful tools additionally write a `{name, hostname, port, url}` manifest onto `AgentRun#tool_sidecar_endpoints` (`db/migrate/.../add_tool_sidecar_endpoints_to_agent_runs.rb`); `Containers::Provision#environment_variables` exports it as `PAID_TOOL_SIDECAR_ENDPOINTS` (JSON array, absent when no tools provision). The manifest never alters `mcp_provisioned_servers` (no `url_servers` entry). `mcp_provisioned_servers` and the manifest are independently cleaned up. Permanent specs: `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb` (retry adoption, partial-failure cleanup, cleanup entry-point), `spec/services/containers/provision_spec.rb` (`PAID_TOOL_SIDECAR_ENDPOINTS` exposure). |
| 7. Docs-only RDR PR contains only `docs/rdrs/` changes. | **Satisfied.** | The RDR itself was added under `docs/rdrs/RDR-073-marketplace-tool-sidecars.md` and its companion audit reports under `docs/rdrs/audit-report-*.md`. The first PR (the docs-only RDR) carried only `docs/rdrs/` changes. |

## EARS coverage

The EARS spec for the segment (`docs/intent/marketplace-tool-sidecars/marketplace-tool-sidecars-specs.md`)
carries claims `[x] TOOL-SIDECAR-001`, `[x] TOOL-SIDECAR-002`, `[x] TOOL-SIDECAR-003`,
`[x] TOOL-SIDECAR-004`, `[x] TOOL-SIDECAR-005`, `[x] TOOL-SIDECAR-006`, and
`[x] TOOL-SIDECAR-007`. `@spec TOOL-SIDECAR-003` / `-004` annotations are
present at `app/services/marketplace_entries/resolver.rb:167, 177` and
in `spec/services/marketplace_entries/resolver_dbless_spec.rb:289, 322, 334,
346, 358, 378, 390, 402, 414, 426` and `spec/services/marketplace_entries/resolver_spec.rb:120, 139, 157, 174, 191`.

`bin/coherence-check.mjs` reports no reverse-orphan or staleness findings
against the `marketplace-tool-sidecars` segment (the arrow overlay entry
`marketplace-tool-sidecars` at `docs/arrows/index.yaml:677` is now `status:
OK`, `sampled: 2026-10-20`; previously named the rule-scoping predicate gap).

## Test evidence actually run (2026-10-20)

```
bundle exec rspec \
  spec/services/marketplace_entries/resolver_spec.rb \
  spec/services/marketplace_entries/resolver_dbless_spec.rb \
  spec/services/marketplace_entries/runtime_attachments_dbless_spec.rb \
  spec/services/marketplace_entries/renderer_dbless_spec.rb \
  spec/services/marketplace_entries/attach_to_run_spec.rb \
  spec/models/marketplace_entry_version_spec.rb \
  spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb
# 103 examples, 0 failures
```

`bundle exec rubocop` on `app/services/marketplace_entries/` and
`spec/services/marketplace_entries/` reports no offenses.

## Live issue and rollout-guard disposition

GitHub API state observed against this audit's reference tree (this audit's
focus is the shipping source, not live issue state, but the related issues
are noted here for posterity):

| Issue | Scope | State (last known) |
| --- | --- | --- |
| #4263 (epic umbrella) | Final acceptance audit | Was open; this audit is the closing reference. |
| #4264 (Phase 1) | Attachment contract + rollout guard | Open prior to #4445; closed in 2026-10-20 audit. |
| #4265 (Phase 2) | Rule condition extensions | Open prior to #4446; this audit supplies the shipping evidence. |
| #4266 (Phase 3) | Hardened provisioning | Closed 2026-10-12 (verified by `audit-report-2026-10-14-rdr-073.md`). |
| #4267 (Phase 4) | Lifecycle integration + endpoint exposure | Open prior to #4447; closed by subsequent closeout audit. |

The `marketplace_tool_sidecars` rollout guard remains defined and default-off
as the RDR specifies. `FeatureFlags.enabled?(:marketplace_tool_sidecars,
project:)` gates the only shipped tool-provisioning arm. This audit makes no
enablement change and does not remove or broaden the guard.

## Closure decision

The four delivery phases — marketplace attachment contract (Phase 1), rule
condition extensions (Phase 2), hardened sidecar provisioning (Phase 3), and
run lifecycle integration + endpoint exposure (Phase 4) — now have shipped
code and passing permanent-test evidence against every RDR validation
criterion. The umbrella (#4263) may be closed with GitHub closing language
(`Closes #4263`).

This audit's companion change ships the Phase 2 rule-scoping predicates
(`TOOL-SIDECAR-003`/`004`), with their EARS spec, `@spec` annotations, and
both dbless and database-backed tests. Phases 1, 3, and 4 shipped previously
under #4445, #4266, and #4447 respectively and are verified above against
the current source tree (no regressions in the RDR's implementation status).
