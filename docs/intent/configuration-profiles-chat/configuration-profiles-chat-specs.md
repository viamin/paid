# EARS Specs: Configuration Profiles Chat

> Testable claims for the planned configuration-profile chat flow. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r CONFIG-PROFILES-001`).

- [x] **CONFIG-PROFILES-001** — When a user asks chat to configure Paid for a
  named operating posture, the system SHALL expose a vetted configuration
  profile registry instead of forcing the model to invent raw settings.

- [x] **CONFIG-PROFILES-002** — When chat needs to mutate project-level
  automation settings as part of a profile, the system SHALL provide an
  authorized `update_project_settings` write surface rather than limiting chat
  writes to user and tenant settings.

- [x] **CONFIG-PROFILES-003** — When a configuration profile is planned, the
  system SHALL render a deterministic before/after diff of the affected tenant,
  user, and project settings before any writes execute.

- [x] **CONFIG-PROFILES-004** — When a user confirms a configuration profile,
  the system SHALL apply the bundled changes through one batched confirmation
  instead of requiring one approval per individual setting write.

- [D] **CONFIG-PROFILES-005** — The profile system MAY later support carefully
  bounded overrides per profile, but the primary contract remains choosing from
  code-curated operating modes rather than arbitrary free-form reconfiguration.

- [ ] **CONFIG-PROFILES-006** — When a new operating-mode-relevant project
  setting ships, the canonical chat-integrated `Configuration::Profiles::*`
  registry SHALL fail regression coverage until every configuration profile
  either covers the setting or explicitly exempts it from operating-mode
  posture handling.

- [x] **CONFIG-PROFILES-007** — When a configuration profile is applied, the
  system SHALL record a dedicated `configuration_profile.applied` activity
  event whose metadata captures the profile name, the list of changed fields,
  the previous value of every changed field, and the value being applied, so
  the change can be reversed without inspecting live settings.

- [x] **CONFIG-PROFILES-008** — When a previously applied configuration
  profile is rolled back through `Configuration::Profiles::Rollback`, the
  system SHALL restore the recorded previous values, refuse to act on events
  that are not `configuration_profile.applied`, and record a matching
  `configuration_profile.reverted` activity event for the same project whose
  metadata identifies the originating applied event (via
  `reverted_from_activity_id`), so each revert can be paired with the apply
  it reverses.
