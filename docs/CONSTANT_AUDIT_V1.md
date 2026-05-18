# Constant Audit Report — Paid v1.0 Preparation

**Date**: 2026-05-12
**Scope**: All constants in `app/` (models, services, controllers, temporal activities/workflows, jobs, lib)
**Total cataloged**: ~700 constants across 216+ files

---

## Executive Summary

The codebase has four categories of constants:

1. **Fallback defaults for existing user settings** — working as intended, no action needed
2. **Hard-coded values that should become user settings for v1.0** — 20+ constants, mostly escalation thresholds, timeouts, and model defaults
3. **Redundant/duplicated constants** — 6 duplication patterns that should be consolidated
4. **Intrinsic hard-coded constants** — enum-like statuses, security patterns, protocol markers; correct as-is

---

## Category 1: Fallback Defaults for Existing User Settings

These already have user-configurable counterparts and serve as correct fallbacks. No action needed.

| Constant | Value | Location | User Setting |
|----------|-------|----------|-------------|
| `MAX_REVIEW_GOAL_RETRIES` | `3` | `scan_paid_prs_activity.rb:1416` | `review_settings.methods.paid_agent.termination.max_review_goal_retries` |
| `max_draft_review_rounds` (DB column) | `10` | `projects.max_draft_review_rounds` | Project setting |
| `DEFAULT_MAX_TOKENS_PER_RUN` | `10_000_000` | `agent_run.rb:96` | `tenant_settings.guardrails.max_tokens_per_run` |
| `DEFAULT_MAX_TOKENS_PER_RUN` | `10_000` | `knowledge_run.rb:9` | Knowledge-specific cap |
| `DEFAULT_FAILURE_THRESHOLD` | `5` | `github_health_state.rb:12` | `github_health_state.failure_threshold` |
| `DEFAULT_RECOVERY_TIMEOUT` | `300` | `github_health_state.rb:13` | `github_health_state.recovery_timeout` |
| `DEFAULT_WEIGHT` / `MAX_WEIGHT` | `1` / `1000` | `provider.rb:14-15` | `provider.weight` |
| `DEFAULT_COMPLEXITY_THRESHOLDS` | `{low_max: 3, mid_max: 7}` | `provider.rb:18` | `provider.complexity_thresholds` |
| `DEFAULT_WINDOW_SIZE` | `10` | `quality_threshold.rb:5` | Quality gate config |
| `DEFAULT_MIN_SAMPLE_SIZE` | `3` | `quality_threshold.rb:6` | Quality gate config |
| `DEFAULT_QUALITY_GATE_SETTINGS` | hash | `project.rb:89` | `project.quality_gate_settings` |

---

## Category 2: Hard-Coded Values That Should Become User Settings

### 2A. Escalation & Circuit Breaker Thresholds (Top Priority)

These directly impact when PRs get escalated to humans. Different teams have different tolerances.

| Constant | Value | Location | Justification |
|----------|-------|----------|---------------|
| `MAX_CONSECUTIVE_DRAFT_FAILURES` | `3` | `scan_paid_prs_activity.rb:316` | Teams with flaky CI need higher tolerance before escalation |
| `MAX_CONSECUTIVE_OPERATIONAL_FAILURES` | `3` | `scan_paid_prs_activity.rb:317` | Provider reliability varies by tier; some providers need more retries |
| `SCAN_STALENESS_MULTIPLIER` | `3` | `scan_paid_prs_activity.rb:27` | Multiplies `project.poll_interval_seconds` to determine re-scan ceiling. Low-activity repos waste API calls at current value |
| `CI_RETRY_COOLDOWN` | `30.minutes` | `scan_paid_prs_activity.rb:1047` | Some CI pipelines complete in 2 minutes; others take 20. Hard-coded value is a poor compromise |
| `CI_ACTION_DISPATCH_GRACE_PERIOD` | `2.minutes` | `scan_paid_prs_activity.rb:22` | Prevents duplicate CI dispatches; should scale with CI speed |
| `MAX_REVIEW_GOAL_RETRIES` | `3` | `scan_paid_prs_activity.rb:1416` | Already configurable per-project but used as default; consider raising default or making it tenant-level |

### 2B. Agent Execution Timeouts (Significant Impact)

These control when agent runs are killed. Complex tasks on large repos need more time.

| Constant | Value | Location | Justification |
|----------|-------|----------|---------------|
| `DEFAULT_ISSUE_GOAL_TIMEOUT` | `600` (10 min) | `run_agent_activity.rb:79` | Wall-clock timeout for issue implementation. Complex features need more time |
| `DEFAULT_ISSUE_GOAL_IDLE_TIMEOUT` | `120` (2 min) | `run_agent_activity.rb:80` | No-output detection. Large repos have slow file reads and tool calls |
| `DEFAULT_REVIEW_GOAL_IDLE_TIMEOUT` | `300` (5 min) | `run_agent_activity.rb:81` | Review of large PRs can stall at 5 minutes of silence |
| `DEFAULT_CREATE_PR_IDLE_TIMEOUT` | `300` (5 min) | `run_agent_activity.rb:82` | PR creation with complex git operations can stall |
| `DEFAULT_AGENT_STARTUP_TIMEOUT` | `300` (5 min) | `run_agent_activity.rb:83` | Cold starts on slow hardware / first-time setup |
| `STALE_CLAIMED_TIMEOUT` | `15.minutes` | `agent_run.rb:101` | Some agents legitimately claim and think for 15+ minutes |
| `STALE_PAUSED_TIMEOUT` | `2.hours` | `agent_run.rb:102` | Long-running debugging sessions may be paused intentionally |

### 2C. Model Defaults (Scattered Across 11+ Files)

The string `"claude-sonnet-4-6"` is repeated as `DEFAULT_MODEL` in 11 files. This should be a single canonical constant, and ideally configurable per-tenant.

**Files with `DEFAULT_MODEL = "claude-sonnet-4-6"`** (10 files):

- `decompose_feature_activity.rb:12`
- `enhance_issue_activity.rb:15`
- `analyze_issue_activity.rb:15`
- `analyze_knowledge_gaps_activity.rb:11`
- `style_guides/compress.rb:13`
- `style_guides/extract.rb:15`
- `strategy_evolution/mutate.rb:7`
- `prompt_evolution/mutate.rb:19`
- `llm/generate_pr_description.rb:21`
- `knowledge/decisions/draft.rb:27`
- `agent_runs/diagnose_error.rb:12`

**Files with `DEFAULT_MODEL = "claude-haiku-4-5-20251001"`** (2 files):

- `llm/generate_issue_title.rb:14`
- `models/meta_agent_selector.rb:7`

### 2D. Queue & Container Management

| Constant | Value | Location | Justification |
|----------|-------|----------|---------------|
| `MAX_STARTS_PER_PERFORM` | `20` | `process_run_queue_job.rb:27` | Large teams need higher throughput |
| `MAX_ITERATIONS_PER_PERFORM` | `100` | `process_run_queue_job.rb:32` | Scaling bottleneck for active projects |
| `DEFAULT_RETENTION_HOURS` | `4` | `retain_container_activity.rb:14` | Cost-sensitive teams want shorter retention; slow teams want longer |
| `MAX_CONSECUTIVE_FAILURES` | `3` | `process_run_queue_job.rb:22` | Breaker for queue processing; should scale with reliability |

---

## Category 3: Redundant / Duplicated Constants (Cleanup Candidates)

### 3A. `POSITIVE_REACTIONS` / `NEGATIVE_REACTIONS`

The arrays `%w[+1 heart hooray rocket]` and `%w[-1 confused]` are defined **independently** in 3 files. Four other files correctly reference the canonical source.

**Canonical source**: `quality_metrics/collect_reaction_feedback.rb:17-18`
**Duplicates** (should reference canonical):

- `llm_output_metrics/collect_pr_description_feedback.rb:20-21`
- `llm_output_metrics/collect_issue_title_feedback.rb:18-19`

**Already correct** (references canonical):

- `quality_metrics/collect_review_reaction_feedback.rb:15-16`
- `quality_metrics/collect_issue_feedback.rb:15-16`
- `quality_metrics/collect_enhance_issue_feedback.rb:8-9`

### 3B. `PAID_ESCALATED_LABEL = "paid-escalated"`

Defined identically in 2 files:

- `scan_paid_prs_activity.rb:42`
- `mark_escalated_activity.rb:9`

Should be extracted to a shared location (e.g., `Issue::PAID_ESCALATED_LABEL` or a dedicated constants module).

### 3C. `MUTATION_TIMEOUT = 120`

Identical value in 3 workflow files:

- `coordination_policy_evolution_workflow.rb:5`
- `strategy_evolution_workflow.rb:5`
- `prompt_evolution_workflow.rb:26`

Should be defined once in `BaseWorkflow` or a shared module.

### 3D. `HEALTH_CHECK_TIMEOUT = 30` and `HEALTH_CHECK_INTERVAL = 1`

Identical in 2 provisioners:

- `containers/mcp_provisioner.rb:33-34`
- `containers/service_provisioner.rb:76-77`

Should be extracted to a shared container constants module.

### 3E. `COLLECTION_INTERVAL = 30.seconds` and `MAX_BACKOFF_INTERVAL = 5.minutes`

Identical in 2 jobs:

- `container_metrics_collection_job.rb:15-16`
- `service_container_metrics_collection_job.rb:13-14`

### 3F. `EXPECTED_MERGE_STATUSES = [405, 409, 422]`

Identical in 2 files:

- `dependabot_auto_merge_job.rb:26`
- `auto_release_evaluation_job.rb:24`

Should be a shared constant in a merge-related module.

---

## Category 4: Hard-Coded, Correct as-is

These define the system's domain vocabulary, protocols, and security posture. They should not be user-configurable.

### Domain Enums (~50 model files)

Status lists, type lists, phase lists in models like `AgentRun::STATUSES`, `Issue::PAID_STATES`, `Issue::PR_REVIEW_PHASES`, `Provider::DIRECT_OUTBOUND_API_PROVIDERS`, `AgentRun::GOALS`, etc.

### Protocol & Format Constants

- `PAID_REVIEW_CLEAN_MARKER` (`"<!-- paid-review-clean -->"`)
- `COMMENT_MARKER` strings across multiple activities
- `CONVENTIONAL_PATTERN` regex
- `PAID_READY_LABEL`, `PAID_AUTO_MERGED_LABEL`, other label name strings
- `FALLBACK_PROMPT` heredocs (prompt text, not configuration)

### Security Patterns

- `SECRET_PATTERNS`, `GITHUB_TOKEN_PATTERN`, `GITHUB_TOKEN_IN_TEXT`
- `SAFE_WORD_PATTERN` (path validation)
- `FORBIDDEN_BINARY_EXTENSIONS`, `FORBIDDEN_DIRECTORY_PREFIXES`
- Auth failure / rate limit regex patterns

### Bot Identity

- `KNOWN_BOT_PREFIXES`, `BODY_ONLY_REVIEW_BOT_LOGINS`, `PROVIDER_BOT_USERNAMES`
- `BOT_REVIEWER_LOGINS` in auto_review configuration

### SQL & Query Expressions

- `QUEUE_ORDER`, `QUEUE_PRIORITY_SQL`, `ADVISORY_LOCK_SQL`
- Queue ordering CASE expressions in `AgentRun`

### External API Constraints

- `DEFAULT_CHECK_RUNS_PER_PAGE = 100` (GitHub API max)
- `WORKFLOW_RUNS_PER_PAGE = 100`
- `DEFAULT_PER_PAGE = 100` (fetch_issues)

### Temporal Framework Constants

- `NO_RETRY`, `DEFAULT_RETRY_POLICY`, `RUN_AGENT_RETRY_POLICY` (Temporal retry policies)
- `KNOWN_FAILURE_TYPES`, `KNOWN_FAILURE_CLASSES`

### Event Type / Trigger Type Enums

- `PROGRESS_EVENT_TYPES`, `TURN_COMPLETE_EVENT_TYPES`, etc.
- `FOLLOWUP_TRIGGER_TYPES`, `POSTED_BOT_FEEDBACK_TRIGGER_TYPES`

---

## Recommended v1.0 Action Plan

### Phase 1: Quick Wins (deduplication, low risk)

| # | Task | Files Changed | Risk |
|---|------|---------------|------|
| 1 | Consolidate `POSITIVE_REACTIONS`/`NEGATIVE_REACTIONS` — make `collect_pr_description_feedback` and `collect_issue_title_feedback` reference `CollectReactionFeedback` | 2 | Low |
| 2 | Extract `PAID_ESCALATED_LABEL` to `Issue::PAID_ESCALATED_LABEL`, reference from `scan_paid_prs_activity.rb` and `mark_escalated_activity.rb` | 3 | Low |
| 3 | Extract `MUTATION_TIMEOUT` to `BaseWorkflow::DEFAULT_MUTATION_TIMEOUT` | 4 | Low |
| 4 | Extract `HEALTH_CHECK_TIMEOUT`/`HEALTH_CHECK_INTERVAL` to shared container module | 3 | Low |
| 5 | Extract `EXPECTED_MERGE_STATUSES` to shared module | 3 | Low |
| 6 | Extract `DEFAULT_MODEL = "claude-sonnet-4-6"` to single canonical `Provider::DEFAULT_MODEL` (or `Llm::DEFAULT_MODEL`), reference from all 11 files | 12 | Low |

### Phase 2: Configurable Escalation Thresholds (medium risk, high value)

| # | Task | Approach |
|---|------|----------|
| 7 | Make `MAX_CONSECUTIVE_DRAFT_FAILURES` configurable | Add to `project` settings or `review_settings.escalation`, default to current value (3) |
| 8 | Make `MAX_CONSECUTIVE_OPERATIONAL_FAILURES` configurable | Same location, default to 3 |
| 9 | Make `CI_RETRY_COOLDOWN` configurable | Add to `review_settings` or project settings, default to 30 minutes |
| 10 | Make `SCAN_STALENESS_MULTIPLIER` configurable | Add to project settings, default to 3 |

### Phase 3: Configurable Timeouts (medium risk, high value)

| # | Task | Approach |
|---|------|----------|
| 11 | Make `DEFAULT_*_TIMEOUT` constants in `run_agent_activity.rb` configurable per-project | Add timeout settings to project or tenant settings. These already have per-run override capability but no UI/config surface |
| 12 | Make `STALE_CLAIMED_TIMEOUT` and `STALE_PAUSED_TIMEOUT` configurable | Tenant-level settings with current values as defaults |
| 13 | Make `DEFAULT_RETENTION_HOURS` configurable | Tenant-level cost control setting |

### Phase 4: Nice-to-Have

| # | Task |
|---|------|
| 14 | Consolidate scattered `CACHE_TTL` values (14 files) into a dashboard cache configuration module |
| 15 | Make `MAX_STARTS_PER_PERFORM` / `MAX_ITERATIONS_PER_PERFORM` tenant-level settings for scaling |
| 16 | Make `DEFAULT_MODEL` fully configurable per-tenant (not just per-call) |

---

## Appendix: Full Constant Catalog

The complete inventory of all ~700 constants across 216+ files is available in the agent exploration task outputs stored in this session. Key groupings:

- **Models**: 297 constants across 72 files (mostly enum-like STATUSES, TYPES, PHASES)
- **Services**: 681 constants across 216 files (operational logic, thresholds, cache TTLs)
- **Temporal activities**: ~100 constants across 30+ activity files (timeouts, patterns, defaults)
- **Temporal workflows**: ~25 constants across 10 workflow files (retry policies, timeouts)
- **Jobs**: ~60 constants across 20+ job files (intervals, windows, thresholds)
- **Lib**: ~15 constants across 5 files (provider mappings, config)
- **Controllers**: ~30 constants across 12 files (rate limits, allowed endpoints)

---

## Agent Handoff Prompt

```markdown
## Task: Implement Constant Audit Recommendations for Paid v1.0

This is a continuation of the constant audit documented in `docs/CONSTANT_AUDIT_V1.md`. Read that file first for full context.

### What was done
- Cataloged all ~700 constants across `app/` (216+ files)
- Categorized into: fallback defaults, hard-coded that should be user settings, redundant duplicates, and correct-as-is
- Identified 6 duplication patterns and 20+ constants that should become user-configurable

### What to do next

#### Phase 1: Quick Wins (deduplication — start here)

1. **Consolidate `POSITIVE_REACTIONS`/`NEGATIVE_REACTIONS`**
   - Canonical: `app/services/quality_metrics/collect_reaction_feedback.rb:17-18`
   - Duplicates to fix: `app/services/llm_output_metrics/collect_pr_description_feedback.rb:20-21` and `collect_issue_title_feedback.rb:18-19`
   - Change these to reference `CollectReactionFeedback::POSITIVE_REACTIONS` / `NEGATIVE_REACTIONS` (pattern already used by 4 other files)

2. **Extract `PAID_ESCALATED_LABEL`**
   - Currently in `scan_paid_prs_activity.rb:42` and `mark_escalated_activity.rb:9`
   - `app/models/issue.rb` already has the label logic; add `PAID_ESCALATED_LABEL = "paid-escalated"` there and reference from both activities

3. **Extract `MUTATION_TIMEOUT`**
   - Currently in 3 workflows: `coordination_policy_evolution_workflow.rb:5`, `strategy_evolution_workflow.rb:5`, `prompt_evolution_workflow.rb:26`
   - Add `DEFAULT_MUTATION_TIMEOUT = 120` to `app/temporal/workflows/base_workflow.rb` and reference from the 3 files

4. **Extract `HEALTH_CHECK_TIMEOUT`/`HEALTH_CHECK_INTERVAL`**
   - In `containers/mcp_provisioner.rb:33-34` and `containers/service_provisioner.rb:76-77`
   - Extract to a shared module like `Containers::HealthCheckConstants`

5. **Extract `EXPECTED_MERGE_STATUSES`**
   - In `dependabot_auto_merge_job.rb:26` and `auto_release_evaluation_job.rb:24`
   - Extract to a shared constant

6. **Consolidate `DEFAULT_MODEL`** (biggest quick win — 11 files)
   - `"claude-sonnet-4-6"` is `DEFAULT_MODEL` in 10 files
   - `"claude-haiku-4-5-20251001"` in 2 files
   - Add `DEFAULT_PLANNING_MODEL = "claude-sonnet-4-6"` and `DEFAULT_LIGHTWEIGHT_MODEL = "claude-haiku-4-5-20251001"` to a single location (e.g., `app/models/llm_model.rb` or a new `app/services/llm/defaults.rb`)
   - Reference from all 12 files

#### Phase 2: Configurable Escalation Thresholds

After Phase 1 dedup is done, make these hard-coded thresholds configurable:

7. **`MAX_CONSECUTIVE_DRAFT_FAILURES`** (scan_paid_prs_activity.rb:316) — add to project settings or `review_settings.escalation`
8. **`MAX_CONSECUTIVE_OPERATIONAL_FAILURES`** (scan_paid_prs_activity.rb:317) — same location
9. **`CI_RETRY_COOLDOWN`** (scan_paid_prs_activity.rb:1047) — add to project or review settings
10. **`SCAN_STALENESS_MULTIPLIER`** (scan_paid_prs_activity.rb:27) — add to project settings

For each: add to the appropriate settings hash with current value as default, update the activity to read from settings with fallback to constant, add validation, update tests.

#### Phase 3: Configurable Timeouts

11. **Agent execution timeouts** in `run_agent_activity.rb` (lines 79-83): `DEFAULT_ISSUE_GOAL_TIMEOUT`, `DEFAULT_*_IDLE_TIMEOUT`, `DEFAULT_AGENT_STARTUP_TIMEOUT` — add to project/tenant settings
12. **Stale run timeouts** in `agent_run.rb:101-103`: `STALE_CLAIMED_TIMEOUT`, `STALE_PAUSED_TIMEOUT` — tenant-level
13. **Container retention** in `retain_container_activity.rb:14`: `DEFAULT_RETENTION_HOURS` — tenant cost control

#### Verification

After each phase:
- Run `bin/rspec` to verify no regressions
- Run `bin/lint` to check style
- Run `bin/lint --staged` before committing
- Follow Conventional Commits: `refactor(constants): ...`, `feat(settings): make X configurable`

#### Key Files to Read First

- `docs/CONSTANT_AUDIT_V1.md` — this full audit
- `app/temporal/activities/scan_paid_prs_activity.rb` — most escalation constants
- `app/temporal/activities/run_agent_activity.rb` — all timeout constants
- `app/models/agent_run.rb` — stale run constants
- `app/services/orchestration_strategies/defaults.rb` — existing defaults pattern
- `app/models/tenant_setting.rb` — where tenant-level defaults go
- `app/models/project.rb` — where project-level defaults go (DEFAULT_REVIEW_SETTINGS, DEFAULT_QUALITY_GATE_SETTINGS)
```
