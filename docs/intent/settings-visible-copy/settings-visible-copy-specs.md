# EARS Specs: Settings Visible Copy

- [x] **SETTINGS-COPY-001** — When Paid renders the covered project and tenant
  settings, it SHALL describe each option by behavior and consequence without
  exposing Paid-owned decision-record identifiers, internal issue identifiers,
  or repository-specific decision-record example paths.
  *Code:* `app/views/projects/_screenshot_settings.html.erb`,
  `app/views/projects/edit.html.erb`, `app/views/projects/show.html.erb`,
  `app/views/tenant_configurations/edit.html.erb`,
  `app/services/feature_flags.rb`.
  *Test:* `spec/requests/settings_visible_copy_spec.rb`.

- [x] **SETTINGS-COPY-002** — When Paid presents a covered decision or
  mutating action, it SHALL lead with the situation and recommended next step,
  name the action by its effect, disclose what changes and who may take it,
  and place implementation identifiers and diagnostics in an operable
  expandable section when they are needed. Unknown state SHALL remain explicit
  and its next step SHALL be stated.
  *Code:* `app/views/projects/edit.html.erb`,
  `app/views/projects/facet_confidence_evaluations/new.html.erb`,
  `app/views/projects/shadow_evaluations/new.html.erb`.
  *Test:* `spec/requests/settings_visible_copy_spec.rb`,
  `spec/requests/projects/facet_confidence_evaluations_spec.rb`,
  `spec/requests/projects/shadow_evaluations_spec.rb`.
