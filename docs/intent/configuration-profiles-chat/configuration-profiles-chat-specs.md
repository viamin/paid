# EARS Specs: Configuration Profiles Chat

> Testable claims for the planned configuration-profile chat flow. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r CONFIG-PROFILES-001`).

- [ ] **CONFIG-PROFILES-001** — When a user asks chat to configure Paid for a
  named operating posture, the system SHALL expose a vetted configuration
  profile registry instead of forcing the model to invent raw settings.

- [ ] **CONFIG-PROFILES-002** — When chat needs to mutate project-level
  automation settings as part of a profile, the system SHALL provide an
  authorized `update_project_settings` write surface rather than limiting chat
  writes to user and tenant settings.

- [ ] **CONFIG-PROFILES-003** — When a configuration profile is planned, the
  system SHALL render a deterministic before/after diff of the affected tenant,
  user, and project settings before any writes execute.

- [ ] **CONFIG-PROFILES-004** — When a user confirms a configuration profile,
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
