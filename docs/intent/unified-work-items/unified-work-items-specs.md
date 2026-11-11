# EARS Specs: Unified Work Items

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Tracking issue: #4854. Rollout decision: [RDR-079](../../rdrs/RDR-079-unified-tracker-work-items-linear-github-migration.md).

- [x] **UNIFIED-WORK-ITEMS-001** — The system SHALL represent a provider work
  item with an explicit provider/resource identity, normalized lifecycle and
  common fields, typed provider extensions, and retained raw payload; SHALL
  represent comments, relations, attachments, assignment provenance and Paid
  overrides, lifecycle mappings and conflicts, and explicit pull-request links
  as typed values; and SHALL preserve existing GitHub `Data::Issue` behavior
  through a lossless conversion path.
  *Tests:* `spec/services/automation/providers/data/work_item_spec.rb`,
  `spec/services/automation/providers/github/work_item_provider_spec.rb`
  *Code:* `Automation::Providers::Data::WorkItem`,
  `Automation::Providers::Data::Issue`,
  `Automation::Providers::Github::WorkItemProvider`

- [ ] **UNIFIED-WORK-ITEMS-002** — When an account configures Linear, the
  system SHALL permit only account owners and admins to configure or revoke its
  one workspace connection, with observable health, configurable synchronization
  defaulting to 15 minutes, pagination and rate-limit outcomes, and clearly
  reported unsupported operations.

- [ ] **UNIFIED-WORK-ITEMS-003** — During Linear synchronization, the system
  SHALL idempotently retain all supported ticket metadata, comments, projects,
  teams, users, relations, dependencies, cycles, attachments, archive/delete
  state, and raw provider payloads, keyed by provider identity; imported
  comments SHALL NOT be reposted.

- [ ] **UNIFIED-WORK-ITEMS-004** — The browser and assignment services SHALL
  show unassigned work first and support filters, individual and bulk
  assignment, current-and-future/future-only/no-auto-assignment mapping modes,
  issue-level customization or replacement, assignment provenance, affected
  issue review flags, preview/confirmation, and mapping- or issue-level
  execution-project defaults.

- [ ] **UNIFIED-WORK-ITEMS-005** — When a user starts a workflow from a
  unified ticket, the system SHALL preserve existing project permissions and
  issue workflow behavior. GitHub-sourced content SHALL remain admitted only
  through the existing GitHub-user allowlist and `issue.trusted?` gate;
  explicit account/project team, user, and provider-identity mappings SHALL be
  an additional admission path for non-GitHub providers and SHALL NOT replace
  or widen that GitHub path. The system SHALL post comments as the configured
  API-key user when permitted and allow agent-run lifecycle writes to be
  configured independently.

- [ ] **UNIFIED-WORK-ITEMS-006** — When lifecycle mappings are configured
  between Linear and Paid, the system SHALL synchronize supported changes in
  both directions with loop prevention, surface simultaneous conflicting
  changes for human review, and never treat an unsupported provider operation
  as successful.

- [ ] **UNIFIED-WORK-ITEMS-007** — The GitHub migration SHALL run offline and
  idempotently, preserve GitHub identity, metadata, comments, Paid state,
  assignments, agent-run history, relationships, provenance, and the existing
  trusted-GitHub-user configuration; it SHALL reconcile issues created during
  the maintenance window and keep existing GitHub issue workflows operational
  through the unified model.

- [ ] **UNIFIED-WORK-ITEMS-008** — Pull requests SHALL remain separate review
  artifacts, with discoverable relationships for Paid-created PRs where
  possible and explicit user linking otherwise; ticket migration SHALL NOT
  replace pull-request review, approval, branch, commit, or merge semantics.

- [x] **UNIFIED-WORK-ITEMS-009** — The system SHALL keep unified work-item
  runtime entry points disabled unless the default-off `unified_work_items`
  feature flag is enabled through `FeatureFlags.enabled?(:unified_work_items,
  project:)`; account tenant-setting overrides SHALL take precedence, and the
  guard SHALL NOT alter existing GitHub issue behavior while disabled.
  *Tests:* `spec/services/automation/providers/unified_work_items_rollout_guard_spec.rb`
  *Code:* `FeatureFlags`,
  `Automation::Providers::UnifiedWorkItemsRolloutGuard`
