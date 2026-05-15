# RDR-023: Automation Modularization Architecture

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-15
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #1114, #1116
- **Related Tests**: N/A
- **Related RDRs**: [RDR-012](RDR-012-github-integration.md) (GitHub Integration), [RDR-022](RDR-022-auto-merge-pr-strategy.md) (Auto-Merge Strategy), [RDR-002](RDR-002-workflow-orchestration.md) (Workflow Orchestration)

## Problem Statement

Paid's four automation features — auto-pick, auto-continue, auto-review, and auto-merge — have grown organically alongside the system. Policy logic, provider integration, and workflow orchestration are interleaved within a small number of large files, most notably `ScanPaidPrsActivity` (~2,000 lines) and `GitHubPollWorkflow`. This coupling creates several problems:

1. **Policy changes require touching provider code.** Adding a review method or changing merge eligibility rules means editing activity files that also contain GitHub API calls and signal detection logic.
2. **Provider lock-in.** Repository access, work-item tracking, review submission, and merge execution all assume GitHub. Supporting a second provider (e.g., GitLab, Bitbucket) would require forking or heavily branching these files.
3. **Testing difficulty.** Unit-testing a policy decision requires stubbing provider responses deeply embedded in activity methods.
4. **Cross-automation coupling.** Auto-review scan results feed directly into auto-merge eligibility checks within the same method body, making it hard to reason about each automation independently.

This RDR defines a target architecture that separates automation policy from provider integration and workflow orchestration, and describes a phased migration path that preserves current behavior while extracting modules incrementally.

## Context

### Background

The automation system evolved through several phases:

- **Phase 1**: Label-based triggering via `LabelPolicy` — a GitHub label on an issue/PR triggers a single decision.
- **Phase 2**: Explicit PR decisions via `PullRequestEvaluator` — full PR scan results flow through the evaluator, producing multiple decisions per scan cycle.
- **Phase 3 (current)**: The `Automation::Decision` data class and `Automation::Result` provide a clean decision vocabulary, but the scan logic that feeds them remains monolithic.

### Current Architecture

```
┌─────────────────────────────────────────────────────┐
│  GitHubPollWorkflow (Temporal)                      │
│  ┌───────────────┐  ┌──────────────────────────┐    │
│  │DetectLabels   │  │ScanPaidPrsActivity       │    │
│  │Activity       │  │  - draft scan            │    │
│  │  ┌──────────┐ │  │  - ready scan            │    │
│  │  │Evaluator │ │  │  - escalated scan        │    │
│  │  │ ├─Issue  │ │  │  - signal detection      │    │
│  │  │ └─PR     │ │  │  - review method checks  │    │
│  │  └──────────┘ │  │  - merge eligibility     │    │
│  └───────────────┘  │  - GitHub API calls      │    │
│                     └──────────────────────────────┘ │
│  ┌───────────────┐  ┌──────────────────────────┐    │
│  │QueueAgentRun  │  │MergePullRequest          │    │
│  │Activity       │  │Activity                  │    │
│  └───────────────┘  └──────────────────────────┘    │
└─────────────────────────────────────────────────────┘

┌─────────────────────┐  ┌─────────────────────────┐
│ Issues::AutoPick    │  │ ProcessRunQueueJob       │
│ (Service)           │  │ (GoodJob)                │
└─────────────────────┘  └─────────────────────────┘
```

Key observations:

- `ScanPaidPrsActivity` mixes signal detection (GitHub API), policy evaluation (review phase rules), and side effects (label management, phase transitions).
- `Issues::AutoPick` is already a well-isolated service but hard-codes GitHub issue semantics.
- `Automation::Decision` and `Automation::Result` provide a clean boundary between evaluation and execution — this pattern should be extended.
- Provider calls (Octokit) are scattered across activities rather than behind adapter interfaces.

### Terminology

| Term | Definition |
|------|-----------|
| **Automation** | A named capability that acts on work items without human intervention (auto-pick, auto-continue, auto-review, auto-merge). |
| **Policy** | The rules that decide *whether* and *when* an automation should act. Pure logic, no I/O. |
| **Signal** | An observable fact gathered from external systems (CI status, review state, label presence). |
| **Decision** | A value object describing an action the system should take (already exists as `Automation::Decision`). |
| **Provider** | An external system adapter that reads signals and executes side effects (GitHub, GitLab, etc.). |
| **Strategy** | A pluggable policy implementation for a specific automation area. |

## Proposed Solution

### Layered Architecture

The target architecture separates concerns into four layers:

```
┌─────────────────────────────────────────────────┐
│ Layer 4: Orchestration (Temporal / GoodJob)      │
│   Workflows, activities, jobs — scheduling and   │
│   durable execution only. No policy logic.       │
├─────────────────────────────────────────────────┤
│ Layer 3: Automation Strategies                   │
│   Pure policy: given signals, produce decisions. │
│   One strategy module per automation area.       │
├─────────────────────────────────────────────────┤
│ Layer 2: Signal Collection                       │
│   Gathers signals from providers into a          │
│   provider-neutral signal set for strategies.    │
├─────────────────────────────────────────────────┤
│ Layer 1: Provider Adapters                       │
│   Thin wrappers around external APIs.            │
│   Repository, WorkItem, Review, Merge adapters.  │
└─────────────────────────────────────────────────┘
```

Data flows top-down for reads (orchestration triggers signal collection, which calls providers) and bottom-up for writes (decisions flow up to orchestration, which calls providers to execute side effects).

### Layer 1: Provider Adapters

Provider adapters encapsulate all external-system I/O behind capability-oriented interfaces. Each interface defines a narrow contract that strategies and signal collectors depend on.

```ruby
# app/adapters/repository_adapter.rb
module Adapters
  module RepositoryAdapter
    # Read operations
    def fetch_pull_request(repo:, number:)    # => PullRequestData
    def fetch_check_suites(repo:, ref:)       # => [CheckSuiteData]
    def fetch_combined_status(repo:, ref:)    # => CombinedStatusData
    def fetch_pull_request_files(repo:, number:) # => [FileData]

    # Write operations
    def merge_pull_request(repo:, number:, method:, sha:) # => MergeResult
    def add_labels(repo:, number:, labels:)
    def remove_label(repo:, number:, label:)
    def create_comment(repo:, number:, body:)
    def mark_ready_for_review(repo:, number:)
  end
end

# app/adapters/work_item_adapter.rb
module Adapters
  module WorkItemAdapter
    def fetch_issue(repo:, number:)           # => IssueData
    def list_issues(repo:, filters:)          # => [IssueData]
    def fetch_issue_comments(repo:, number:)  # => [CommentData]
    def fetch_issue_timeline(repo:, number:)  # => [TimelineEvent]
  end
end

# app/adapters/review_adapter.rb
module Adapters
  module ReviewAdapter
    def fetch_reviews(repo:, pr_number:)      # => [ReviewData]
    def fetch_review_comments(repo:, pr_number:) # => [ReviewCommentData]
    def request_reviewers(repo:, pr_number:, reviewers:) # => void
    def submit_review(repo:, pr_number:, body:, event:)  # => ReviewData
  end
end
```

**Implementation approach**: A single `Adapters::GitHub` class implements all three interfaces, backed by Octokit. Future providers implement the same interfaces. Adapter selection is driven by `Project#provider_type` (defaulting to `:github`).

**Data objects**: Adapter methods return plain data objects (Ruby `Data.define` classes) rather than raw API responses. These data objects form the stable contract between layers.

```ruby
# app/adapters/data/pull_request_data.rb
module Adapters
  module Data
    PullRequestData = Data.define(
      :number, :title, :state, :draft, :mergeable,
      :head_sha, :head_ref, :base_ref,
      :author_login, :labels, :created_at, :updated_at
    )
  end
end
```

### Layer 2: Signal Collection

Signal collectors translate raw provider data into a provider-neutral signal set that strategies consume. This layer exists so strategies never touch provider APIs directly.

```ruby
# app/services/automation/signals/pull_request_signals.rb
module Automation
  module Signals
    PullRequestSignals = Data.define(
      :pr_number, :head_sha, :draft, :mergeable, :labels,
      :author_login, :base_ref, :head_ref,
      :ci_status,          # :pending | :success | :failure | :error
      :ci_check_details,   # [CheckDetail]
      :reviews,            # [ReviewSignal]
      :review_threads,     # [ThreadSignal] — unresolved threads
      :conversation_comments, # [CommentSignal]
      :last_agent_run,     # AgentRunSignal | nil
      :pr_review_phase,    # :draft | :ready | :escalated | :merged
      :draft_review_count,
      :pr_followup_count,
      :review_goal_retry_count,
      :auto_continue_paused
    )
  end
end

# app/services/automation/signals/collector.rb
module Automation
  module Signals
    class Collector
      def initialize(repository_adapter:, review_adapter:)
        @repository_adapter = repository_adapter
        @review_adapter = review_adapter
      end

      def collect_pr_signals(project:, issue:)
        pr_data = repository_adapter.fetch_pull_request(
          repo: project.github_repo_full_name,
          number: issue.pull_request_number
        )
        reviews = review_adapter.fetch_reviews(
          repo: project.github_repo_full_name,
          pr_number: issue.pull_request_number
        )
        # ... assemble PullRequestSignals from provider data + DB state
        PullRequestSignals.new(...)
      end
    end
  end
end
```

### Layer 3: Automation Strategies

Each automation area has a strategy that receives signals and produces decisions. Strategies are pure policy — no I/O, no database writes, no API calls. This makes them trivially testable.

#### Auto-Pick Strategy

```ruby
# app/services/automation/strategies/auto_pick.rb
module Automation
  module Strategies
    class AutoPick
      def initialize(project:)
        @project = project
      end

      # Given a set of candidate issues and project state,
      # returns a Decision (queue_create_pr_run or noop).
      def evaluate(candidates:, active_pr_count:, budget:)
        return Decision.noop unless project.auto_pick_enabled?
        return Decision.noop if active_pr_count >= project.max_concurrent_prs
        return Decision.noop if budget.exceeded?

        issue = select_next(candidates)
        return Decision.noop unless issue

        Decision.queue_create_pr_run(issue_id: issue.id)
      end

      private

      def select_next(candidates)
        # Priority: priority label tier first, then by
        # github_number ascending (FIFO — oldest first).
        # (Extracted from current Issues::AutoPick logic)
      end
    end
  end
end
```

#### Auto-Continue Strategy

```ruby
# app/services/automation/strategies/auto_continue.rb
module Automation
  module Strategies
    class AutoContinue
      def initialize(project:)
        @project = project
      end

      # Given PR signals, decides whether to queue a follow-up run.
      def evaluate(signals:)
        return Decision.noop if signals.auto_continue_paused
        return Decision.noop if followup_limit_reached?(signals)

        triggers = detect_followup_triggers(signals)
        return Decision.noop if triggers.empty?

        Decision.queue_create_pr_run(
          issue_id: signals.issue_id,
          source_pull_request_number: signals.pr_number
        )
      end

      private

      def detect_followup_triggers(signals)
        # CI failure, review threads, conversation comments,
        # changes requested, merge conflicts, review bot comments
      end

      def followup_limit_reached?(signals)
        signals.pr_followup_count >= @project.max_pr_followup_runs
      end
    end
  end
end
```

#### Auto-Review Strategy

```ruby
# app/services/automation/strategies/auto_review.rb
module Automation
  module Strategies
    class AutoReview
      def initialize(project:)
        @project = project
      end

      # Given PR signals and review config, decides review actions.
      def evaluate(signals:)
        case signals.pr_review_phase
        when :draft    then evaluate_draft(signals)
        when :ready    then evaluate_ready(signals)
        when :escalated then evaluate_escalated(signals)
        else Result.noop
        end
      end

      private

      def evaluate_draft(signals)
        decisions = []

        if needs_review_bot_request?(signals)
          decisions << Decision.request_review(
            pr_number: signals.pr_number,
            reviewers: [project.review_bot_request_login]
          )
        end

        if needs_paid_agent_review?(signals)
          decisions << Decision.queue_review_run(
            issue_id: signals.issue_id,
            source_pull_request_number: signals.pr_number
          )
        end

        if all_reviews_clean?(signals) && !draft_review_limit_reached?(signals)
          decisions << Decision.mark_ready(
            issue_id: signals.issue_id,
            pr_number: signals.pr_number,
            owner_reviewer_login: project.owner_reviewer_login
          )
        end

        Result.new(decisions: decisions.presence || [Decision.noop])
      end

      # ... evaluate_ready, evaluate_escalated follow similar pattern
    end
  end
end
```

#### Auto-Merge Strategy

```ruby
# app/services/automation/strategies/auto_merge.rb
module Automation
  module Strategies
    class AutoMerge
      def initialize(project:)
        @project = project
      end

      # Given PR signals, decides whether to merge.
      def evaluate(signals:)
        return Decision.noop unless project.auto_merge_enabled?
        return Decision.noop unless merge_preconditions_met?(signals)

        Decision.merge(
          issue_id: signals.issue_id,
          pr_number: signals.pr_number
        )
      end

      private

      def merge_preconditions_met?(signals)
        signals.mergeable &&
          signals.ci_status == :success &&
          owner_approved?(signals) &&
          all_blocking_reviews_complete?(signals) &&
          !review_stale_for_head?(signals)
      end
    end
  end
end
```

#### Strategy Composition

A coordinator runs all applicable strategies for a record and merges their decisions:

```ruby
# app/services/automation/strategy_coordinator.rb
module Automation
  class StrategyCoordinator
    def initialize(project:)
      @project = project
      @strategies = {
        auto_review: Strategies::AutoReview.new(project:),
        auto_continue: Strategies::AutoContinue.new(project:),
        auto_merge: Strategies::AutoMerge.new(project:)
      }
    end

    def evaluate_pr(signals:)
      decisions = strategies.flat_map do |_name, strategy|
        strategy.evaluate(signals:).decisions
      end

      # Resolve conflicts: merge trumps continue, review gates continue
      resolve(decisions)
    end

    private

    def resolve(decisions)
      # If merge is decided, suppress continue/review decisions.
      # If review is pending, suppress continue decisions.
      Result.new(decisions: deduplicate_and_prioritize(decisions))
    end
  end
end
```

### Layer 4: Orchestration Integration

Orchestration (Temporal activities and GoodJob jobs) becomes a thin shell that:

1. Creates adapter instances for the project's provider.
2. Calls signal collectors.
3. Passes signals to strategy coordinator.
4. Executes the resulting decisions via provider adapters.

```ruby
# app/temporal/activities/scan_pr_activity.rb (simplified target)
class Activities::ScanPrActivity
  def execute(input)
    project = Project.find(input.project_id)
    issue = project.issues.find(input.issue_id)

    adapters = Adapters.for(project)
    signals = Automation::Signals::Collector.new(
      repository_adapter: adapters.repository,
      review_adapter: adapters.review
    ).collect_pr_signals(project:, issue:)

    result = Automation::StrategyCoordinator
      .new(project:)
      .evaluate_pr(signals:)

    result.to_h  # Returned to workflow for decision execution
  end
end
```

### Configuration Model

Current configuration is spread across `Project` columns, `review_settings` JSON, and `Issue` fields. The target architecture introduces value objects that normalize access:

```ruby
# app/models/automation/config.rb
module Automation
  class Config
    def initialize(project:)
      @project = project
    end

    def auto_pick = AutoPickConfig.new(project:)
    def auto_review = AutoReviewConfig.new(project:)
    def auto_merge = AutoMergeConfig.new(project:)
    def auto_continue = AutoContinueConfig.new(project:)
  end

  class AutoPickConfig < Data.define(:project)
    def enabled? = project.auto_pick_enabled?
    def max_concurrent_prs = project.max_concurrent_prs
    def excluded_labels = project.auto_pick_excluded_labels
    def trusted_usernames = project.trusted_github_usernames
  end

  class AutoReviewConfig < Data.define(:project)
    def enabled_methods = project.enabled_review_methods
    def max_draft_rounds = project.max_draft_review_rounds
    def max_review_goal_retries = project.max_review_goal_retries
    def termination_policy = project.review_termination_policy
    # ...delegates to review_settings JSON without exposing its shape
  end

  class AutoMergeConfig < Data.define(:project)
    def enabled? = project.auto_merge_enabled?
    def merge_method = project.merge_method
    def require_owner_approval? = project.owner_reviewer_login.present?
    def auto_fix_conflicts? = project.auto_fix_merge_conflicts?
    def semver_policy = project.auto_merge_semver_policy
  end
end
```

**What stays stable**: Column names on `Project` and `Issue`, the `review_settings` JSON schema, feature flag names. These are already widely used in UI, API, and database queries.

**What gets normalized**: Access patterns. Strategies receive config objects rather than reaching into `Project` directly. This decouples policy from the storage shape.

## Alternatives Considered

### 1. Event-Sourced Automation Engine

**Description**: Model all automation transitions as domain events, replay events to derive current state, and use event handlers for side effects.

**Pros**:

- Full audit trail of every automation decision.
- Time-travel debugging.
- Clean separation between state derivation and side effects.

**Cons**:

- Significant infrastructure investment (event store, projections, snapshots).
- Temporal already provides durable execution history — event sourcing adds a second history mechanism.
- Over-engineered for the current scale of four automation areas.

**Reason for rejection**: The benefits don't justify the complexity at current scale. The decision log (`Automation::Decision` objects serialized in Temporal history) already provides audit capability.

### 2. Generic Rule Engine

**Description**: Define automation rules as data (YAML/JSON/database records) interpreted by a general-purpose rule engine.

**Pros**:

- Non-developers could modify rules.
- New automations require no code changes.

**Cons**:

- Rule engines trade code complexity for configuration complexity.
- Debugging rule interactions is harder than debugging strategy classes.
- The current automation areas have distinct enough semantics that generic rules would lose clarity.
- Premature — the number of automation areas (4) doesn't justify a meta-framework.

**Reason for rejection**: Code-as-strategy is more maintainable and debuggable at the current number of automation areas. If automation count grows significantly (>8), this could be revisited.

### 3. Microservice Extraction

**Description**: Extract each automation area into its own service communicating via message queues.

**Pros**:

- Independent deployment and scaling.
- Hard boundaries between automations.

**Cons**:

- Operational overhead (deployment, monitoring, debugging) for four services.
- Distributed transaction complexity when automations interact.
- Premature — the system runs as a single Rails app with Temporal.

**Reason for rejection**: Module boundaries within the monolith achieve the same decoupling benefits without operational overhead.

## Trade-offs and Consequences

### Positive Consequences

- **Testability**: Strategies are pure functions from signals to decisions — unit tests need no API stubs.
- **Provider extensibility**: Adding a new provider (GitLab, Bitbucket) requires implementing adapter interfaces without touching policy code.
- **Readability**: Each automation area is a self-contained class with a clear `evaluate` entry point.
- **Gradual migration**: The architecture can be adopted one layer at a time without breaking existing behavior.

### Negative Consequences

- **Indirection**: Adding a layer between activities and provider calls increases the number of files to navigate.
- **Signal staleness**: Collecting signals into a snapshot means strategies operate on potentially stale data. This matches current behavior (scan results are point-in-time) but is worth noting.
- **Dual code paths during migration**: Until migration is complete, some code will live in the old location and some in the new.

### Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Behavior regression during extraction | Medium | High | Extract one strategy at a time; use integration tests comparing old/new decision output for the same inputs |
| Over-abstraction of provider interfaces | Low | Medium | Start with interfaces that match current GitHub usage; generalize only when a second provider is added |
| Signal collection performance | Low | Medium | Signal collection replaces existing API calls, not adds new ones; cache within scan cycle |
| Strategy interaction bugs (e.g., merge + review conflict) | Medium | Medium | Coordinator resolves conflicts with explicit priority rules; integration tests cover multi-decision scenarios |

## Implementation Plan

### Prerequisites

- Existing `Automation::Decision` and `Automation::Result` classes remain stable.
- `explicit_pr_automation_decisions` feature flag is fully rolled out (removes legacy label-only path).

### Phase 1: Provider Adapter Extraction

**Goal**: Extract GitHub API calls from activities into adapter classes behind interfaces.

1. Define adapter interfaces (`RepositoryProvider`, `WorkItemProvider`, `ReviewProvider`). — *Shipped as `Automation::Providers::*` in #1116.*
2. Define adapter data objects (`PullRequest`, `Review`, etc.). — *Shipped under `Automation::Providers::Data` in #1116.*
3. Implement a GitHub provider set backed by existing Octokit client usage.
4. Replace direct Octokit calls in `ScanPaidPrsActivity` and `MergePullRequestActivity` with provider calls.
5. Verify behavior parity via existing integration tests.

The interface code is placed under `app/services/automation/providers/` (rather than `app/adapters/` as originally sketched) so that the capability modules live alongside other automation namespaces (`Automation::Decision`, `Automation::Result`, `Automation::Strategies::*`). The term "provider" tracks the wording used in #1116 and avoids collision with the existing `::Provider` model, which models LLM providers.

**Files to create**:

- `app/services/automation/providers/repository_provider.rb`
- `app/services/automation/providers/work_item_provider.rb`
- `app/services/automation/providers/review_provider.rb`
- `app/services/automation/providers/resolver.rb`
- `app/services/automation/providers/data/*.rb` (data objects)
- `app/services/automation/providers/github/*.rb` (concrete provider implementations — not yet created)

**Files to modify**:

- `app/temporal/activities/scan_paid_prs_activity.rb`
- `app/temporal/activities/merge_pull_request_activity.rb`

**Rollback**: Adapter classes are additive. If issues arise, activities can bypass adapters and call Octokit directly (the original code path).

### Phase 2: Signal Collection Layer

**Goal**: Extract signal detection from `ScanPaidPrsActivity` into a signal collector.

1. Define `Automation::Signals::PullRequestSignals` data class.
2. Define `Automation::Signals::IssueSignals` data class.
3. Implement `Automation::Signals::Collector` that uses adapters + DB state to build signal sets.
4. Replace inline signal detection in `ScanPaidPrsActivity` with collector calls.

**Files to create**:

- `app/services/automation/signals/pull_request_signals.rb`
- `app/services/automation/signals/issue_signals.rb`
- `app/services/automation/signals/collector.rb`

**Files to modify**:

- `app/temporal/activities/scan_paid_prs_activity.rb` (remove signal detection methods)

### Phase 3: Strategy Extraction

**Goal**: Extract policy logic from `ScanPaidPrsActivity` and `PullRequestEvaluator` into per-automation strategy classes.

1. Extract auto-merge policy into `Automation::Strategies::AutoMerge`.
2. Extract auto-review policy into `Automation::Strategies::AutoReview`.
3. Extract auto-continue policy into `Automation::Strategies::AutoContinue`.
4. Refactor auto-pick: extract selection policy from `Issues::AutoPick` into `Automation::Strategies::AutoPick`, keeping the service as an orchestration wrapper. — *Shipped in #1122.* The strategy consumes project-level guard signals (`pr_attention_count`, `pr_attention_limit`) from `Automation::Context#metadata` and delegates data access to `Automation::Strategies::AutoPick::CandidateSource`. The default, GitHub-backed implementation (`DefaultCandidateSource`) holds the existing Postgres queries; alternate work-item providers can implement the interface without changing the policy layer.
5. Implement `Automation::StrategyCoordinator` for multi-strategy evaluation.
6. Wire strategies into activities via coordinator.

**Extraction order**: Auto-merge first (smallest, clearest preconditions), then auto-review (most complex, benefits most from isolation), then auto-continue, then auto-pick.

**Files to create**:

- `app/services/automation/strategies/auto_merge.rb`
- `app/services/automation/strategies/auto_review.rb`
- `app/services/automation/strategies/auto_continue.rb`
- `app/services/automation/strategies/auto_pick.rb`
- `app/services/automation/strategy_coordinator.rb`

**Files to modify**:

- `app/services/automation/pull_request_evaluator.rb` (delegate to strategies)
- `app/services/automation/issue_evaluator.rb` (delegate to auto-pick strategy)
- `app/services/issues/auto_pick.rb` (thin orchestration wrapper)
- `app/temporal/activities/scan_paid_prs_activity.rb` (simplified to orchestration shell)

### Phase 4: Configuration Normalization

**Goal**: Introduce config value objects that strategies consume instead of reaching into `Project` directly.

1. Implement `Automation::Config` and per-area config classes.
2. Update strategies to accept config objects.
3. Update project settings UI to use config objects for validation.

**Files to create**:

- `app/models/automation/config.rb`

**Files to modify**:

- Strategy classes from Phase 3

### Parity Verification Strategy

Each phase includes a verification step:

1. **Shadow mode**: Run new code path alongside old, log decision differences without acting on them.
2. **Decision comparison tests**: For a set of representative signal snapshots, assert old and new paths produce identical decisions.
3. **Feature-flag gating**: Each phase can be toggled per-project before full rollout.

## Validation

### Testing Approach

- **Unit tests for strategies**: Given signal fixtures, assert correct decisions. No stubs needed.
- **Unit tests for adapters**: Mock HTTP responses, assert correct data object construction.
- **Unit tests for signal collectors**: Given adapter responses + DB state, assert correct signal assembly.
- **Integration tests for coordinator**: Given signals, assert correct multi-strategy decision resolution.
- **End-to-end tests**: Existing activity specs continue to run, verifying the full pipeline.

### Test Scenarios

1. **Auto-pick with blocked dependencies**: Signals include open dependency → Decision.noop.
2. **Auto-review draft with clean bot review**: Signals show clean review, under draft limit → Decision.mark_ready.
3. **Auto-merge with failing CI**: Signals show CI failure → Decision.noop (no merge).
4. **Auto-continue with paused PR**: Signals show auto_continue_paused → Decision.noop.
5. **Multi-strategy conflict**: Auto-merge and auto-continue both trigger → merge wins, continue suppressed.
6. **Review-goal retry limit**: Signals show retry count at max → Decision.noop (no more retries).
7. **Provider adapter failure**: Adapter raises → activity handles error, no decision emitted.

### Performance Validation

- Signal collection should not add API calls beyond what `ScanPaidPrsActivity` already makes.
- Strategy evaluation is pure computation — sub-millisecond overhead.
- No new database queries; signal collectors use the same queries currently in activities.

## References

### Internal Documents

- [RDR-012: GitHub Integration Strategy](RDR-012-github-integration.md)
- [RDR-002: Workflow Orchestration](RDR-002-workflow-orchestration.md)
- [RDR-022: Auto-Merge PR Strategy](RDR-022-auto-merge-pr-strategy.md)

### Patterns

- Strategy Pattern — GoF (encapsulate interchangeable algorithms)
- Ports and Adapters (Hexagonal Architecture) — Alistair Cockburn
- Data Transfer Objects — Martin Fowler (adapter data classes)

## Notes

- This RDR intentionally avoids mapping every current method to its target location. The implementation agent should read the current code at extraction time rather than relying on line-level mappings that will drift.
- The provider adapter interfaces are designed for GitHub's capabilities. When a second provider is added, the interfaces should be reviewed and generalized — not before.
- `ScanPaidPrsActivity` will shrink dramatically but does not disappear. It remains the Temporal activity entry point, responsible for adapter instantiation and signal-to-decision orchestration.
- The `Automation::Decision` vocabulary (factory methods on the class) should not change. New decision types may be added, but existing ones are stable.
