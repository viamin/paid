# RDR-044 Audit Report — 2026-08-04

## Summary

RDR-044 is no longer accurately described as "not implemented". As of Tuesday, August 4, 2026, the repository ships a user-visible chat configuration-profile flow built around `Configuration::Profiles::*`, `list_configuration_profiles`, `plan_configuration_profile`, `apply_configuration_profile`, and the supporting `update_project_settings` write tool.

The closeout issue for this audit is [#3163](https://github.com/viamin/paid/issues/3163). That audit confirmed two things:

1. The profile system is real, test-covered, and exposed through chat.
2. The shipped scope is narrower than the original RDR and still needs focused follow-up work.

## What Shipped

### Project settings are writeable from chat

- `app/mcp/tools/update_project_settings.rb` provides a confirmed, authorized project-settings write path.
- The tool limits writes to a bounded permitted-attribute list and records `project.settings_changed` activity when values change.
- `spec/mcp/tools/update_project_settings_spec.rb` covers confirmation, authorization, attribute filtering, and activity recording.

### Curated profiles are discoverable and plannable

- `app/services/configuration/profiles/{base,registry,settings,planner,plan}.rb` define the shipped profile catalog and deterministic planner.
- `app/mcp/tools/list_configuration_profiles.rb` exposes the curated profiles to chat.
- `app/mcp/tools/plan_configuration_profile.rb` returns a read-only before/after diff, bounded overrides, blocker state, and normalized overrides.
- `spec/services/configuration/profiles/{registry,settings,planner}_spec.rb` and `spec/mcp/tools/plan_configuration_profile_spec.rb` cover registry behavior, override coercion, no-op detection, and prerequisite blocking.

### Profiles apply in one confirmed batch

- `app/mcp/tools/apply_configuration_profile.rb` rebuilds a plan and applies it in one confirmed write operation.
- `app/services/configuration/profiles/applier.rb` enforces prerequisite blocking, project-level authorization, transactional save plus activity logging, and idempotent re-apply behavior.
- `spec/services/configuration/profiles/applier_spec.rb` and `spec/mcp/tools/apply_configuration_profile_spec.rb` cover batch apply, idempotence, rollback-on-failure, confirmation, and blocked-plan behavior.

### The chat UX advertises and renders the feature

- `app/services/chat_sessions/build_system_prompt.rb` explicitly tells the model to prefer configuration profiles for operating-mode setup.
- `app/helpers/chat_sessions_helper.rb` summarizes configuration profile plans and renders curated field labels.
- `app/views/chat_messages/_tool_call.html.erb` renders configuration-profile plan diffs in the transcript UI.
- `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/helpers/chat_sessions_helper_spec.rb`, and `spec/views/chat_messages/tool_call_partial_spec.rb` cover the prompt guidance and user-visible plan rendering.

## Remaining Gaps

### 1. Profile scope is still project-only

The shipped `Configuration::Profiles::Settings` descriptors and `Configuration::Profiles::Applier::LEVEL_POLICIES` only target project-level writes. The original RDR planned coordinated project, user, and tenant configuration.

Follow-up: [#3204](https://github.com/viamin/paid/issues/3204)

### 2. Chat profile coverage is narrower than the repo's older posture model

The chat-integrated `Configuration::Profiles::*` stack covers a bounded slice of operating-mode settings, while the older `ConfigurationProfiles::*` stack still models a broader posture catalog and field set.

Follow-up: [#3205](https://github.com/viamin/paid/issues/3205)

### 3. Audit trail and rollback semantics are still reduced

Chat-applied profiles currently record generic `project.settings_changed` events with profile metadata. They do not yet emit dedicated profile activity events or expose a supported rollback path.

Follow-up: [#3206](https://github.com/viamin/paid/issues/3206)

## Conclusion

RDR-044 should remain **Partially Implemented**:

- The chat-driven configuration-profile feature shipped and is user-visible.
- The original broader multi-scope and audit-complete design did not fully ship.

The RDR should describe the shipped project-level profile flow accurately, point to the existing test evidence, and leave the remaining scope to [#3204](https://github.com/viamin/paid/issues/3204), [#3205](https://github.com/viamin/paid/issues/3205), and [#3206](https://github.com/viamin/paid/issues/3206).
