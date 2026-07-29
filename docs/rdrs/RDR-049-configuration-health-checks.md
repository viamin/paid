# RDR-049: Configuration Health Checks

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Status**: Proposed
- **Date**: 2026-07-29
- **Priority**: P1
- **Related Issues**: #3050 (tracking/umbrella), #3049 (RDR PR); phased issues #3051–#3058 (see "Implementation Plan")
- **Related RDRs**: RDR-008 (Model Selection Strategy), RDR-022 (Auto-Merge PR Strategy), RDR-023 (Automation Modularization Architecture), RDR-030 (GitHub App Bot Account), RDR-040 (Runner Model Compatibility Contracts), RDR-041 (Subscription Runner Auth Lifecycle)

## Implementation Status

Not yet implemented. This RDR defines the design; implementation is broken into phased issues that hang off a tracking (umbrella) issue. The umbrella issue is the verification gate: RDR-049 stays `Proposed` / `Partially Implemented` until the closeout audit confirms the shipped code matches this plan.

## Problem Statement

Paid has rich, interdependent configuration across three scopes:

- **Project** — review settings, auto-merge mode, owner/reviewer logins, allowed GitHub usernames, data classification, GitHub credentials.
- **Runner** — tier-to-model mappings (`tier_models` / `tier_model_ids`), auth type, credentials, enabled flags.
- **User** — runner fleet, default/fallback runners, container settings.

Each individual field is well-validated in isolation (see `Project` validations at `app/models/project.rb:288-304`, `UserSetting` validations). But many real-world misconfigurations are **cross-field and cross-scope**: every setting involved is valid on its own, yet the *combination* is broken or silently no-ops. Two concrete examples that motivate this RDR:

1. **Auto-merge with no owner reviewer.** A project sets `auto_merge_mode` to `all`, but leaves `owner_reviewer_login` blank. Every individual field is valid. Yet for human-authored PRs, `owner_approved?` (`app/temporal/activities/scan_paid_prs_activity.rb:2445`) can never be satisfied (it requires an `APPROVED` review from `owner_reviewer_login`), so human PRs never auto-merge — they silently stall. Nothing warns the operator.

2. **Runner pinned to an outdated model.** A runner's `tier_models` points at a model id that the provider has since deprecated, that Paid's catalog has marked `active: false`, or that a newer sibling in the same tier supersedes. Existing detection is either reactive (`Models::DetectBrokenRunnerModels` scans *failed* runs) or catalog-wide (`Models::DetectContractDrift` scans the whole catalog × every runner). There is no **per-runner, proactive** check that says "this specific runner is pointed at something stale."

Paid needs a single, configuration-aware system that inspects these settings together, finds the gaps that no single model validation can catch, and surfaces them as actionable findings — proactively, before they become failed agent runs or silently stalled PRs.

## Context

### Current Architecture

- **Single-field validation is strong.** `Project` enforces `allowed_github_usernames_not_empty` (`project.rb:1912`), `owner_reviewer_login_is_trusted` (`:1586`), `exactly_one_github_credential` (`:290`), `review_settings_valid` (`:1625`), and per-method rules in `validate_review_methods_config` (`:1758`) — including that the `paid_agent` review method requires the paid-code-reviewer bot to be configured (`:1790`, delegating to `Github::ReviewBotInstallationToken.configured?`). `UserSetting` validates runner fallback chains, default runners, and resource limits.
- **Effective-settings resolution is centralized.** `Project#effective_review_settings` (`:1011`), `Project#effective_quality_gate_settings` (`:916`), and `Automation::Configuration::Project.from(project)` (`app/services/automation/configuration/project.rb:14`) deep-merge defaults so reading code never hand-parses jsonb. `Project#effective_owner` (`:490`) resolves the owning `User` whose runner fleet and user settings apply.
- **Model resolution is centralized.** `Runners::ResolveTierModel` (`app/services/runners/resolve_tier_model.rb:15-34`) resolves a runner's model per tier through a 4-level priority chain; `Runners::ModelCompatibility` (`app/services/runners/model_compatibility.rb`) is the single compatibility contract; `Runners::DefaultTierModelIds` knows the current best model per tier.
- **Existing detection is reactive or catalog-wide.** `Models::DetectBrokenRunnerModels` reacts to failed runs; `Models::DetectContractDrift` (RDR-040) scans the whole catalog against every runner contract; `Models::DetectCatalogDrift` diffs the catalog against the RubyLLM registry. All run through the daily `ModelHealthCheckJob` and file a single `model-health` GitHub issue (`Models::FileModelHealthIssue`).
- **A soft-warning precedent exists.** `Configuration::Profiles::Base#prerequisites_for` (`app/services/configuration/profiles/base.rb:51`) returns human-readable unmet-prerequisite strings rather than raising — e.g. `Configuration::Profiles::TeamReviewed` warns when `owner_reviewer_login` is blank or the review bot is unconfigured.
- **A mature notification pipeline exists.** `Notification` (`app/models/notification.rb`) carries `severity` (info/warning/error), a polymorphic `subject`, and a dedup `source`. `Notifications::Publish` is the write path; `Notifications::Rule` (`app/services/notifications/rule.rb`) is the rule-driven auto-resolving variant — `detect(scope)` returns matched subjects, `build(subject)` produces notification attrs, and `call` publishes for matched subjects while auto-resolving notifications for subjects no longer flagged.

### Observed Gaps

The following cross-field misconfigurations are **not** caught by any existing validation or detector:

1. `auto_merge_mode != "off"` with blank `owner_reviewer_login` — human PRs can never satisfy `owner_approved?`.
2. Review enabled + bot configured globally but **not installed on the repo** — surfaces only as a runtime 422 in `RequestReviewActivity` (`app/temporal/activities/request_review_activity.rb`).
3. A runner whose resolved tier model is `active: false` (retired), `expired?`, `below_quality_bar?`, or dropped from the provider registry — no per-runner proactive check exists.
4. An `api_key` runner with neither `provider_api_key` nor `integration_credential` set.
5. A user with zero `kept_only.for_agent_runs` runners, or whose `default_agent_runner` / fallback chain references a discarded/disabled runner.
6. A confidential/restricted project resolved to a free model with `data_training_risk: possible` (the `Guardrails::DataClassificationPolicy` warns *during* a run; a health check would warn *before*).

These are exactly the gaps a configuration health check should fill.

## Recommendation

Introduce a **health-check framework**: a small set of value objects (`Finding`, `Result`, `Check`) plus a registry and coordinator, with one file per concrete check. Each check is mechanically simple — it reads resolved settings through the existing effective-settings/model-resolution services and emits `Finding` value objects. The framework is deliberately **not** semantic-reasoning code (Zero Framework Cognition): quality judgments stay delegated to the existing services it wraps; the checks only encode "do these settings add up?" structural rules.

Checks run on a **scheduled daily sweep per account** (the source of truth) and write their `Result` to a cache that a dedicated **health-check page** reads. Findings flow into the existing `Notification` pipeline via a generic `Notifications::Rule` adapter so they **auto-resolve** when the underlying check comes back clean.

The framework reuses, and does not duplicate: `Automation::Configuration::Project`, `Runners::ResolveTierModel`, `Runners::ModelCompatibility`, `Models::DetectCatalogDrift`, `Github::ReviewBotInstallationToken`, and the `Notification` / `Notifications::Rule` infrastructure.

## Proposed Design

### Data model (value objects)

Three co-located, immutable value objects under `app/services/health_checks/`:

```ruby
# A single detected problem. Stable :code is the dedup/auto-resolve key.
Finding = Data.define(:code, :scope, :severity, :title, :description,
                      :remediation, :action_url, :subject_type, :subject_id,
                      :metadata) do
  SEVERITIES = %i[info warning error].freeze   # mirrors the Notification enum
end

# Aggregate of one coordinator run.
Result = Data.define(:findings, :checked_at, :duration_ms) do
  def healthy?     = findings.none? { |f| f.severity == :error }
  def warnings?    = findings.any? { |f| f.severity == :warning }
  def for_scope(s) = findings.select { |f| f.scope == s }
  def counts       = findings.group_by(&:severity).transform_values(&:count)
end

# One check. Subclasses implement #call(subject) -> [Finding] (empty = pass).
class Check
  def self.code     = name.demodulize.underscore.to_sym
  def self.scope    = raise NotImplementedError    # :project | :user | :runner
  def self.network? = false                          # marks checks that hit GitHub / registry
  def call(subject) = raise NotImplementedError
end
```

This shape matches the established `Data.define` Result convention (`Guardrails::DataClassificationPolicy::Result` at `app/services/guardrails/data_classification_policy.rb:8-24`). The stable `:code` is the join key to `Notification#source` (same dedup idea as the `Models::FileModelHealthIssue` fingerprint).

### Check catalog (v1)

Each check is one file under `app/services/health_checks/checks/<scope>/`.

**Project scope** (6):

| Check | Severity | Detects | Reuses |
|---|---|---|---|
| `AutoMergeWithoutOwner` | error | `auto_merge_mode != "off"` AND `owner_reviewer_login` blank | `Project#auto_merge_enabled?`; logic at `scan_paid_prs_activity.rb:2445` |
| `ReviewWithoutBot` | error | review enabled + `paid_agent` method enabled AND `Github::ReviewBotInstallationToken.configured?` false | validation at `project.rb:1790` |
| `ReviewBotNotInstalled` | warning (**network**) | review enabled + bot configured but bot not installed on the repo | GitHub API; mirrors `code_scanning_permission_error_at` backoff precedent (`db/schema.rb` ~:1976) |
| `EmptyAllowlist` | error | `allowed_github_usernames` empty | `Project#allowed_github_usernames` (defensive; also a model validation) |
| `MissingGitHubCredential` | error | neither `github_token` nor `github_installation` set | `exactly_one_github_credential` |
| `SensitiveDataFreeModel` | warning | confidential/restricted project resolved to a free model with `data_training_risk: possible` | `Guardrails::DataClassificationPolicy` logic |

**Runner scope** (7) — iterate `project.effective_owner.runners.kept_only.for_agent_runs`:

| Check | Severity | Detects | Reuses |
|---|---|---|---|
| `InactiveModel` | error | resolved tier model has `active: false` (retired) | `Runners::ResolveTierModel`, `LlmModel#active` |
| `ExpiredModel` | warning | resolved model `expired?` | `LlmModel#expired?` |
| `BelowQualityBarModel` | warning | resolved model `below_quality_bar?` | `LlmModel#below_quality_bar?` |
| `DeprecatedModel` | warning (**network**) | resolved model dropped from the RubyLLM registry | `Models::DetectCatalogDrift#deprecated_models_for` |
| `IncompatibleModel` | error | resolved model hard-incompatible with the runner contract | `Runners::ModelCompatibility` (treat `nil` as pass, matching existing permissiveness) |
| `MissingRunnerCredentials` | error | `api_key` runner with no `provider_api_key` AND no `integration_credential` | `Runner#effective_api_secret` |
| `SupersededModel` | info | newer sibling exists in same provider+tier with higher `capability_score` | `LlmModel` catalog query |

**User scope** (3):

| Check | Severity | Detects | Reuses |
|---|---|---|---|
| `NoAgentRunners` | error | zero `kept_only.for_agent_runs` runners | `Dashboard::RunnerHealth` scope |
| `InvalidFallbackChain` | warning | `runner_selection_mode` references disabled/discarded runners | `UserSetting#validate_fallback_runners` |
| `MissingDefaultRunner` | warning | `default_agent_runner` set to a discarded/disabled runner | `UserSetting#validate_default_agent_runner` |

The runner's example ("runner configured for an older out-of-date model") maps to `InactiveModel` + `DeprecatedModel` + `SupersededModel` — three severity tiers from "won't run" through "provider deprecated it" to "a newer one exists." The auto-review/auto-merge example maps to `AutoMergeWithoutOwner` + `ReviewWithoutBot` (+ `ReviewBotNotInstalled`).

### Coordinator and registry

```ruby
# app/services/health_checks/coordinator.rb
module HealthChecks
  class Coordinator
    def self.call(scope:, subject:, include_network: false) = new(...).call
    def call
      checks = Registry.for_scope(scope).select { |c| include_network || !c.network? }
      findings = checks.flat_map { |check| run_safely(check, subject) }  # isolated
      Result.new(findings:, checked_at: Time.current, duration_ms: ...)
    end
    # A raising check becomes an internal-error Finding instead of failing the run.
  end
end
```

`Coordinator.call(scope: :project, subject: project, include_network: true)` composes all three scopes: it runs the project checks on the project, the runner checks over `project.effective_owner.runners.kept_only.for_agent_runs`, and the user checks over `project.effective_owner`, aggregating everything into one `Result`. So a project's health report spans "project, user, and runner settings" in one view, as requested.

### Execution model

**Scheduled daily sweep is the source of truth.** `AccountHealthCheckSweepJob` (queue `:maintenance`, `GoodJob::ActiveJobExtensions::Concurrency` with `key: "account_health_sweep"`, capped at 1):

```
under TenantContext.with_system_access:
  Project.includes(:effective_owner).find_each do |project|
    Cache.write(project, Coordinator.call(scope: :project, subject: project, include_network: true))
  end
  Notifications::Rule.evaluate_all(account:)   # drives publish + auto-resolve
  log message: "project_health.sweep_completed", ...
```

**Network checks run only in the job path** (never synchronously in a request). The health-check page always reads the cached `Result`. A per-project on-demand `ProjectHealthCheckJob` (queue `:default`, concurrency key per project id) backs the page's "Re-run checks" button: it recomputes one project, writes the cache, and the page refreshes via Turbo.

### Notification auto-resolve

Rather than one hand-written `Notifications::Rule` subclass per check, a single generic adapter binds any `Check` class into a rule:

```ruby
# app/services/health_checks/notifications/rule_adapter.rb
module HealthChecks::Notifications
  class RuleAdapter < Notifications::Rule
    def self.for(check_class) = Class.new(self) { define_singleton_method(:check_class) { check_class } }
    def detect(scope)   # account -> projects where the check fires
      Project.where(account: scope).select { |p| check_class.new.call(p).any? }
    end
    def build(subject)  # project -> notification attrs from the finding
      finding = check_class.new.call(subject).first
      { severity: finding.severity, title: finding.title, description: finding.description,
        action_url: project_health_check_path(subject), nav_section: "projects",
        source: "health_check_#{finding.code}", metadata: finding.metadata }
    end
  end
end
```

Registered once per check at boot. `Notifications::Rule#call` handles publish-on-fire and auto-resolve-on-clean, so no new reconciliation code is written. One finding → one notification per `(project, code)`; source-keyed dedup means a re-sweep updates rather than stacks.

### Frontend (dedicated page only)

`GET /projects/:id/health` reads `Cache.read(project)` and renders the stored `Result`:

- Standard `mx-auto max-w-7xl` container, `content_for(:title)`, back-link (matches `convention_settings/index.html.erb`).
- Summary header: green/amber/red badge from `result.counts`; "Last checked" timestamp; "Re-run checks" button (Turbo, enqueues `ProjectHealthCheckJob`, shows a spinner frame then refreshes).
- Findings grouped by scope (Project / Runners / User), each rendered by `_finding.html.erb`: severity icon, title, description, remediation hint, and an `action_url` deep-link ("Fix review settings" → the relevant settings tab).
- Empty state: a green "All checks passed" card.
- A single "Health" link in the project sub-nav (not an inline banner) is the entry point.

Route — `resource :health_check, only: [:show], controller: "projects/health_check"` plus `post :refresh, on: :member`, nested under `resources :projects`. This deliberately avoids the top-level `/up` and `/health/*` routes, which are reserved for unauthenticated infrastructure probes (`config/routes.rb:13-16`, `app/controllers/health_controller.rb`).

### Schema

**None required.** All checks read existing columns; `Notification` records use the existing `notifications` table; the cache uses the existing `Rails.cache`. This is a pure services + controllers + views + jobs addition.

## Alternatives Considered

### Alternative 1: Extend model validations only

Add more `validate` callbacks to `Project` / `UserSetting` to catch the cross-field gaps (e.g. block save when `auto_merge_mode != "off"` and `owner_reviewer_login` is blank).

Rejected as the primary design. Validations are hard gates: they prevent save and surface as form errors. Several target cases are not "invalid" so much as "suboptimal or about to break" (a deprecated model, a bot not installed on the repo, a superseded model). Hard-blocking saves would be hostile and would not help existing records that are already misconfigured. A health check is a read-only, advisory layer that operates over the live state including records created before any new rule existed.

### Alternative 2: Ad-hoc checks scattered per feature

Each feature (auto-merge, review, runner fleet) grows its own warning banner or notification when it detects its own misconfiguration.

Rejected. This duplicates detection logic across features, produces inconsistent severity/severity taxonomies and UI surfaces, and makes "show me everything wrong with this project" impossible without a cross-cutting layer. The framework's value is the single registry and the uniform `Finding` shape.

### Alternative 3: Fold the checks into the existing `ModelHealthCheckJob`

Extend the existing daily model-health sweep and its single filed GitHub issue to also cover project/user configuration.

Rejected. `ModelHealthCheckJob` and `Models::FileModelHealthIssue` are account-scoped and file a consolidated `model-health` GitHub issue — an operator-facing artifact aimed at model/runner correctness. Project configuration health is a different audience (the project owner, in-app) with a different surface (a per-project page + in-app notifications) and a much wider scope than models. Coupling them would overload the model-health issue and force one severity taxonomy onto unrelated concerns. The two systems coexist: the health check *reuses* `DetectCatalogDrift` as one input among many.

### Alternative 4: On-demand checks only (no scheduled sweep)

Run checks live when the page is visited, with no background job.

Rejected. With network checks in scope (review-bot-installed-on-repo, registry drift), a synchronous page render would hit GitHub and the registry on every load — untenable under rate limits and latency budgets. The scheduled sweep is the single source of truth; the page reads a cache.

## Trade-offs and Consequences

### Positive Consequences

- Cross-field misconfigurations surface proactively, before they become failed runs or silently stalled PRs.
- A single registry + uniform `Finding` shape make "show me everything wrong" trivial and make adding a new check a one-file change.
- Findings auto-resolve through the existing `Notifications::Rule` pipeline — no manual dismissal burden, no stale warnings.
- The system is purely advisory and read-only, so it cannot break existing configurations and works against records created before any rule existed.

### Negative Consequences

- Daily sweep cost grows with the number of projects × runners; network checks add GitHub/registry load. Must be monitored and rate-limited (concurrency cap of 1 per account, network checks behind the `include_network` flag).
- A check that raises is contained (becomes an internal-error finding), but a subtly *wrong* check could emit false positives at scale. Each check needs a tight spec covering both the broken and the healthy state.
- The advisory layer overlaps conceptually with model validations; the boundary rule (validations = hard save-time gates; health checks = read-only advisory over live state) must be respected to avoid drift between the two.

### Risks and Mitigations

- **Risk**: Sweep cost / API rate limits.
  - **Mitigation**: `:maintenance` queue with concurrency cap of 1; network checks only in the job path; cache the `Result`; reuse the registry-fetch caching already present in `Models::DetectCatalogDrift`.
- **Risk**: False positives erode trust.
  - **Mitigation**: Permissiveness where the underlying service is permissive (treat `ModelCompatibility` `nil` as pass, matching RDR-040); severity tiers (info vs warning vs error) so "newer model available" never reads as "broken."
- **Risk**: Check logic drifts from the real dispatch/merge logic.
  - **Mitigation**: Checks must delegate to the same effective-settings/model-resolution services the live code uses (`Automation::Configuration::Project`, `Runners::ResolveTierModel`, etc.), never re-implement them.
- **Risk**: Naming collision with infrastructure health probes.
  - **Mitigation**: Project-scoped route under `projects/health_check`; leave `/up` and `/health/*` to `HealthController`.

## Implementation Plan

The work is broken into phased issues hanging off a tracking (umbrella) issue. Issues use explicit `Depends on #...` lines so auto-pick honors the order. Parallelizable phases are grouped; each phase references this RDR.

1. **Core framework** — `Finding`, `Result`, `Check` base, `Registry`, `Coordinator` (with check isolation), `Cache`. Specs for the framework itself. *No upstream dependencies.*
2. **Project-scope local checks** — `AutoMergeWithoutOwner`, `ReviewWithoutBot`, `EmptyAllowlist`, `MissingGitHubCredential`, `SensitiveDataFreeModel`. *Depends on the core framework.*
3. **Runner-scope local checks** — `InactiveModel`, `ExpiredModel`, `BelowQualityBarModel`, `IncompatibleModel`, `MissingRunnerCredentials`, `SupersededModel`. *Depends on the core framework.*
4. **User-scope local checks** — `NoAgentRunners`, `InvalidFallbackChain`, `MissingDefaultRunner`. *Depends on the core framework.*
5. **Network checks** — `ReviewBotNotInstalled` (GitHub API), `DeprecatedModel` (registry diff via `DetectCatalogDrift`). *Depends on the core framework.*
6. **Health check page + on-demand job** — controller, routes, `show` view + partials, `Cache.read`, `refresh` action + `ProjectHealthCheckJob`. *Depends on project + runner local checks.*
7. **Scheduled sweep job** — `AccountHealthCheckSweepJob` (daily cron, `:maintenance`, concurrency cap, writes cache, structured log). *Depends on network checks + the page's job pattern.*
8. **Auto-resolving notifications** — `RuleAdapter`, boot-time registration, integration with `Notifications::Rule.evaluate_all`. *Depends on the scheduled sweep.*
9. **Closeout audit (umbrella)** — verify the shipped implementation matches this RDR; update the RDR `Status` to `Implemented`. *Depends on all phases.*

Phases 2–5 can proceed in parallel once the core framework lands.

## Validation

### Tests

- One spec per check (`spec/services/health_checks/checks/**/*_spec.rb`): factory the subject in the broken state, assert the `Finding`; factory it in the healthy state, assert `[]`. Network checks stub the GitHub client / registry fetch.
- Coordinator spec: assert scope composition (a `:project` run includes runner + user findings), and that a raising check becomes an internal-error finding rather than failing the run.
- `RuleAdapter` spec: assert publish-on-fire and resolve-on-clean via the existing `Notifications::Rule` spec harness.
- Job specs: assert cache is written, the structured `message: "project_health.sweep_completed"` log is emitted, and the concurrency key is set.
- A system spec for the page: renders cached findings grouped by scope, "Re-run" enqueues the job, empty state renders when healthy.

### Operational Checks

- After rollout, a representative misconfigured project (auto-merge on, no owner reviewer) produces an error finding on its health page within one sweep cycle.
- A deprecated runner model produces a warning finding and a corresponding auto-resolving notification.
- Sweep duration and GitHub/registry API usage are monitored; the concurrency cap holds.
- Resolving a misconfiguration causes its notification to auto-resolve on the next sweep without manual dismissal.

## Decision

Proceed with the configuration health-check framework: a `Finding` / `Result` / `Check` registry coordinated into a cached `Result`, driven by a daily account sweep, surfaced on a dedicated project health page and through the existing auto-resolving notification pipeline. Keep the layer strictly advisory and read-only; delegate every setting/resolution/compatibility decision to the services the live code already uses. Do not extend model validations to cover these cross-field cases, and do not fold the checks into the model-health sweep.
