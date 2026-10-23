# EARS Specs: Marketplace Tool Sidecars

> Testable claims for the hardened per-run tool sidecar provisioning
> introduced by RDR-073 Phase 3 (`docs/rdrs/RDR-073-marketplace-tool-sidecars.md`).
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r TOOL-SIDECAR`).

- [x] **TOOL-SIDECAR-001** — When a marketplace entry with `entry_type:
  "tool"` is attached by the resolver (automatic, team-default, or manual),
  its canonical artifact and every provider renderer that can replace it SHALL
  require `install_type: "tool"`, a non-empty `image`, and an integer `port`
  from 1 through 65535. Optional `env` and `hardening` values SHALL be objects
  and optional `alias` SHALL be a non-empty string.
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

- [x] **TOOL-SIDECAR-003** — `MarketplaceEntries::Resolver#rule_matches?`
  SHALL evaluate `issue_labels_includes_any` as an any-of match against the
  run's `agent_run.issue.labels`, conjunctively with existing condition keys;
  when the key is absent OR empty, the predicate SHALL impose no constraint
  (treating the absence as "match"). When the key is present and non-empty,
  the rule matches iff the issue labels intersect the configured set
  (case-sensitive string equality on the array elements). The issue labels
  SHALL be read at most once per resolution, and only when a rule declares the
  key, so evaluating a rule adds no query of its own.
  *Tests:* `spec/services/marketplace_entries/resolver_dbless_spec.rb`,
  `spec/services/marketplace_entries/resolver_spec.rb`.
  *Code:* `MarketplaceEntries::Resolver#rule_matches?`,
  `MarketplaceEntries::Resolver#match_issue_labels_constraint`,
  `MarketplaceEntries::Resolver#issue_labels`.

- [x] **TOOL-SIDECAR-004** — `MarketplaceEntries::Resolver#rule_matches?`
  SHALL evaluate `languages_include_any` and `repo_files_include_any` as
  any-of matches against `project.effective_repo_profile["languages"]` and
  `project.effective_repo_profile["marker_files"]` respectively, conjunctively
  with existing condition keys. When either key is absent OR empty, the
  predicate SHALL impose no constraint. When present and non-empty, the rule
  matches iff the corresponding profile set intersects the configured set. The
  effective repo profile SHALL be read at most once per resolution, and only
  when a rule declares one of the two keys, so evaluating a rule adds no query
  of its own.
  *Tests:* `spec/services/marketplace_entries/resolver_dbless_spec.rb`,
  `spec/services/marketplace_entries/resolver_spec.rb`.
  *Code:* `MarketplaceEntries::Resolver#rule_matches?`,
  `MarketplaceEntries::Resolver#match_repo_profile_constraint`,
  `MarketplaceEntries::Resolver#repo_profile_values`.

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

- [x] **TOOL-SIDECAR-007** — When a marketplace tool sidecar successfully
  passes provisioning and its health probe, Paid SHALL record its stable
  per-run `{name, hostname, port, url}` endpoint in
  `AgentRun#tool_sidecar_endpoints` and SHALL expose the complete manifest to
  the agent through the non-MCP `PAID_TOOL_SIDECAR_ENDPOINTS` JSON environment
  variable. The manifest SHALL contain no failed, skipped, or unprovisioned
  tools; SHALL not alter `mcp_provisioned_servers`; and SHALL be cleared when
  tool-sidecar cleanup runs or provisioning fails.
  *Tests:* `spec/services/containers/mcp_provisioner_tool_install_arm_spec.rb`,
  `spec/services/containers/provision_spec.rb`.
  *Code:* `Containers::McpProvisioner#provision`,
  `Containers::McpProvisioner#provision_tool_sidecar`,
  `Containers::McpProvisioner#cleanup_tool_sidecars`,
  `Containers::Provision#environment_variables`.
