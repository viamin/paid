# RDR-039: Exception Reporting via `exception_notification` Custom Notifier

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-30
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: P2
- **Related Issues**: #2395 (umbrella), #2388, #2389, #2390, #2391, #2392, #2393, #2394
- **Related RDRs**: [RDR-011](RDR-011-observability.md) (observability stack), [RDR-029](RDR-029-multi-tenancy-preparation.md) (tenant context propagation)

## Implementation Status

Implemented. Paid uses the `exception_notification` gem, a custom `Paid::ExceptionNotifier`, Rack middleware integration, ActiveJob terminal-failure notification, subsystem/project context for knowledge jobs, allowlisted issue filing, rate limits, and dashboard surfacing. The middleware placement intentionally differs from the draft text so production 500s are captured inside Rails exception handling.

## Problem Statement

Paid's exception handling pipeline (`ExceptionHandler::Handle`, `Fingerprinter`, `Classifier`, `IssueFiler`) is sound but reaches only one catch-site today — [app/services/knowledge/collector_runner.rb:130](../../app/services/knowledge/collector_runner.rb#L130). Most unhandled exceptions in jobs, controllers, and rake tasks never enter the pipeline at all.

Three gaps:

1. **No global capture.** Background-job and web-request exceptions bypass `ExceptionHandler::Handle` entirely. Issues that the pipeline would have filed are silently lost.
2. **No spam protection.** Every captured occurrence walks the full pipeline (fingerprint → classify → notify → potentially file). A new exception fingerprint that fires in a tight loop can flood GitHub with issues and — downstream — spawn unbounded auto-picked agent runs that burn LLM tokens.
3. **No external reporting path.** Paid-managed projects (e.g. hunthelper, which already uses `exception_notification` for email) have no way to report exceptions back to the Paid instance that manages them. Closing this loop is a longer-term goal, but the design needs to anticipate it.

Requirements:

- Adopt `exception_notification` as the capture mechanism so background-job and web-request exceptions flow into `ExceptionHandler::Handle` without per-callsite plumbing.
- Add a per-fingerprint occurrence rate limit that prevents repeated invocations from burning DB writes, GitHub API calls, or downstream agent runs.
- Add a subsystem allowlist controlling which captured exceptions are allowed to escalate to "file a GitHub issue." Start with a small allowlist (current coverage); expand deliberately.
- Keep the notifier's wire format stable enough that a future HTTP transport can reuse the same payload shape for cross-process reporting.

## Context

### Current Capture Surface

Today, the only path into `ExceptionHandler::Handle` is an explicit `report_exception` call in `Knowledge::CollectorRunner` that enqueues `HandleExceptionJob` with a serialized exception. Unhandled exceptions elsewhere — controllers, GoodJob workers, rake tasks — terminate normally and do not produce an `ExceptionIncident`.

### The Pipeline

```
HandleExceptionJob
   │
   ▼
ExceptionHandler::Handle.call(exception:, account:, context:)
   │
   ├─ Fingerprinter.call  ── SHA-256 over subsystem + class + normalized
   │                          message + first 5 backtrace frames
   ├─ Classifier.call     ── transient? → action: "logged"
   │                          otherwise → severity (p1/p2), action: "issue_filed"
   ├─ find_or_create_incident   (account-scoped dedup via fingerprint)
   ├─ file_or_update_issue      (IssueFiler — Octokit-only, no LLM)
   └─ notify_if_needed          (Notifications::Publish)
```

Key facts that shaped this RDR:

- **`IssueFiler` uses Octokit only.** No `agent_harness` call. Token cost of a spammy exception is not in the handler — it's in the *downstream* agent run that auto-picks the filed issue.
- **`Current.account` is reliable in both contexts.** [app/models/current.rb](../../app/models/current.rb) defines a `CurrentAttributes` instance, and [app/jobs/application_job.rb:16-25](../../app/jobs/application_job.rb#L16-L25) wraps every job in `with_tenant_context`, so the account is set per-request and per-job.
- **Cache store is Solid Cache** (DB-backed). A separate cache-based rate-limit counter is just another DB round-trip; the `exception_incidents` row already carries `occurrence_count` + `last_occurred_at` and can serve as the counter directly.
- **`exception_notification` is not yet in the Gemfile.** No competing error-reporting gem is in use.

### Allowlist Today

There is no allowlist. `Classifier` decides `action: "issue_filed"` vs `"logged"` based on transient-error patterns and subsystem-level severity defaults. Once the gem captures every job and request exception, the existing classifier rules would route a much larger volume to `issue_filed`. The allowlist exists to gate that expansion.

## Proposed Solution

### 1. Add `exception_notification` to the Gemfile

```ruby
gem "exception_notification", "~> 5.0"
```

No `exception_notification-rails` or UI dependency — only the core gem and our custom notifier.

### 2. Custom Notifier

New class `Paid::ExceptionNotifier` at [lib/paid/exception_notifier.rb](../../lib/paid/exception_notifier.rb), conforming to the gem's notifier contract (`def call(exception, options = {})`).

```ruby
# frozen_string_literal: true

module Paid
  class ExceptionNotifier
    DEFAULT_SUBSYSTEM = "general"

    def call(exception, options = {})
      data = options[:data] || {}
      account = data[:account] || Current.account
      return unless account

      extra_context = (data[:context] || {}).except(:subsystem, :project_id)
      context = {
        subsystem: data[:subsystem] || DEFAULT_SUBSYSTEM,
        project_id: data[:project_id]
      }.merge(extra_context)

      HandleExceptionJob.perform_later(
        exception_class: exception.class.name,
        exception_message: safe_message(exception).truncate(10_000),
        exception_backtrace: exception.backtrace&.first(20),
        account_id: account.id,
        context: context
      )
    rescue => e
      Rails.logger.error(
        message: "exception_notifier.notify_failed",
        original_exception: exception.class.name,
        notifier_error: e.message
      )
      nil
    end

    private

    def safe_message(exception)
      exception.message.to_s
    rescue
      "[#{exception.class.name} message raised]"
    end
  end
end
```

Properties:

- **Never raises.** The notifier itself cannot become a source of exceptions. Failure is logged and swallowed. Even a buggy `exception#message` cannot break the notifier — `safe_message` traps it.
- **Enqueues, doesn't execute.** The notifier returns immediately; the full pipeline runs asynchronously via `HandleExceptionJob` (which already exists). Web-request latency is unaffected.
- **Pulls tenant from `Current.account`.** Works in both web-request and ActiveJob paths because `Current.account` is set by `set_current_request_details` / `ApplicationJob#with_tenant_context`. `Current` does not currently define a `:project` attribute, so `project_id` must come from the caller's `data:` hash (typically the per-job `notification_subsystem`/`notification_project_id` declarations described in §6).
- **Pinned keys are not clobberable.** The merge order in the snippet strips `subsystem` and `project_id` from `data[:context]` before merging, mirroring [handle.rb:129-134](../../app/services/exception_handler/handle.rb#L129-L134) — a caller's `data[:context][:subsystem]` cannot override the deliberate subsystem decision.
- **Truncates at the boundary.** A pathological backtrace cannot enlarge job arguments past 20 frames.

### 3. Initializer

New `config/initializers/exception_notification.rb`:

```ruby
# frozen_string_literal: true

return if Rails.env.test?

ExceptionNotification.configure do |config|
  config.ignored_exceptions += %w[
    ActionController::RoutingError
    ActiveRecord::RecordNotFound
    ActionController::InvalidAuthenticityToken
    ActionController::BadRequest
  ]

  config.add_notifier :paid, Paid::ExceptionNotifier.new
end

Rails.application.config.middleware.insert_after(
  ActionDispatch::ShowExceptions,
  ExceptionNotification::Rack
)
```

The middleware must sit inside Rails exception handling so it catches app-raised exceptions *before* the error page renders. In the shipped implementation this means inserting `ExceptionNotification::Rack` *after* `ActionDispatch::ShowExceptions`, which places it closer to the app; `ShowExceptions` then rescues the re-raised exception and renders the response. `config.middleware.use` (which appends to the end) would not see app-raised exceptions and is incorrect here.

ActiveJob integration is enabled via a terminal-failure hook in `ApplicationJob`. Per-retry firing would 5x the capture volume on a 5-retry job and pollute the rate limiter. The hook reads per-job declared subsystem/project (see §6) and only fires after retries exhaust:

```ruby
class ApplicationJob < ActiveJob::Base
  class_attribute :notification_subsystem, default: "general"

  rescue_from(StandardError) do |exception|
    if executions >= self.class.max_attempts
      Paid::ExceptionNotifier.new.call(
        exception,
        data: {
          subsystem: self.class.notification_subsystem,
          project_id: notification_project_id
        }
      )
    end
    raise
  end

  # subclasses override to attach a project:
  def notification_project_id = nil
end
```

Subclasses set `self.notification_subsystem = "knowledge"` and override `notification_project_id` to point at the relevant project. Jobs without an override fall through to `"general"` — which is intentionally *not* in `ISSUE_FILING_ALLOWLIST`, so misattributed exceptions get recorded and notified but don't file GitHub issues.

### 4. Subsystem Allowlist

In `ExceptionHandler::Classifier`:

```ruby
ISSUE_FILING_ALLOWLIST = %w[
  knowledge
  agent_runs
  container_manager
  secrets_proxy
].freeze
```

In `ExceptionHandler::Handle#file_or_update_issue`, before delegating to `IssueFiler`:

```ruby
return unless Classifier::ISSUE_FILING_ALLOWLIST.include?(@subsystem)
```

**Seed rationale.** A naive "start small with current coverage" seed (`%w[knowledge]` only) would, once T3 opens global capture, silently suppress GitHub issue filing for `agent_runs`, `container_manager`, and `secrets_proxy` — the three p1 subsystems per `Classifier::SUBSYSTEM_SEVERITY`. Today those subsystems fail loudly into logs because nothing catches them; broadening capture without including them in the allowlist would turn loud failures into quiet incidents, which is the worst possible UX of this RDR. The seed therefore includes all p1 subsystems plus the historically-covered `knowledge`. P2 subsystems (`github_sync`, `general`) stay off the allowlist initially.

Effect: incidents outside the allowlist are still recorded, fingerprinted, deduped, and surfaced via `Notifications::Publish` — but no GitHub issue is filed. Adding a subsystem to the allowlist is a deliberate one-line change.

### 5. Rate Limits (Per-Fingerprint and Per-Account)

Two tiers, both checked at the *top* of `Handle#call`, before classifier or any other side-effect-producing work:

```ruby
RATE_LIMIT_THRESHOLD = 5
RATE_LIMIT_WINDOW = 1.hour
ACCOUNT_HOURLY_CAP = 500
```

**Order matters.** Account cap is cheaper to check first (single indexed count), so it short-circuits before the per-fingerprint lookup when an account is in flood. Per-fingerprint check follows, using the existing `exception_incidents` row as the counter (no new cache layer).

Restructured `Handle#call`:

```ruby
def call
  return account_cap_result if account_over_cap?

  fingerprint = Fingerprinter.call(exception: @exception, subsystem: @subsystem)
  existing = ExceptionIncident.find_by(account: @account, fingerprint: fingerprint)

  if existing && rate_limited?(existing)
    fast_path_increment(existing)
    return rate_limited_result(existing)
  end

  classification = Classifier.call(exception: @exception, subsystem: @subsystem)
  log_exception(classification)
  return logged_result(classification) if classification.action == "logged"

  incident = existing || create_incident(fingerprint, classification)
  existing && incident.record_occurrence!(new_context: occurrence_context)
  file_or_update_issue(incident, classification) if @project
  notify_if_needed(incident, classification)

  Result.new(success: true, incident: incident, action: incident.action_taken)
rescue IssueFiler::RetryableFilingInProgress
  raise
rescue => e
  # ... existing error handling
end

private

def account_over_cap?
  ExceptionIncident.where(account: @account)
    .where("last_occurred_at > ?", RATE_LIMIT_WINDOW.ago)
    .sum(:occurrence_count) >= ACCOUNT_HOURLY_CAP
end

def rate_limited?(incident)
  incident.last_occurred_at &&
    incident.last_occurred_at > RATE_LIMIT_WINDOW.ago &&
    incident.occurrence_count >= RATE_LIMIT_THRESHOLD
end

def fast_path_increment(incident)
  incident.record_occurrence!(new_context: occurrence_context)
  Rails.logger.warn(
    message: "exception_handler.rate_limited",
    fingerprint: incident.fingerprint,
    occurrence_count: incident.occurrence_count
  )
end

def account_cap_result
  Rails.logger.error(
    message: "exception_handler.account_cap_dropped",
    account_id: @account.id,
    exception_class: @exception.class.name
  )
  Result.new(success: true, action: "logged", message: "Account hourly cap exceeded")
end

def rate_limited_result(incident)
  Result.new(success: true, incident: incident, action: incident.action_taken,
    message: "Rate-limited (per-fingerprint cap)")
end
```

Properties:

- **Classifier doesn't run** for rate-limited captures or account-cap drops. Cheap, but more importantly: `log_exception` (which writes a structured log per occurrence) is skipped, so log volume during spam stays bounded.
- **Account cap drops with zero DB writes** past the limit. The cap check itself is one indexed sum query (`account_id` + `last_occurred_at` are both indexed per `db/schema.rb`).
- **Per-fingerprint fast-path still ticks `occurrence_count` and `last_occurred_at`** via `record_occurrence!`, so dashboards reflect spam volume.
- **No `throw`/`catch`.** Control flow is plain returns, idiomatic Ruby.

### 6. Retire `report_exception`

[app/services/knowledge/collector_runner.rb:130](../../app/services/knowledge/collector_runner.rb#L130) becomes a no-op once the ApplicationJob hook catches collector failures. Verify with `rg "report_exception" app lib` that no other callers exist; delete the wrapper.

Subsystem attribution moves into the job class via the `class_attribute` declared in §3:

```ruby
class RunCollectorsJob < ApplicationJob
  self.notification_subsystem = "knowledge"

  def notification_project_id
    arguments.first.is_a?(Hash) ? (arguments.first[:project_id] || arguments.first["project_id"]) : nil
  end
  ...
end
```

Each subsystem-owning job declares its own `notification_subsystem`; jobs that don't declare one default to `"general"` (deliberately *not* on the allowlist). This keeps subsystem strings out of the `ApplicationJob` super-class and avoids a central registry that would have to be updated for every new job.

### 7. Wire-Format Pin (for future external transport)

The `data:` hash passed into `Paid::ExceptionNotifier#call` defines the eventual external payload. Pin these keys in the RDR so external clients can match:

| Key | Type | Required | Notes |
|-----|------|----------|-------|
| `subsystem` | string | yes | Maps to `Classifier::SUBSYSTEM_SEVERITY` |
| `account` | Account | yes (internal) | Replaced by API-key auth in the external path |
| `project_id` | uuid | no | Resolved to a `Project` under the account |
| `context` | hash | no | Arbitrary JSON-safe metadata stored in `ExceptionIncident#context` |

External callers (phase 2) will POST these same fields plus `exception_class`, `exception_message`, `exception_backtrace`, and a project token. No restructuring will be needed; the controller deserializes into the same `HandleExceptionJob`.

## Alternatives Considered

1. **Wire `Rails.error.subscribe` instead of `exception_notification`.** Cleaner Rails-native API, no external dependency. Rejected because the longer-term goal includes external Paid-managed projects reporting in via the *same* notifier API — they will already be using `exception_notification` (hunthelper does), so adopting the gem's contract internally keeps a single mental model.

2. **Cache-based rate limit (Solid Cache counter).** Considered, then rejected. Solid Cache is DB-backed, so it's just another write. The existing `exception_incidents` row already carries `occurrence_count` and `last_occurred_at` — same information, no extra table.

3. **Per-account budget only, no per-fingerprint cap.** Simpler, but a single runaway fingerprint can still exhaust the budget and starve legitimate captures. Both limits in series is cheaper than either alone in the worst case.

4. **Allowlist as `Account`-scoped configuration in the database.** Rejected for phase 1. A class constant is auditable in git history, immune to misconfiguration during incidents, and trivial to grep. Revisit once external projects need their own allowlists.

## Trade-offs

### Positive

- One-line subsystem coverage. Adding exception reporting to a new area becomes `Paid::ExceptionNotifier.new.call(e, data: { subsystem: "..." })` or, for web requests, raising into the global Rack capture path instead of wiring a custom job + serializer.
- The pipeline is unchanged. `ExceptionHandler::Handle`, `Fingerprinter`, `Classifier`, `IssueFiler` keep their interfaces and tests.
- Token-spam exposure is bounded. A new fingerprint can file at most one issue per hour per account, and a runaway exception cannot exceed the per-account cap.

### Negative

- New gem dependency. `exception_notification` is widely used and stable, but adds a supply-chain surface.
- Allowlist enforces a deliberate rollout. Adding a subsystem requires a code change + review. This is the point, but it means new captured subsystems will sit in "incident recorded, no GitHub issue" mode until someone allowlists them. Surface this state clearly in the dashboard.
- Backtrace truncation happens once at the notifier and again at incident creation. The boundary cap (20 frames) must stay consistent across both call sites or one of them is dead code.

### Risks

- **GoodJob retry semantics.** If the rescue hook fires on every retry instead of terminal failure, a 5-retry job becomes 5 captures. Must verify and test.
- **Tenant context loss for top-level web errors.** If an exception fires before `Current.account` is set (e.g., in early Rack middleware), the notifier returns silently. Acceptable, but should be logged so we know how often it happens.
- **Sensitive data in messages/backtraces.** Out of scope for this RDR but flagged as a follow-up — `IssueFiler` posts raw messages into GitHub issues; a future secret-scrubber should sit between `Handle` and `IssueFiler`.

## Implementation Plan

Sub-tasks (each a separate child issue under the umbrella issue):

1. **Add `exception_notification` gem.** Update `Gemfile`, `bundle install`, lock file. No code change yet.
2. **Implement `Paid::ExceptionNotifier`.** New file at `lib/paid/exception_notifier.rb`. Unit tests covering: in-process enqueue path, missing account returns nil, internal exception swallowed.
3. **Initializer + middleware wiring + per-job subsystem declaration.** New `config/initializers/exception_notification.rb`. `ExceptionNotification::Rack` is inserted *after* `ActionDispatch::ShowExceptions`, which places it inside Rails exception handling so production 500s are notified before `ShowExceptions` renders the response. `ApplicationJob` gains a `class_attribute :notification_subsystem` (default `"general"`) and a terminal-failure-only `rescue_from` hook. Knowledge collector jobs set `self.notification_subsystem = "knowledge"`. Specs assert both terminal job failures and Rack/web-request exceptions land as `ExceptionIncident`s with the right account attribution.
4. **Add `ISSUE_FILING_ALLOWLIST` constant + gating in `Handle`.** Seed with `%w[knowledge agent_runs container_manager secrets_proxy]` (all current p1 subsystems plus historically-covered `knowledge`). Specs covering: allowlisted subsystem files issue; non-allowlisted subsystem records incident + notification but does *not* call `IssueFiler`.
5. **Add per-fingerprint and per-account rate limits.** Constants in `Handle`, fast-path in `find_or_create_incident`, structured warn/error logs on rate-limit hits. Specs covering: 5th occurrence files, 6th occurrence skips, 1-hour window resets, account-level cap drops cleanly.
6. **Retire `report_exception` in `Knowledge::CollectorRunner`.** Confirm via `rg` that no other callers exist. Migrate collector exception coverage to the GoodJob hook with `data: { subsystem: "knowledge", project_id: ... }`.
7. **Dashboard surfacing.** Add a "non-allowlisted incident" badge or filter in the existing exception-incidents view so we can see what would have been filed under broader allowlist coverage. (Smallest possible change — full UX is a follow-up.)

## Validation

Scenarios to exercise before marking the RDR Implemented:

- A handled GoodJob failure under an allowlisted subsystem produces an `ExceptionIncident` with `action_taken: "issue_filed"` and a GitHub issue.
- A handled GoodJob failure under a non-allowlisted subsystem produces an `ExceptionIncident` with `action_taken: "notified"` and no GitHub issue.
- A Rack/web-request exception produces an `ExceptionIncident` with `Current.account` correctly attributed.
- 50 identical exceptions in quick succession produce at most 5 full-pipeline runs in the first hour; the rest fast-path through `record_occurrence!`.
- 600 distinct exceptions for a single account in an hour: the first 500 record incidents; the rest are dropped with a structured `error` log.
- Removing the `report_exception` callsite does not regress incident creation for collector failures.
- `Paid::ExceptionNotifier#call` invoked with an exception of its own (mock) does not re-enter the notifier loop.

## Out of Scope (Future RDR)

- HTTP transport for external Paid-managed projects (e.g. hunthelper) — payload shape is pinned here, but the controller, Rack::Attack rules, project-token auth, and signed payloads are deferred to the external-reporting RDR.
- Secret scrubbing between `Handle` and `IssueFiler`.
- Per-account allowlist configuration in the database.
- Auto-pick gating for exception-derived GitHub issues (separate concern in the issue-routing layer).
