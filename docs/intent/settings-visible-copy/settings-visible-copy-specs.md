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
