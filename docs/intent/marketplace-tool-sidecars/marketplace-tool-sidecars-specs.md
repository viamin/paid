# EARS Specs: Marketplace Tool Sidecars

> Testable claims for the hardened per-run tool sidecar provisioning
> introduced by RDR-073 Phase 3 (`docs/rdrs/RDR-073-marketplace-tool-sidecars.md`).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r TOOL-SIDECAR`).

- [x] **TOOL-SIDECAR-001** — When a marketplace entry with `entry_type:
  "tool"` is attached by the resolver (automatic, team-default, or manual),
  its version SHALL require `install_type: "tool"`, a non-empty `image`, and
  an integer `port` from 1 through 65535. Optional `env` and `hardening`
  values SHALL be objects and optional `alias` SHALL be a non-empty string.
  The renderer SHALL emit `tool_sidecar`, and the attachment pipeline SHALL
  add the normalized definition and marketplace provenance to the run's
  `tool_sidecar_snapshot`, not its MCP snapshot.
  *Tests:* `spec/models/marketplace_entry_version_spec.rb`,
  `spec/services/marketplace_entries/renderer_dbless_spec.rb`,
  `spec/services/marketplace_entries/runtime_attachments_dbless_spec.rb`,
  `spec/services/marketplace_entries/attach_to_run_spec.rb`.
  *Code:* `MarketplaceEntryVersion`, `MarketplaceEntries::Renderer`,
  `MarketplaceEntries::RuntimeAttachments`, `MarketplaceEntries::McpSnapshotSync`.

- [x] **TOOL-SIDECAR-002** — When `marketplace_tool_sidecars` is disabled for
  a run's project, the tool definition SHALL remain snapshotted but
  `Containers::McpProvisioner` SHALL not create or record a tool sidecar
  container. The flag defaults off and is enabled per tenant through
  `tenant_settings.features`; disabling it is the RDR-073 rollback action.
  *Tests:* `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb`.
  *Code:* `FeatureFlags::DEFINITIONS`,
  `Containers::McpProvisioner#tool_sidecars_enabled?`.

- [x] **TOOL-SIDECAR-005** — When a `tool` sidecar is provisioned for an
  agent run, the container SHALL be created on `NetworkPolicy::NETWORK_NAME`
  with all Linux capabilities dropped, `no-new-privileges`, the image-family
  hardening profile when one matches (`Containers::ServiceProvisioner::HARDENING_PROFILES`),
  the `DEFAULT_HARDENING_PROFILE` otherwise, and a stable per-run DNS alias
  (`paid-tool-<sanitized-name>-run<agent_run_id>`) reachable from the agent
  container. The container ID SHALL be recorded on
  `AgentRun#tool_sidecar_container_ids` so retries adopt existing sidecars
  and run cleanup removes them. Capacity inventory SHALL recognize the
  `paid.tool_sidecar` label and persisted IDs as sidecars, excluding them from
  the running-agent count while retaining their resource usage in the paid-agent
  capacity bucket.
  *Tests:* `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb`,
  `spec/services/accounts/operations/auto_capacity_observer_spec.rb`.
  *Code:* `Containers::McpProvisioner#provision` (tool arm),
  `Containers::McpProvisioner#provision_tool_sidecar`,
  `Containers::McpProvisioner#create_hardened_tool_sidecar_container`,
  `Containers::McpProvisioner#cleanup_tool_sidecars`,
  `Containers::McpProvisioner#tool_sidecar_hostname`,
  `Capacity::DockerContainerInventory#sidecar?`.

- [x] **TOOL-SIDECAR-006** — When a `tool` sidecar is provisioned for an
  agent run, the image SHALL be validated against the account's allowlisted
  service images (`UserSetting#allowed_service_images` for the run's
  account's admin/owner membership, the same surface as
  `ServiceContainer#image_in_allowlist`); provisioning SHALL fail closed with a
  non-retryable `Containers::McpProvisioner::Error` when the image is not
  allowlisted. A `PAID_SERVICE_HARDENING`-shaped override SHALL be subject
  to the same validation rules as service-container overrides:
  `readonly_rootfs`/`user` overrides refused for built-in image families
  (`HARDENING_PROFILES`), `cap_add` restricted to
  `SAFE_OVERRIDE_CAPABILITIES`.
  *Tests:* `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb`.
  *Code:* `Containers::McpProvisioner#provision_tool_sidecar`,
  `Containers::McpProvisioner#image_allowed_for_account?`,
  `Containers::McpProvisioner#account_allowed_images`,
  `Containers::ServiceProvisioner#hardening_overrides_for`.
