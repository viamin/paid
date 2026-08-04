# RDR-044: Chat-Driven Configuration Profiles (Operating Modes)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-07-05
- **Status**: Partially Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #3163 (closeout), #3204 (multi-scope profile application), #3205 (chat/legacy profile coverage reconciliation), #3206 (profile audit + rollback follow-up), #2820 (epic), #2821 (Phase 1), #2822 (Phase 2), #2823 (Phase 3)
- **Related RDRs**: [RDR-028](RDR-028-interactive-chat.md) (Interactive Chat), [RDR-042](RDR-042-change-intent-records.md) (Change Intent Records), [RDR-024](RDR-024-multi-tenancy-isolation-strategy.md) (Multi-Tenancy Isolation), [RDR-023](RDR-023-automation-modularization-architecture.md) (Automation Modularization), [RDR-022](RDR-022-auto-merge-pr-strategy.md) (Auto-Merge Strategy), [RDR-014](RDR-014-learned-orchestration.md) (Learned Orchestration)
- **Related Tests**: `spec/mcp/tools/{plan_configuration_profile,apply_configuration_profile,update_project_settings}_spec.rb`, `spec/services/configuration/profiles/{registry,settings,planner,applier}_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/helpers/chat_sessions_helper_spec.rb`, `spec/views/chat_messages/tool_call_partial_spec.rb`

## Implementation Status

Partially implemented as of 2026-08-04. The repository now ships a chat-integrated configuration-profile path built around `Configuration::Profiles::*`, the MCP tools `list_configuration_profiles`, `plan_configuration_profile`, `apply_configuration_profile`, and the granular `update_project_settings` write tool. The chat prompt and UI also explicitly support the recommend -> plan -> confirm -> apply flow.

The shipped scope is narrower than the original RDR:

- the chat profile planner/applier currently targets only a bounded project-level slice of settings, not tenant/user/project bundles
- the chat profile field coverage is materially smaller than the richer operating-mode field set still modeled in the older `ConfigurationProfiles::*` stack
- chat-applied profiles record generic `project.settings_changed` activity, not dedicated `configuration_profile.applied` / `configuration_profile.reverted` events with a supported rollback path

The remaining gaps are tracked by #3204, #3205, and #3206.

## 2026-08-04 Closeout

The original RDR text no longer matches the codebase. The closeout audit for issue #3163 confirmed these shipped behaviors:

- `app/mcp/tools/update_project_settings.rb` now gives chat a project-settings write primitive with permitted-attribute filtering, confirmation, authorization, and activity logging.
- `app/mcp/tools/list_configuration_profiles.rb`, `plan_configuration_profile.rb`, and `apply_configuration_profile.rb` expose curated profile discovery plus a deterministic plan-then-apply flow.
- `app/services/configuration/profiles/{registry,base,settings,planner,plan,applier}.rb` provide the shipped registry/planner/applier implementation, including bounded overrides, prerequisite blocking, transactional apply, and idempotent re-apply.
- `app/services/chat_sessions/build_system_prompt.rb`, `app/helpers/chat_sessions_helper.rb`, and `app/views/chat_messages/_tool_call.html.erb` make configuration profiles a user-visible chat feature rather than a hidden backend primitive.

The closeout also confirmed the following design deltas:

1. **Project-settings write coverage**: satisfied for a broad project-level settings surface through `update_project_settings`, but not extended to tenant/user settings as originally envisioned.
2. **Batched plan-then-apply behavior**: satisfied for the shipped project-level profile slice. One read-only planning tool shows the diff; one confirmed write applies the batch.
3. **Confirmation flow**: satisfied. The chat registry strips `confirmed` from advertised write-tool schemas, and the write tools reject unconfirmed execution.
4. **Profile activity/audit trail**: partially satisfied. Chat-applied profiles are auditable through `project.settings_changed` metadata, but they do not yet use dedicated profile activity events or a supported rollback helper.
5. **Overall closeout status**: the feature is real and user-visible, but the original multi-scope/audit-complete design remains only partially implemented.

### Shipped Test Evidence

- Curated profile registry, settings normalization, planning, idempotent apply, and prerequisite blocking: `spec/services/configuration/profiles/{registry,settings,planner,applier}_spec.rb`
- MCP tool behavior for planning, applying, and direct project-setting writes: `spec/mcp/tools/{plan_configuration_profile,apply_configuration_profile,update_project_settings}_spec.rb`
- Tool-registry exposure and authorization parity: `spec/mcp/tools/{registry,registry_authorization_parity}_spec.rb`
- User-visible prompt guidance, tool summaries, and plan rendering: `spec/services/chat_sessions/build_system_prompt_spec.rb`, `spec/helpers/chat_sessions_helper_spec.rb`, `spec/views/chat_messages/tool_call_partial_spec.rb`

### Remaining Follow-Up Issues

- #3204 — expand chat configuration profiles to tenant/user settings with per-level authorization and skipped-level reporting
- #3205 — broaden chat profile coverage and reconcile the duplicate legacy `ConfigurationProfiles::*` posture registry
- #3206 — restore dedicated audit and rollback semantics for chat-applied profiles

## Problem Statement

Paid's configuration surface is large and federated. Behavioral knobs live across four models — `Project` (~20 automation flags plus the `review_settings`, `model_preferences`, `interop_settings`, `quality_gate_settings` JSONB blobs), `UserSetting` (runner/concurrency/timeouts), `TenantSetting` (caps, guardrails, budgets, agent settings), and `Account` (plan, scheduler pause). Most of these resolve through implicit three- or four-tier inheritance (project → user → tenant → built-in constant), and several are mode-like enums (`auto_merge_mode`, `interop_settings.adoption_mode`, `UserSetting#runner_selection_mode`, `TenantSetting#features.deployment_assurance.tenant_isolation`) that interact in non-obvious ways.

Users cannot easily tell what the "optimal" settings are for a given situation, or whether Paid is currently configured for manual or automated operation. The natural way to close this gap is the interactive chat: a user should be able to say "configure Paid for a single-tenant, single-user, fully-automated setup" and have the chat (1) understand which settings that implies, (2) ask for clarification/confirmation, and (3) change the settings at the relevant levels.

Three concrete gaps block that today:

1. **The chat cannot change project settings.** The tool registry exposes `get_project` (read) but no `update_project_settings`. Yet "fully automated" is expressed almost entirely on `Project` (`auto_pick_enabled`, `review_settings`, `auto_merge_mode`, `allow_bot_authored_pr_auto_merge`, `owner_reviewer_login`, `interop_settings.adoption_mode`, `model_preferences`). The configuration surface most central to operating mode is unreachable from chat.
2. **There is no "operating mode" abstraction.** The knowledge of "for situation X, set these values" has nowhere to live except the LLM's head, which is unreliable, untestable, and drifts. `interop_settings.adoption_mode` is a partial concept but it only gates interop/external execution — it does not cover native auto-pick, review, or merge. Without a vetted, named mapping from intent to settings, the chat would have to re-derive the correct bundle on every request.
3. **There is no batched plan-then-apply UX.** Configuring an operating mode means changing ~10–15 settings across multiple models. The existing confirmation model approves one write tool at a time (`app/mcp/tools/registry.rb:129` strips `confirmed`; `app/services/chat_sessions/resolve_tool_call.rb` claims one pending confirmation). Approving 15 separate operations to "set me up" is unusable, and gives no coherent before/after view of the resulting configuration.

## Context

### Background

Paid orchestrates AI agents against GitHub repos. The degree of automation is configurable per project, and most "is this thing running itself?" decisions are made by a small set of flags and enums whose cumulative effect is hard to reason about:

- `auto_pick_enabled` is the master gate for automatic issue selection (`app/services/issues/auto_pick_project_gate.rb`).
- `review_settings.methods` selects which reviewers act (paid_agent, copilot, codex, ci_action, manual) and how they terminate (`app/services/automation/configuration/review_method.rb`).
- `auto_merge_mode` (`off` / `dependabot_only` / `all`) plus `allow_bot_authored_pr_auto_merge` control whether PRs land without a human.
- `interop_settings.adoption_mode` (`observe_only` / `advisory` / `review_only` / `full_execution`) gates *external/interop* execution only (`app/services/interop/adoption_mode_guard.rb`) — a different axis from native automation.

These flags compose into recognizable operating postures — "fully automated solo", "team with required review", "observe only" — but that composition is implicit. There is no first-class object that says "this set of values = this posture."

### Technical Environment

- **Chat system**: `ChatSession`/`ChatMessage` with a 33-tool registry (`app/mcp/tools/registry.rb`), full LLM function-calling via `agent_harness` transports, and a read/write split. Write tools carry a `confirmed:` argument that is stripped from the schema advertised to the model and injected by the human approver (`registry.rb:129`; RDR-028). Tools authorize via Pundit through `Tools::BaseTool#dispatch` (`app/mcp/tools/base_tool.rb:20`).
- **Confirmation modes**: `Tools::BaseTool.confirmation_mode` is `:pre_dispatch` by default (approve before the write executes). `:post_dispatch` exists for the draft-then-activate pattern (`app/mcp/tools/record_change_intent.rb:9`, RDR-042): `perform` stages a draft, `resolve_confirmation` activates or discards on the human's decision.
- **Settings write tools that already exist**: `update_user_settings` (~40 permitted attrs), `update_tenant_settings` (`PERMITTED_ATTRIBUTES`, `app/mcp/tools/update_tenant_settings.rb:7`), plus provider API keys, MCP server definitions, and account memberships. Each applies one record's changes and records activity via `Accounts::RecordActivity`.
- **Settings model**: `Project` (`db/schema.rb:1818-1909`), `UserSetting` (`db/schema.rb:2513+`), `TenantSetting` (`db/schema.rb:2445-2467`), with `Project::DEFAULT_REVIEW_SETTINGS` (`app/models/project.rb:46-100`) and `TenantSetting` defaults (`app/models/tenant_setting.rb:8-165`) as the canonical baseline.
- **Orchestration defaults precedent**: `OrchestrationStrategies::Defaults` (`app/services/orchestration_strategies/defaults.rb`) is an existing code-curated, versioned Ruby module of canonical configuration values. This RDR proposes the same shape for operating-mode profiles.
- **System prompt**: `ChatSessions::BuildSystemPrompt` (`app/services/chat_sessions/build_system_prompt.rb`) assembles identity, tool list, project context, and preferences under a token budget with priority-ordered sections.

## Research Findings

### Investigation Process

1. Inventoried every settings-bearing model and the behavioral flags/enums each carries.
2. Mapped the existing 33 chat tools to confirm which configuration surfaces are read-reachable and write-reachable.
3. Traced the confirmation/authorization mechanics (`BaseTool`, `resolve_tool_call`, `record_change_intent`) to understand what a batched, multi-model write would require.
4. Checked for any existing "preset/profile/mode" concept (grep across `app/` and `db/`).

### Key Discoveries

**Discovery 1 — Project settings are write-unreachable from chat.** Confirmed: `app/mcp/tools/` contains `get_project` but no `update_project`/`update_project_settings`. This is the single largest gap, because operating-mode behavior is dominated by `Project` columns and JSONB blobs.

**Discovery 2 — No operating-mode abstraction exists.** The only "profile"-named code is `ProjectConventions::AutomationProfile`, which parses conventional-commit semantics — unrelated to settings. "Preset" appears only in marketplace/smoke-test contexts. `adoption_mode` is the closest existing concept but is scoped to interop/external execution and does not govern native auto-pick/review/merge.

**Discovery 3 — The settings surface is genuinely federated and overlapping.** A single posture ("fully automated") requires coordinated changes across:

- **Project**: `auto_pick_enabled`, `automation_on_label_enabled`, `auto_scan_prs`, `auto_merge_mode`, `allow_bot_authored_pr_auto_merge`, `owner_reviewer_login`, `review_settings`, `interop_settings.adoption_mode`, optional `model_preferences`.
- **UserSetting**: `run_concurrency_mode`, runner selection.
- **TenantSetting**: `agent_settings.auto_continue`, caps/budgets.

Any solution that sets only one level produces an incoherent configuration (e.g., auto-pick on but review disabled and no reviewer configured).

**Discovery 4 — Confirmation UX is one-write-at-a-time.** `process_write_tool_calls` (`app/services/chat_sessions/agent_loop.rb`) pauses the loop on the first write tool and persists one pending confirmation. A multi-setting change therefore becomes N separate approvals with no grouped before/after view.

**Discovery 5 — A vetted-bundle approach is both a UX and a security property.** If profiles are code-curated (immutable at runtime), the LLM can only *choose* a profile and supply *limited* overrides — it cannot invent arbitrary setting values. This constrains the write surface far more than a generic "set any setting" tool would.

## Proposed Solution

### Approach

Introduce a code-curated **Configuration Profiles** layer: named, versioned Ruby modules (the same shape as `OrchestrationStrategies::Defaults`) that map an operating posture to concrete target values at the tenant/user/project levels. Expose profiles to the chat through three tools — `list_configuration_profiles` and `plan_configuration_profile` (read-only) and `apply_configuration_profile` (batched write) — plus the missing granular primitive `update_project_settings`. Support the flow **recommend → clarify → plan → confirm → apply** with one human confirmation for the whole bundle, rendered as a grouped before/after diff.

### Design Principles

- **Profiles are code, not data.** They ship in version control, are unit-tested, and are not a runtime mutation surface. This keeps the "what is optimal" knowledge reviewable and immune to prompt injection.
- **The LLM chooses, it does not invent.** The model selects a profile ID and supplies bounded overrides; the target values themselves come from code. A generic "set arbitrary setting" tool is explicitly rejected (see Alternatives).
- **Plan before apply, as two tools.** A deterministic read tool produces the diff; the write tool applies a plan the human has seen. The LLM never fabricates the before/after.
- **One confirmation per posture, not per field.** The batched write carries a structured `Plan`; the existing `confirmed` gate covers the whole bundle.
- **Authorization is per-level, checked up front.** Applying a profile requires the union of permissions for the levels it touches (`ProjectPolicy#update?`, `AccountPolicy#update?` for tenant, `UserSettings` self/owner scope). Levels the caller cannot change are reported as skipped, not silently applied.
- **Idempotent and reversible.** Re-applying a profile is a no-op where values already match; each applied profile records an activity entry so the change is auditable and can be reverted manually.

### Technical Design

#### Configuration::Profiles module

Profiles are plain Ruby modules conforming to a small interface. A registry enumerates them.

```ruby
# app/services/configuration/profiles/registry.rb
module Configuration
  module Profiles
    module Registry
      PROFILES = [
        Configuration::Profiles::SoloAutomated,
        Configuration::Profiles::TeamReviewed,
        Configuration::Profiles::ObserveOnly,
        Configuration::Profiles::ManualOnLabel
      ].freeze

      def self.all = PROFILES
      def self.find(id) = PROFILES.find { |p| p::ID == id } or raise ArgumentError, "Unknown profile: #{id}"
      def self.summaries = all.map { |p| { id: p::ID, title: p::TITLE, description: p.description, scope: p.scope } }
    end
  end
end
```

Each profile declares target values, prerequisites, and the clarifying questions the chat should ask before applying:

```ruby
# app/services/configuration/profiles/solo_automated.rb
module Configuration
  module Profiles
    module SoloAutomated
      ID = "solo_automated"
      TITLE = "Fully automated, single user"

      def self.description
        "Single tenant, single user, fully automated: auto-pick on, paid-agent review, " \
          "auto-merge all PRs, no manual gate. Requires the paid-code-reviewer GitHub App key."
      end

      def self.scope = %i[tenant user project]

      # Values a profile wants to hold. Overrides (user-supplied) are merged on top.
      def self.targets
        {
          project: {
            auto_pick_enabled: true,
            automation_on_label_enabled: true,
            auto_scan_prs: true,
            auto_merge_mode: "all",
            allow_bot_authored_pr_auto_merge: true,
            review_settings: { "enabled" => true, "methods" => { "paid_agent" => { "enabled" => true } } },
            interop_settings: { "adoption_mode" => "full_execution" }
          },
          user: { run_concurrency_mode: "auto" },
          tenant: { agent_settings: { "auto_continue" => true } }
        }
      end

      # Hard prerequisites. If unsatisfied, the Plan lists them as blockers and
      # apply refuses until resolved (the chat can offer to set them up).
      def self.prerequisites_for(project:)
        [].tap do |reqs|
          unless Github::ReviewBotInstallationToken.configured?
            reqs << { key: "paid_reviewer_key", message: "paid-code-reviewer GitHub App key not configured" }
          end
          reqs << { key: "owner_reviewer", message: "owner_reviewer_login must be set to a trusted user" } \
            if project.owner_reviewer_login.blank?
        end
      end

      # Open questions the chat should resolve before applying. Answers become overrides.
      def self.clarifying_questions(project:)
        [
          { id: "merge_method", question: "Preferred merge method?", default: project.merge_method || "squash" },
          { id: "model", question: "Pin a model, or let Paid choose?", default: "auto" }
        ]
      end
    end
  end
end
```

#### Plan and Change value objects

The diff between current state and profile targets is a deterministic `Plan` of `Change` records. This is the reusable abstraction for any future batch operation.

```ruby
# app/services/configuration/profiles/plan.rb
module Configuration
  module Profiles
    Change = Struct.new(:level, :model, :field, :before, :after, :rationale, :no_op, keyword_init: true)
    Plan   = Struct.new(:profile_id, :title, :description, :changes, :prerequisites, :clarifying_questions, keyword_init: true)
  end
end
```

```ruby
# app/services/configuration/profiles/planner.rb
module Configuration
  module Profiles
    class Planner
      def self.plan(profile_id:, project:, overrides: {})
        profile = Registry.find(profile_id)
        targets = deep_merge(profile.targets, overrides)
        Plan.new(
          profile_id: profile_id,
          title: profile::TITLE,
          description: profile.description,
          changes: build_changes(targets, project),
          prerequisites: profile.prerequisites_for(project:),
          clarifying_questions: profile.clarifying_questions(project:)
        )
      end

      def self.build_changes(targets, project)
        # For each level, diff current resolved value against target; emit a
        # Change with no_op: true where they already match.
      end
    end
  end
end
```

#### Applier (transactional, per-level authorized)

```ruby
# app/services/configuration/profiles/applier.rb
module Configuration
  module Profiles
    class Applier
      # Returns an array of per-change results: { change:, applied:, error: }
      def self.apply(plan:, project:, actor:)
        results = []
        ApplicationRecord.transaction do
          plan.changes.reject(&:no_op).each do |change|
            results << apply_change(change, project:, actor:)
          end
        end
        results
      end
    end
  end
end
```

Each `apply_change` updates the right record (`Project`, owner `UserSetting`, `TenantSetting`), records activity via `Accounts::RecordActivity`, and is authorized through Pundit by the corresponding tool before it ever reaches the applier.

#### Chat tools

Four tools are added to `Tools::Registry::TOOL_CLASSES`:

- **`list_configuration_profiles`** (read) — returns `Registry.summaries` plus which levels each profile touches. Lets the chat enumerate postures and pick one from natural language.
- **`plan_configuration_profile`** (read) — input `{ profile_id:, project_id:, overrides: }` → returns the serialized `Plan` (changes with before/after, prerequisites, clarifying questions). This is the "show me what you'd change and what you need" step; it executes no writes.
- **`apply_configuration_profile`** (write, `:pre_dispatch`) — input `{ profile_id:, project_id:, overrides:, confirmed: }`. On `confirmed`, builds the plan, checks per-level authorization (skipping un-permitted levels with a reported reason), runs `Applier.apply` in a transaction, and returns per-change results. One human confirmation applies the whole bundle.
- **`update_project_settings`** (write, `:pre_dispatch`) — the granular primitive that fills the existing gap, mirroring `update_tenant_settings`'s `PERMITTED_ATTRIBUTES` slice and activity recording. Used both standalone and as the engine under `apply_configuration_profile`'s project-level changes.

#### System-prompt guidance

`ChatSessions::BuildSystemPrompt#base_identity` gains a short, profile-aware clause so the chat reaches for profiles rather than inventing settings:

> When the user asks to configure Paid's operating mode or "set up" automation, call `list_configuration_profiles`, recommend a posture, ask the clarifying questions, then call `plan_configuration_profile` to show the diff before applying with `apply_configuration_profile`. Prefer profiles over setting individual flags.

This keeps the knowledge of *which settings matter* in code (the profiles) while leaving *which posture matches intent* to the LLM, which is what it is good at.

### End-to-End Flow

```
User: "Set up Paid for a solo fully-automated workflow."
Chat:  → list_configuration_profiles
       ← [solo_automated, team_reviewed, observe_only, manual_on_label]
Chat:  recommends solo_automated; asks clarifying questions (merge method, model)
User:  answers
Chat:  → plan_configuration_profile(solo_automated, overrides: {merge_method: "squash"})
       ← Plan: 12 changes (project/user/tenant), 1 prerequisite (paid_reviewer_key)
Chat:  presents grouped before/after, notes the prerequisite
User:  approves (resolves prerequisite first if needed)
Chat:  → apply_configuration_profile(solo_automated, confirmed: true)
       ← 12 applied, 0 errors, activity recorded per change
Chat:  confirms and summarizes the resulting posture
```

### Decision Rationale

1. **Code-curated profiles over DB-stored** — keeps the "optimal settings" knowledge in version control, unit-testable, and not a runtime mutation or prompt-injection surface. Editing a profile is a reviewed PR, not an admin click. This matches `OrchestrationStrategies::Defaults` precedent.
2. **Plan and apply as separate tools** — the LLM never authors the before/after; it presents a deterministic diff the human can audit. This is safer and clearer than a single "configure" tool that both computes and applies.
3. **Batched write via a single `confirmed`** — reuses the existing human-in-the-loop gate (RDR-028) rather than inventing new confirmation machinery. The structured `Plan` is what makes the single approval coherent.
4. **Per-level authorization, skip-on-deny** — applying a posture must not silently change tenant settings a non-admin could not otherwise set. Explicit skip-with-reason is safer than a partial transaction the user does not understand.
5. **Bounded overrides, not arbitrary writes** — the LLM supplies answers to declared clarifying questions; it cannot inject ad hoc setting keys. This is the security core of the design.

## Alternatives Considered

### Alternative 1: Let the LLM set individual flags via `update_project_settings` only

**Description**: Ship only the granular `update_project_settings` tool and rely on the LLM to figure out the right combination of flags for "fully automated."

**Pros**:

- Minimal new surface — one tool.
- Maximum flexibility per request.

**Cons**:

- The "what is optimal" knowledge lives in the model's weights: untestable, drifts between models, and is re-derived (inconsistently) every time.
- Produces incoherent states (auto-pick on, review off, no reviewer).
- No prerequisite checking (e.g., enabling `paid_agent` review without the GitHub App key configured silently fails or errors at runtime).
- Every configuration request becomes ~10–15 separate confirmations.

**Reason for rejection**: Fails the core goal — a reliable, low-friction "configure Paid for X" experience. The knowledge must be codified, not improvised.

### Alternative 2: DB-stored, admin-editable profiles

**Description**: Store profile definitions in a table, editable through an admin UI, resolved at apply time.

**Pros**:

- Customers/admins can customize postures without a release.
- Per-tenant profile overrides are natural.

**Cons**:

- Adds a runtime mutation surface that is itself an attack/injection target.
- Requires its own authz, validation, versioning, and audit story.
- Risks drift between shipped profiles and tenant overrides, with no easy review path.
- The set of useful postures is small and stable; the flexibility is not worth the surface.

**Reason for rejection**: Premature flexibility. Code-curated profiles cover the known postures with far less risk. Account-level overrides can be layered later (hybrid) only if a real need emerges.

### Alternative 3: Extend `interop_settings.adoption_mode` into a general operating mode

**Description**: Broaden the existing `adoption_mode` enum (`observe_only`/`advisory`/`review_only`/`full_execution`) to also drive native auto-pick/review/merge.

**Pros**:

- Reuses an existing, understood concept.
- Single source of truth for "mode."

**Cons**:

- `adoption_mode` is semantically about *external/interop execution gating* (`adoption_mode_guard.rb`); overloading it would conflate two independent axes and break existing interop semantics.
- A single enum cannot express the full combinatorial space (auto-pick on/off × review method × auto-merge tier × concurrency model).
- Would require migrating every existing project's behavior.

**Reason for rejection**: Wrong abstraction boundary. Profiles compose the real flags; `adoption_mode` remains one input among them.

### Alternative 4: Generic "execute arbitrary settings change-set" tool

**Description**: A single write tool that accepts an arbitrary `{ model, field, value }[]` array and applies them in a batch.

**Pros**:

- Maximally general; one tool covers every future setting.
- Avoids needing profile definitions.

**Cons**:

- Hands the LLM an unrestricted write surface: it can set any setting to any value, including destructive or security-relevant ones (e.g., disabling quality gates, raising cost caps to maximum).
- No prerequisite checking, no coherence guarantee, no vetted bundles.
- The before/after must be authored by the LLM, which defeats the audit-the-diff principle.

**Reason for rejection**: Violates the "LLM chooses, it does not invent" principle. Profiles bound the write surface to vetted values, which is the whole point.

## Trade-offs and Consequences

### Positive Consequences

- **Closes the project-settings gap**: chat can finally reach the configuration surface that matters most for operating mode.
- **Codifies operating posture**: "fully automated" becomes a tested, versioned object rather than tribal knowledge.
- **One coherent confirmation**: users see the full before/after of a posture change and approve once.
- **Auditable**: every applied profile records per-change activity; re-applying is idempotent.
- **Security-bounded**: the LLM picks among vetted bundles and supplies bounded overrides; it cannot invent setting values.

### Negative Consequences

- **Profile maintenance**: each new operating posture or new setting requires updating profile modules (mitigated: small, stable set of profiles; profiles are plain Ruby and unit-tested).
- **Write-surface expansion**: two new write tools reach `Project` and bundle tenant/user/project changes. Requires careful per-level authz and threat-model review (mitigated: Pundit per level, `confirmed` gate, code-curated targets, RLS via `TenantContext.with(account)`).
- **Partial-permission cases**: an apply that must skip tenant-level changes (non-admin caller) leaves a partially-applied posture. Must be surfaced clearly (mitigated: explicit skip-with-reason in results; chat explains what was and was not applied).

### Risks and Mitigations

- **Risk**: A profile's target values are wrong/harmful (e.g., enable auto-merge in a posture that should require review).
  **Mitigation**: Profiles are code-reviewed and unit-tested; the Plan is shown to the human before apply; activity is recorded for rollback.

- **Risk**: Applying a posture changes tenant-wide settings affecting other users/projects unexpectedly.
  **Mitigation**: Tenant-level changes are flagged prominently in the Plan; per-level authorization is enforced; tenant changes require admin/owner (`AccountPolicy#update?`), matching `update_tenant_settings`.

- **Risk**: The batched apply partially fails mid-transaction (e.g., a validation error on one change).
  **Mitigation**: `Applier.apply` runs in a transaction; a hard failure rolls back all changes and returns structured per-change errors so the chat can explain and retry. Prerequisites are checked before apply to catch the common failure modes upfront.

- **Risk**: LLM selects the wrong profile or supplies a destructive override.
  **Mitigation**: The Plan + human confirmation is the backstop. Overrides are validated against the profile's declared clarifying-question schema, not accepted as arbitrary setting keys.

- **Risk**: Profile set grows stale as new settings are added.
  **Mitigation**: A test asserts that every profile covers the current set of operating-mode-relevant fields (regression guard when new flags land).

## Implementation Plan

### Phase 1: Profile core + project-settings primitive

**Prerequisites:**

- [ ] Interactive chat tool registry and confirmation mechanics (exist, RDR-028)
- [ ] `update_tenant_settings` / `update_user_settings` patterns to mirror (exist)

**Steps:**

1. Add `Configuration::Profiles::Registry`, `Plan`, `Change`, and the four initial profile modules (`SoloAutomated`, `TeamReviewed`, `ObserveOnly`, `ManualOnLabel`).
2. Add `Configuration::Profiles::Planner` (deterministic diff against current resolved state) and unit tests covering no-op detection, override merging, and prerequisite emission.
3. Add `update_project_settings` chat tool, mirroring `update_tenant_settings` (permitted-attribute slice, `confirmed` gate, activity recording, `ProjectPolicy#update?`).
4. Add `Configuration::Profiles::Applier` (transactional, per-level authorized, idempotent, returns per-change results).

**Files to create/modify:**

- `app/services/configuration/profiles/registry.rb`
- `app/services/configuration/profiles/plan.rb`
- `app/services/configuration/profiles/planner.rb`
- `app/services/configuration/profiles/applier.rb`
- `app/services/configuration/profiles/{solo_automated,team_reviewed,observe_only,manual_on_label}.rb`
- `app/mcp/tools/update_project_settings.rb`
- `app/mcp/tools/registry.rb` (register tool)

### Phase 2: Profile chat tools + batch plan-then-apply

**Prerequisites:**

- [ ] Phase 1 complete

**Steps:**

1. Add `list_configuration_profiles` (read) and `plan_configuration_profile` (read) tools.
2. Add `apply_configuration_profile` (write) tool with per-level authorization, prerequisite enforcement, skip-on-deny, and structured result reporting.
3. Extend `ChatSessions::BuildSystemPrompt#base_identity` with profile-driven-configuration guidance.
4. Render a grouped before/after diff in the tool-call confirmation card (`app/views/chat_messages/_tool_call.html.erb`), driven by the serialized `Plan`.

**Files to create/modify:**

- `app/mcp/tools/{list_configuration_profiles,plan_configuration_profile,apply_configuration_profile}.rb`
- `app/mcp/tools/registry.rb` (register tools)
- `app/services/chat_sessions/build_system_prompt.rb`
- `app/views/chat_messages/_tool_call.html.erb`
- `app/helpers/chat_sessions_helper.rb` (plan rendering helpers)

### Phase 3: Hardening + posture coverage

**Prerequisites:**

- [ ] Phases 1 and 2 complete

**Steps:**

1. Regression test asserting every profile covers the current operating-mode-relevant field set (guards against drift as new flags land).
2. Activity/audit summary so a user can ask "what posture am I in?" and have the chat reverse-engineer the nearest profile from current settings (read-only `describe_current_posture` or reuse `plan_*` with a "nearest match" mode).
3. Reverse-apply / rollback helper using the recorded activity entries.
4. Coverage for additional postures as real usage patterns emerge (e.g., `cost_capped_automated`, `quality_strict`).

### Dependencies

- Chat system with MCP tool dispatch and human-in-the-loop confirmation (exists, RDR-028)
- Pundit authorization + `TenantContext` RLS scoping (exists)
- `Accounts::RecordActivity` audit pipeline (exists)
- `Github::ReviewBotInstallationToken.configured?` prerequisite check (exists)

## Validation

### Testing Approach

1. Unit tests for each profile module (targets, prerequisites, clarifying questions).
2. Unit tests for `Planner` (diff correctness, no-op detection, override merge, override rejection of undeclared keys).
3. Unit tests for `Applier` (transactional rollback on failure, idempotent re-apply, per-change result shape, activity recording).
4. Tool specs mirroring `spec/mcp/tools/update_tenant_settings_spec.rb` for `update_project_settings`, `plan_configuration_profile`, and `apply_configuration_profile` (authorization, `confirmed` enforcement, skip-on-deny, prerequisite blocking).
5. Request-level chat specs for the recommend → plan → apply round trip.

### Test Scenarios

1. **Scenario**: User asks to configure fully-automated solo; chat recommends `solo_automated`, asks clarifying questions, plans, and applies.
   **Expected**: All target values set across project/user/tenant; one confirmation; activity recorded per change.

2. **Scenario**: Profile prerequisite unsatisfied (paid-code-reviewer key missing).
   **Expected**: `plan_configuration_profile` lists the prerequisite as a blocker; `apply_configuration_profile` refuses until resolved; chat offers to resolve.

3. **Scenario**: Re-applying an already-applied profile.
   **Expected**: All changes are `no_op`; apply reports zero changes; no duplicate activity.

4. **Scenario**: Non-admin caller applies a posture with tenant-level changes.
   **Expected**: Tenant-level changes skipped with reason; project/user changes applied; result clearly reports the skip.

5. **Scenario**: Validation error mid-apply (e.g., invalid `review_settings`).
   **Expected**: Transaction rolls back all changes; structured per-change error returned; chat explains and retries.

6. **Scenario**: Caller supplies an override key the profile did not declare.
   **Expected**: Override rejected with a clear error; no setting mutated.

7. **Scenario**: Granular `update_project_settings` for a single flag.
   **Expected**: One field updated, activity recorded, authorization enforced.

### Performance Validation

- `plan_configuration_profile` latency: in-process diff over 3 records, < 100 ms.
- `apply_configuration_profile` latency: single transaction over ≤ ~15 fields, < 500 ms.
- No new external calls; profiles are static Ruby.

### Security Validation

- Every write tool enforces Pundit per level (`ProjectPolicy#update?`, `AccountPolicy#update?`).
- `confirmed` is stripped from advertised schemas and injected only by the human approver (existing mechanic).
- Tools run under `TenantContext.with(account)`; RLS enforces tenant isolation.
- Override keys are validated against declared clarifying-question IDs; arbitrary setting keys are rejected.
- Profiles are code-curated (immutable at runtime) — the LLM cannot author target values.

## References

### Requirements & Standards

- RDR-028 Interactive Chat — existing tool registry, confirmation mechanics
- RDR-042 Change Intent Records — `:post_dispatch` confirmation pattern precedent
- RDR-024 Multi-Tenancy Isolation Strategy — RLS / `TenantContext` requirements
- `OrchestrationStrategies::Defaults` — code-curated configuration precedent

### Dependencies

- `app/mcp/tools/base_tool.rb` — tool DSL (`authorize`, `write_operation?`, `confirmation_mode`)
- `app/mcp/tools/update_tenant_settings.rb` — settings write tool template
- `app/services/chat_sessions/resolve_tool_call.rb` — confirmation resolution
- `app/services/chat_sessions/agent_loop.rb` — read/write tool split, loop pause
- `app/models/project.rb` — settings columns and `DEFAULT_REVIEW_SETTINGS`
- `app/services/github/review_bot_installation_token.rb` — paid-reviewer key prerequisite check

## Notes

- The `Plan`/`Change` structs are deliberately generic so future batch operations (e.g., applying a curated quality-gate bundle, or a cost-budget preset) can reuse them without a second design pass.
- If real demand emerges for tenant-customized postures, a hybrid (code-shipped defaults + optional account-level override rows) can be layered on without breaking the interface; this is explicitly deferred.
- A read-only "describe current posture" capability (reverse-engineer the nearest profile from live settings) is a strong Phase 3 candidate; it makes "what mode am I in?" answerable and is a natural complement to the apply flow.
- Account-level and `OrchestrationStrategy` write tools are intentionally out of scope for this RDR (plan changes, billing, and strategy overrides are admin/sensitive surfaces); they can be added later behind their own authorization review.
