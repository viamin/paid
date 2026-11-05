# EARS Specs: Unified Work Items

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

- [x] **UNIFIED-WORK-ITEMS-009** — The system SHALL keep unified work-item
  runtime entry points disabled unless the default-off `unified_work_items`
  feature flag is enabled through `FeatureFlags.enabled?(:unified_work_items,
  project:)`; account tenant-setting overrides SHALL take precedence, and the
  guard SHALL NOT alter existing GitHub issue behavior while disabled.
  *Tests:* `spec/services/automation/providers/unified_work_items_rollout_guard_spec.rb`
  *Code:* `FeatureFlags`,
  `Automation::Providers::UnifiedWorkItemsRolloutGuard`
