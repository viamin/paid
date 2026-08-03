# EARS Specs: Configuration Health Checks

> Testable claims for the shipped configuration health-check system. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r HEALTH-CHECKS-001`).

- [x] **HEALTH-CHECKS-001** — When a cached project health result contains a
  finding, the notification adapter SHALL publish an unresolved notification
  for that finding with `nav_section: "projects"` and an `action_url` pointing
  at the project's health page.
  *Code:* `app/services/health_checks/notifications/rule_adapter.rb`.
  *Test:* `spec/services/health_checks/notifications/rule_adapter_spec.rb`.

- [x] **HEALTH-CHECKS-002** — When a previously published cached finding is no
  longer present in the project's cached health result, the notification
  adapter SHALL auto-resolve the stale notification on the next sync.
  *Code:* `app/services/health_checks/notifications/rule_adapter.rb`.
  *Test:* `spec/services/health_checks/notifications/rule_adapter_spec.rb`.

- [x] **HEALTH-CHECKS-003** — When the same health-check code produces more
  than one finding for the same subject but with distinct metadata, the
  notification adapter SHALL preserve each finding as a separate notification
  instead of collapsing them into one record.
  *Code:* `app/services/health_checks/notifications/rule_adapter.rb`.
  *Test:* `spec/services/health_checks/notifications/rule_adapter_spec.rb`.

- [x] **HEALTH-CHECKS-004** — When auto-merge is enabled for a project without
  an owner reviewer login, the project health framework SHALL emit an error
  finding describing that stalled-merge risk.
  *Code:* `app/services/health_checks/checks/project/auto_merge_without_owner.rb`.
  *Test:* `spec/services/health_checks/checks/project/auto_merge_without_owner_spec.rb`.

- [x] **HEALTH-CHECKS-005** — When a runner resolves to a model that the
  registry drift detector reports as deprecated, the project health framework
  SHALL emit a warning finding for that runner.
  *Code:* `app/services/health_checks/checks/runner/deprecated_model.rb`.
  *Test:* `spec/services/health_checks/checks/runner/deprecated_model_spec.rb`.
