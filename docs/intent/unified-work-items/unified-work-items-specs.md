# Unified Work Item EARS

- [x] **UNIFIED-WORK-ITEMS-001** - When a provider returns a unified work
  item, the system SHALL retain its stable provider identity, normalized fields,
  typed extension, raw payload, comments, relations, attachments, assignment
  provenance and override, lifecycle mapping and conflict, and pull-request
  relationships.
  *Tests:* `spec/services/automation/providers/data/work_item_spec.rb`,
  `spec/services/automation/providers/github/work_item_provider_spec.rb`.
  *Code:* `Automation::Providers::Data::WorkItem`,
  `Automation::Providers::Github::WorkItemProvider`.

- [x] **UNIFIED-WORK-ITEMS-009** - When `unified_work_items` is disabled for
  a project, the system SHALL reject a unified-work-item runtime entry point
  while preserving existing GitHub issue behavior. When it is enabled, the
  system SHALL permit that entry point.
  *Tests:* `spec/services/unified_work_items/feature_spec.rb`,
  `spec/services/automation/providers/github/work_item_provider_spec.rb`.
  *Code:* `UnifiedWorkItems::Feature`, `FeatureFlags`.
