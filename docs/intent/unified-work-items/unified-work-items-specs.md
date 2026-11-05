# EARS Specs: Unified Work Items

- [x] **UNIFIED-WORK-ITEMS-001** — When a provider exposes a unified work
  item, it SHALL return a provider/resource/external identity, normalized core
  fields, typed assignments with provenance and override state, comments,
  relations, attachments, explicit pull-request links, lifecycle mapping and
  conflict state, typed provider extensions, and retained raw payload. Existing
  GitHub `Data::Issue` reads SHALL remain compatible while the richer contract
  is introduced.
  *Code:* `app/services/automation/providers/data/work_item.rb`,
  `app/services/automation/providers/work_item_provider.rb`,
  `app/services/automation/providers/github/work_item_provider.rb`.
  *Test:* `spec/services/automation/providers/data/work_item_spec.rb`,
  `spec/services/automation/providers/github/work_item_provider_spec.rb`.

- [x] **UNIFIED-WORK-ITEMS-009** — When `unified_work_items` is disabled for
  a project, every new unified-work-item runtime entry point SHALL refuse the
  operation and existing GitHub issue behavior SHALL remain available. The flag
  SHALL be registered through `FeatureFlags` as default-off and support normal
  project-scoped enablement.
  *Code:* `app/services/unified_work_items/rollout_guard.rb`,
  `app/services/feature_flags.rb`,
  `app/services/automation/providers/github/work_item_provider.rb`.
  *Test:* `spec/services/unified_work_items/rollout_guard_spec.rb`,
  `spec/services/feature_flags/unified_work_items_spec.rb`,
  `spec/services/automation/providers/github/work_item_provider_spec.rb`.
