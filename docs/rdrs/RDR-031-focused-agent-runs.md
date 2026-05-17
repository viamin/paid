# RDR-031: Focused Agent Runs — Single-Problem-Per-Run Architecture

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-13
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: #1987 (foundation), #1988 (prompt scoping), #1989 (quality scoring)
- **Related RDRs**: RDR-013 (Code Quality & Backpressure), RDR-014 (Learned Orchestration), RDR-023 (Automation Modularization)

## Problem Statement

When an agent run encounters multiple classes of problems on a PR (failing CI workflows, code review comments, merge conflicts, linter errors, security findings), the current system bundles all of them into a single agent run and instructs the agent to fix everything in one pass. This causes:

1. **Lower quality per task** — The agent spreads attention across unrelated issues, producing shallower fixes for each
2. **Misattributed quality scores** — A run that successfully fixed CI gets penalized for unresolved review comments that were never its responsibility
3. **No per-problem-type effectiveness measurement** — Composite scores conflate unrelated concerns, making it impossible to tell whether CI fix quality is improving while review response quality is declining

Requirements:

- Agent runs should be scoped to a single class of problem per run
- Follow-up runs should be scheduled automatically for remaining problem classes
- Quality scoring should evaluate each run against its specific focus, not against all PR problems
- A run focused on CI fixes should receive high quality if CI passes, regardless of other PR issues
- Manual/quick runs should continue using the current all-in-one approach
- The system must be backward compatible and rollout gradually via feature flag

## Context

### Current Behavior

The PR scanner (`ScanPaidPrsActivity`) collects all triggers for a PR and bundles them into a single agent run. The prompt builder (`Prompts::BuildForPr`) includes all applicable sections unconditionally:

1. Merge conflicts
2. CI failures (with logs, error output, workflow YAML)
3. Issue implementation gaps
4. Code review threads
5. Conversation comments

The priority list in the rendered prompt template (`coding.pr_review_rebase`) instructs the agent to "Work through the priorities above in order" — attempting all of them.

Quality scoring uses fixed weights per goal type. All `create_pr` runs share the same weight profile regardless of what they're actually fixing:

| Metric | Weight |
|--------|--------|
| `pr_created` | 0.25 |
| `pr_merged` | 0.25 |
| `ci_passed` | 0.15 |
| `iterations` | 0.10 |
| `agent_rerun_count` | 0.10 |
| `review_comment_count` | 0.05 |
| `lint_clean` | 0.05 |
| `tests_pass` | 0.05 |

A `ci_fix` run gets only 0.15 weight on `ci_passed` — the metric it should be judged on — while `pr_merged` (0.25) penalizes it for review comments that block merge but weren't its job.

### Technical Environment

- Scanner: `ScanPaidPrsActivity` collects triggers, `GitHubPollWorkflow` dispatches runs
- Prompt: `Prompts::BuildForPr` assembles sections, `coding.pr_review_rebase` template renders the instructions shell
- Quality: `QualityMetrics::Collect` builds scores, `QualityMetric` stores composite scores with goal-specific weights
- Feature flags: Flipper-based with per-project gating (`FeatureFlags`)

## Research Findings

### Investigation Process

1. Analyzed trigger collection in `ScanPaidPrsActivity` — 12+ trigger types, all bundled into one payload
2. Traced trigger-to-run flow through `handle_pr_trigger` → `start_draft_followup_workflow` / `start_pr_followup_workflow`
3. Examined `BuildForPr` section assembly — no focus/scoping parameter exists
4. Reviewed quality weight system in `QualityMetric::SCORE_WEIGHTS` and `GOAL_WEIGHTS`
5. Confirmed feature flag infrastructure supports per-project rollout

### Key Findings

- **Trigger types already encode problem class**: `ci_failure`, `review_threads`, `merge_conflicts`, `conversation_comments`, `actionable_labels` — the scanner already classifies problems; it just doesn't use that classification to scope runs
- **Priority ordering already exists**: merge conflicts > CI > issue gaps > reviews > comments — this becomes the focus priority
- **The `goal` field is orthogonal**: `goal` determines execution mode (create_pr vs review vs enhance_issue), not problem focus within a PR
- **Prompt has no scoping mechanism**: `BuildForPr` includes all applicable sections based on PR state, with no way to say "only address CI"
- **Quality weights are goal-level, not focus-level**: No way to say "for a CI-focused run, weight ci_passed at 0.50"

## Proposed Solution

### New Concept: `focus`

A new `focus` field on `agent_runs`, orthogonal to the existing `goal`. While `goal` determines *how* the agent executes (create code, review code, enhance issue), `focus` determines *what problem* the agent targets within a PR.

**Focus types:**

| Focus | Description | Primary Quality Signal |
|-------|-------------|------------------------|
| `ci_fix` | Fix failing CI checks | CI green after run |
| `review_feedback` | Address unresolved review threads/comments | Threads resolved |
| `merge_conflict` | Resolve merge conflicts | Conflicts resolved, rebase succeeds |
| `conversation` | Address trusted-human conversation comments | No new actionable comments |
| `issue_implementation` | Close implementation gaps against linked issue | Issue requirements met |
| `label_action` | Handle actionable PR labels | Labels cleared |
| `general` | Default/unscoped (current behavior) | Current composite scoring |

### Design Decisions

1. **Focus selection is automatic** — The scanner picks the highest-priority trigger as the run's focus. Priority order: `merge_conflict` > `ci_fix` > `review_feedback` > `conversation` > `issue_implementation` > `label_action`. Manual override is available via API for explicit control.

2. **Focused prompts mention other issues as context** — The prompt includes a "Other Issues on This PR (Deferred)" section listing problems that are not the agent's responsibility, with an explicit instruction to ignore the "fix forward" directive for those unrelated problems. This prevents the agent from being surprised by failing CI when it's focused on review comments, and avoids accidentally regressing unrelated fixes.

3. **Quality weights are hard-coded per focus** — No per-project/account customization initially. Focus-specific weight maps replace the general `SCORE_WEIGHTS` for focused runs. Revisit configurability after validation.

4. **Runs are sequential** — One focused run per scan cycle. The next poll naturally schedules the next focused run for remaining issues. Parallel runs on the same PR would cause merge conflicts.

5. **`general` focus is preserved** — Manual quick runs and any run where the feature flag is disabled uses `general`, producing identical behavior to the current system.

### Architecture Changes

#### 1. Schema & Model

Add `focus` column to `agent_runs`:

```ruby
add_column :agent_runs, :focus, :string, limit: 50, default: "general", null: false,
  comment: "Scoped task focus: general, ci_fix, review_feedback, merge_conflict, conversation, issue_implementation, label_action"
add_index :agent_runs, :focus
```

Model constant and validation:

```ruby
FOCUSES = %w[general ci_fix review_feedback merge_conflict conversation issue_implementation label_action].freeze
validates :focus, presence: true, inclusion: { in: FOCUSES }
```

#### 2. Scanner — Focus Resolution

The scanner maps trigger types to focus types and selects the highest-priority one:

```ruby
TRIGGER_TO_FOCUS = {
  "merge_conflicts" => "merge_conflict",
  "ci_failure" => "ci_fix",
  "changes_requested" => "review_feedback",
  "review_threads" => "review_feedback",
  "review_bot_comments" => "review_feedback",
  "review_bot_threads" => "review_feedback",
  "conversation_comments" => "conversation",
  "actionable_labels" => "label_action"
}.freeze

FOCUS_PRIORITY = %w[merge_conflict ci_fix review_feedback conversation issue_implementation label_action].freeze
```

The resolved focus is included in the trigger payload and flows through the workflow to `CreateAgentRunActivity`, where it is persisted on the agent run.

When the feature flag `focused_agent_runs` is disabled for a project, the scanner defaults to `general`.

#### 3. Prompt Scoping

`BuildForPr` accepts a `focus:` parameter and conditionally includes/excludes sections:

| Focus | Sections Included |
|-------|-------------------|
| `ci_fix` | Task, CI Failures, Instructions, Service Env, Style Guide |
| `review_feedback` | Task, Code Review, Instructions, Service Env, Style Guide |
| `merge_conflict` | Task, Merge Conflicts, Instructions, Service Env, Style Guide |
| `conversation` | Task, Conversation, Instructions, Service Env, Style Guide |
| `issue_implementation` | Task, Issue Requirements, Instructions, Service Env, Style Guide |
| `general` | All applicable (current behavior) |

For focused runs, the priority list collapses to a single item (e.g., "1. Fix the failing CI checks on this PR"), and a new "Other Issues (Deferred)" section is appended:

```markdown
# Other Issues on This PR (Deferred)

This PR also has the following issues that are **not** your responsibility this run:
- failing CI checks
- unresolved code review comments

Ignore the "fix forward" directive for these unrelated problems. Follow-up runs will address them.
Do not attempt to fix these issues. Focus solely on the task described above.
```

#### 4. Focus-Scoped Quality Scoring

Focus-specific weight maps replace the general weights for focused runs:

```ruby
FOCUS_WEIGHTS = {
  ci_fix: {
    "ci_passed" => 0.50,
    "lint_clean" => 0.20,
    "tests_pass" => 0.20,
    "iterations" => 0.10
  },
  review_feedback: {
    "focus_resolved" => 0.60,
    "iterations" => 0.20,
    "lint_clean" => 0.10,
    "tests_pass" => 0.10
  },
  merge_conflict: {
    "focus_resolved" => 0.70,
    "ci_passed" => 0.15,
    "iterations" => 0.15
  },
  # ... similar for conversation, issue_implementation, label_action
}.freeze
```

A new `focus_resolved` metric (0.0 / 1.0) measures whether the focused issue was actually resolved. This is computed by the scanner on the next scan cycle by comparing PR state:

- For `ci_fix`: all CI checks green → 1.0 (deferred if checks still pending)
- For `review_feedback`: no unresolved threads → 1.0
- For `merge_conflict`: PR mergeable → 1.0
- For `conversation`: no actionable comment trigger → 1.0

The scanner writes `focus_resolved` back to the previous run's `QualityMetric`, recalculating the composite score with focus-specific weights.

#### 5. Feature Flag

A `focused_agent_runs` feature flag gates the entire system:

```ruby
focused_agent_runs: Definition.new(
  name: :focused_agent_runs,
  owner: "infrastructure",
  intent: "Enable focused agent runs that target a single class of PR issue per run, with focus-scoped quality scoring.",
  rollout_plan: "Enable per-project during validation, monitor quality scores by focus, then promote to default.",
  cleanup_criteria: "Remove when focused runs are the default and general focus is deprecated or removed."
)
```

When disabled, all runs use `focus: "general"` with current behavior unchanged.

### Implementation Plan

Three sequenced issues, each independently shippable:

#### Issue 1: Foundation — Focus field, feature flag, scanner focus resolution

- Migration: `focus` column on `agent_runs`
- `AgentRun` model: `FOCUSES` constant, validation, `focused?` predicate
- Feature flag: `focused_agent_runs` definition
- Scanner: `TRIGGER_TO_FOCUS`, `FOCUS_PRIORITY`, `resolve_focus`, include `focus` in trigger payloads
- Workflow: Pass `focus` through to `CreateAgentRunActivity`
- `CreateAgentRunActivity`: Extract and persist `focus`

**Risk**: Low — defaults to `"general"`, identical to current behavior.

#### Issue 2: Prompt scoping — Focused prompts + other-issues context

- `BuildForPr`: `focus` parameter, `include_section?` gating, `other_issues_context` section, `focused_priority` method
- `PreparePrPromptActivity`: Pass focus from agent run
- Prompt template: Inject focus context before instructions shell

**Risk**: Medium — changes prompt content, but only when focus is non-general (feature flag gated).

**Depends on**: Issue 1.

#### Issue 3: Focus-scoped quality scoring — Focus-specific weights + focus_resolved attribution

- `QualityMetric`: `FOCUS_WEIGHTS` map, `weights_for(focus:)` class method
- `QualityMetrics::Collect`: Branch on `agent_run.focused?`, use focus-specific weights
- Scanner: `record_focus_resolution` step at start of `scan_pr`, with CI pending deferral

**Risk**: Medium — changes quality score calculations, but only for focused runs.

**Depends on**: Issue 1. Can be developed in parallel with Issue 2.

### Dependency Graph

```
Issue 1 (foundation)
    ├── Issue 2 (prompt scoping)
    └── Issue 3 (quality scoring)  [parallel with 2]
```

## Alternatives Considered

### Alternative 1: Multiple focused runs in parallel

Queue one focused run per trigger class simultaneously. **Rejected** because parallel runs on the same PR branch would cause merge conflicts and race conditions. Sequential is simpler and safer.

### Alternative 2: Let the agent decide what to focus on via prompt instructions

Instead of restricting sections, include all sections but add a "Focus on X first" instruction. **Rejected** because the agent still sees all the context and tends to spread attention. Section exclusion is a stronger signal than priority ordering.

### Alternative 3: New goal types instead of focus

Add `ci_fix`, `review_feedback`, etc. as goals rather than a separate `focus` field. **Rejected** because `goal` determines execution mode (container vs non-container, review prompt vs PR prompt, issue creation flow). Mixing problem class into goal conflates two orthogonal concepts and would require duplicating execution logic for each problem class.

### Alternative 4: Prompt-only scoping without quality changes

Scope the prompt but keep current quality scoring. **Rejected** because it doesn't solve the quality attribution problem — a successful CI fix run would still get penalized for unresolved review comments.

## Trade-offs

### Positive

- **Higher quality per fix** — Agent focuses deeply on one problem class
- **Accurate quality measurement** — Scores reflect success at the actual task
- **Better diagnostics** — Can compare CI fix quality vs review response quality independently
- **Backward compatible** — Feature flag + `general` default preserves current behavior
- **Incremental rollout** — Per-project enablement allows validation before broad rollout
- **Simpler prompts** — Focused runs have shorter, clearer prompts

### Negative

- **More agent runs per PR** — A PR with 3 problem classes now requires 3 sequential runs instead of 1. This increases total cost and wall-clock time.
- **More prompt tokens for context** — The "other issues" section adds tokens, though this is small compared to the savings from excluding full CI logs or review threads.
- **Scanner complexity** — Focus resolution and `focus_resolved` attribution add logic to the already complex scanner.
- **CI timing edge case** — `focus_resolved` for `ci_fix` must defer if checks are still pending, potentially requiring multiple scan cycles before the metric is recorded.

### Risks

- **Run budget exhaustion** — Projects with tight `max_pr_followup_runs` limits may exhaust their budget before all problems are addressed. Mitigation: consider whether focused runs should count differently against the followup limit.
- **Quality pause false positives** — If early focused runs happen to be harder problem classes, initial quality scores may trigger pause. Mitigation: ensure rolling average requires minimum sample size (already enforced by `QualityPause::Check`).
- **Inter-run regressions** — A `review_feedback` run might break CI that was just fixed by a `ci_fix` run. Mitigation: the prompt includes context about other issues, and CI will be caught on the next scan cycle. Long-term, running lint/test before commit (already in the prompt) prevents most regressions.

## Validation

### Unit Tests

- Focus resolution logic: trigger-to-focus mapping, priority ordering
- Prompt section inclusion/exclusion by focus type
- Focus-specific weight selection
- `focus_resolved` metric computation for each focus type

### Integration Tests

- Full scan → focus assignment → prompt building pipeline with various trigger combinations
- Multi-problem PR: verify sequential focused runs are scheduled across scan cycles
- Quality metric flow: verify focused run gets `focus_resolved` score on next scan

### Backward Compatibility Tests

- Verify `focus: "general"` produces identical prompts to current behavior
- Verify quality scores are unchanged for general runs
- Verify feature flag disabled path is identical to current behavior

### Monitoring (Post-Rollout)

- Per-focus quality score distribution (ci_fix vs review_feedback vs general)
- Average number of runs per PR before all issues resolved
- Time-to-green-CI for ci_fix runs vs general runs
- Prompt token usage comparison (focused vs general)
