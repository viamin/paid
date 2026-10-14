# RDR-073 Epic Final-Acceptance Audit — 2026-10-14

- **RDR**: [RDR-073: Marketplace Tool Sidecars — Per-Run Hardened Tool
  Provisioning](RDR-073-marketplace-tool-sidecars.md); metadata status remains
  **Draft**.
- **Umbrella**: [#4263](https://github.com/viamin/paid/issues/4263).
- **Result**: **Final acceptance is not eligible. #4263 remains open.** Only
  the hardened provisioning slice has shipped; the attachment contract, rule
  conditions, endpoint exposure, and closeout are still absent or open.

This audit follows the [RDR Closeout Checklist](closeout-checklist.md). It
verifies current source, specs, documentation, and live issue state rather than
treating the closed Phase 3 issue as acceptance evidence. It `Tracks #4263`;
it deliberately contains no closing language.

## Acceptance criteria and evidence

| RDR validation criterion | Verdict | Evidence |
| --- | --- | --- |
| A conforming `tool` entry attaches through automatic, team-default, or manual selection and contributes a `tool_sidecar` definition to the run snapshot (`TOOL-SIDECAR-001`) | **Not satisfied.** | `MarketplaceEntries::Renderer#inferred_attachment_strategy` in `app/services/marketplace_entries/renderer.rb` maps only `mcp_server` to `mcp_server` and plugin/provider config entries to `runtime_config`; `tool` falls through to `prompt_append`. `MarketplaceEntries::RuntimeAttachments` exposes only MCP snapshots, runtime environment, and runtime file preparation. No `TOOL-SIDECAR-001` spec or implementation annotation exists. |
| The default-off `marketplace_tool_sidecars` flag prevents tool provisioning while retaining the attachment snapshot (`TOOL-SIDECAR-002`) | **Partially satisfied.** | The flag is defined in `app/services/feature_flags.rb` and `Containers::McpProvisioner#tool_sidecars_enabled?` reads it per project. `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb` proves the tool install arm creates no container while disabled. The required tool attachment/snapshot does not exist, so the full attachment-to-flag-off behavior cannot be demonstrated. |
| Rules independently support issue labels, repo marker files, and languages; empty arrays impose no constraint (`TOOL-SIDECAR-003/004`) | **Not satisfied.** | `MarketplaceEntries::Resolver#rule_matches?` in `app/services/marketplace_entries/resolver.rb` evaluates provider, agent, goal, project, repository, and task-text constraints only. It contains no `issue_labels_includes_any`, `languages_include_any`, or `repo_files_include_any` checks. No matching EARS claims or specs exist. |
| A matched tool provisions one hardened `paid_agent` sidecar with stable per-run DNS and retry-safe tracking (`TOOL-SIDECAR-005`) | **Partially satisfied, but unreachable through marketplace attachment.** | `Containers::McpProvisioner` implements the `tool` arm, hardened HostConfig, `paid-tool-…-run<id>` naming, tracking in `tool_sidecar_container_ids`, cleanup, and health checks. `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb` and `spec/services/accounts/operations/auto_capacity_observer_spec.rb` cover those mechanics. The only source of definitions remains `agent_run.mcp_server_snapshot`; `RuntimeAttachments.mcp_server_snapshots` cannot supply a `tool_sidecar` attachment. |
| Image and hardening overrides fail closed (`TOOL-SIDECAR-006`) | **Satisfied for the shipped provisioning arm.** | `Containers::McpProvisioner#validate_tool_image_allowlisted!` and `#validate_tool_hardening_override!` use the service-image allowlist and `Containers::ServiceProvisioner.compute_hardening_profile`. The tool-install-arm spec covers rejected images and invalid hardening overrides. |
| Lifecycle cleanup, orphan handling, failed-provision cleanup, and explicit endpoint exposure reach the agent (`TOOL-SIDECAR-007`) | **Not satisfied.** | `ExecutionRunners::LocalDockerRunner` reuses the MCP provision/cleanup methods and `McpProvisioner#cleanup_tool_sidecars` removes persisted IDs, but no prompt or environment endpoint exposure exists. The LLD explicitly says Phase 4 is responsible for that exposure. No `TOOL-SIDECAR-007` claim or spec exists; `docs/arrows/index.yaml` still names endpoint exposure as the next RDR-073 work. |

## Shipped behavior

The closed Phase 3 issue has a real, bounded implementation:

- `AgentRun#tool_sidecar_container_ids` is persisted in the schema.
- `Containers::McpProvisioner` can process a pre-existing `install_type:
  "tool"` definition when `marketplace_tool_sidecars` is enabled.
- Tool containers receive service-container hardening, allowlist enforcement,
  labels, health probing, retry adoption, and cleanup.
- Capacity inventory recognizes labeled and persisted tool sidecars.

Those mechanics do not meet the RDR's desired outcome on their own. A project
owner cannot presently publish a `MarketplaceEntry` with `entry_type: "tool"`
and have it become a provisionable sidecar definition, scope that attachment
by labels/repo files/languages, or give the resulting endpoint to the agent.

## Live issue and rollout-guard disposition

GitHub API state checked on 2026-10-14:

| Issue | State |
| --- | --- |
| #4263 umbrella | open |
| #4264 Phase 1 | open |
| #4265 Phase 2 | open |
| #4266 Phase 3 | closed 2026-10-12 |
| #4267 Phase 4 | open |
| #4268 closeout | open |

The `marketplace_tool_sidecars` rollout guard remains defined and default-off.
`FeatureFlags.enabled?(:marketplace_tool_sidecars, project:)` gates the only
shipped tool-provisioning arm. This audit makes no enablement change and does
not remove or broaden the guard.

## Closure decision

**Do not close #4263.** The prerequisite child and closeout issues remain
open, and criteria 001, 003, 004, and 007 have material gaps. The focused
existing owners are sufficient; no duplicate issues are filed:

1. #4264 must ship the tool attachment contract and its flag-off snapshot
   proof.
2. #4265 must add and test the three declarative rule conditions.
3. #4267 must expose the stable alias/endpoint to the agent and demonstrate
   full lifecycle behavior from attached marketplace entry through cleanup.
4. #4268 must reconcile the RDR and README status after the phases have
   shipped, with all `TOOL-SIDECAR-001` through `TOOL-SIDECAR-007` claims in
   the LID segment.

Only after those conditions and passing evidence are present may a future
umbrella audit use GitHub closing language for #4263.
