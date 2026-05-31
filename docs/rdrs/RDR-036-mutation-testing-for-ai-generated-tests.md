# RDR-036: Mutation Testing for AI-Generated Tests (Mutant)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-25
- **Status**: Draft
- **Type**: Architecture
- **Priority**: P1
- **Related Issues**: (to be filed during planning)
- **Related RDRs**:
  - [RDR-013](RDR-013-code-quality-backpressure.md) (Code Quality and Backpressure)
  - [RDR-009](RDR-009-prompt-evolution.md) (Prompt Evolution)
  - [RDR-031](RDR-031-focused-agent-runs.md) (Focused Agent Runs)
  - [RDR-035](RDR-035-style-guide-evolution.md) (Style Guide Evolution)
- **Related Tests**: (to be created during implementation)

## Amendment 1 (2026-05-29)

### Decision

Paid switches the sanctioned mutation-testing source from `mbj/mutant` to the MIT-licensed `viamin/mutant` fork. Follow-on implementation is tracked in `viamin/paid#2367` (gem-source switch), `viamin/paid#2368` (`--usage` cleanup), and `viamin/paid#2370` (customer UI work).

### Rationale and trade-off

This amendment removes the customer commercial-license burden from the design. The trade-off is a weaker initial signal: `viamin/mutant` currently ships fewer modern mutation operators than upstream `mbj/mutant`, so early kill-rate coverage is less exhaustive. The project accepts that weaker signal in exchange for eliminating customer license-key setup, license-compliance UX, and split open-source/commercial execution paths.

### Switch blockers

The gem-source switch remains gated on the upstream `viamin/mutant` blockers tracked in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, and `viamin/mutant#12`. Compatibility follow-up for the Paid integration remains tracked in `viamin/mutant#16`.

## Problem Statement

LLM-generated tests are particularly susceptible to a class of pathology that is hard to catch with line/branch coverage:

- **Tautological assertions** — `expect(result).to eq(result)`, `expect(true).to be_truthy`.
- **Over-mocking** — the system-under-test is stubbed away so the test passes regardless of what the production code does.
- **Coincidental coverage** — a line is executed but no assertion actually depends on it; mutating the line still leaves all tests green.
- **Missing branches** — happy-path-only specs that pass even when the unhappy branch is silently broken.

These passes look healthy to RuboCop, RSpec, SimpleCov, and the existing `QualityMetrics::Collect` pipeline because all of those measure *something other than whether the test would notice a regression*. The result is that Paid agents (and the projects Paid manages) can ship "fully tested" code whose tests have no semantic teeth.

[Mutant](https://github.com/viamin/mutant) directly measures this. It mutates the production code under a subject and reports any mutation the test suite fails to kill. A surviving mutation is concrete evidence that the test is not actually exercising the behavior it claims to.

Two distinct surfaces need this:

1. **Paid itself** — a Rails 8 application whose security boundaries (trusted-comment filtering, RBAC, secrets proxy, tenant RLS) live in pure Ruby. A surviving mutation in these subjects is a real-world risk, not a stylistic concern.
2. **Paid-managed Ruby projects** — every Ruby repo Paid writes code in is also a repo Paid writes tests in. Mutation score is the most direct quantitative signal that the agent's tests are doing their job, and it is exactly the signal an LLM cannot fake by being verbose.

The requirement is to (a) introduce mutation testing into Paid's own CI with realistic runtime cost, (b) make it an opt-in pre-commit check that agents can run inside containers in customer Ruby projects, and (c) feed mutation kill-rate into Paid's `QualityMetric` pipeline so it can drive backpressure, gating, and prompt/style-guide evolution.

## Context

### Background

Mutation testing executes the test suite once normally, then re-runs it many times against a copy of the source where each "mutation" replaces an operator, removes a statement, or alters a return value. For every mutation:

- **Killed** — at least one test fails. Good: the suite noticed the change.
- **Alive** — every test still passes. Bad: either the test is missing or the original code is redundant (dead).

The kill rate (killed / total) is the *mutation score*. Unlike line coverage, mutation score cannot be gamed by writing assertion-free tests — those tests will not kill mutations.

Mutant is the selected Ruby implementation family. This RDR now assumes `viamin/mutant` as the sanctioned source, with the adoption blockers tracked in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, `viamin/mutant#12`, and `viamin/mutant#16`. It supports RSpec (`mutant-rspec`) and Minitest (`mutant-minitest`), runs Ruby 3.2–4.0 on Linux/macOS, forks a worker per CPU, and persists run results under `.mutant/results/` for incremental analysis.

Critical mechanics:

- **Subject expressions** — `Module::Class`, `Module::Class*` (recursive), `Module::Class#instance_method`, `Module::Class.class_method`, `descendants:ApplicationController`, `source:lib/**/*.rb`. CLI subjects override `.mutant.yml` `matcher.subjects`.
- **Incremental mode** — `--since git-reference` filters subjects to those whose line range overlaps a git diff hunk. Only catches *direct* changes; constant-edits that change behavior indirectly are missed.
- **Concurrency** — `-j N` forks N workers. Default is one per core. Rails apps with a shared Postgres need per-worker template databases or `--jobs 1`; the docs explicitly warn that sharing one SQLite file across workers corrupts results.
- **Limitations** — methods defined via `module_eval`/`class_eval`/`define_method`/`define_singleton_method` or string-eval cannot be mutated. This matters for Rails: a lot of metaprogramming-heavy code (concerns built via `included do`, ActiveSupport `delegate`, dynamically-defined attribute methods) is invisible to mutant. Plan subject selection around what is statically analyzable.
- **Licensing history** — Historical only after Amendment 1 (2026-05-29): ~~`--usage opensource` is free for open-source repos. Commercial use is `$30/month or $250/year per developer`. **Paid itself is open source**, so its own CI runs under `--usage opensource` at no cost. The license question only arises for *Paid-managed projects* whose source is commercial. Paid does not — and should not — hold mutant licenses on behalf of customers; the license belongs to the customer, the same way their GitHub PAT and LLM API credentials do.~~ Amendment 1 switches the sanctioned source to `viamin/mutant`, so Paid no longer designs around customer commercial-license handling.

### Technical Environment

- Rails 8 / PostgreSQL / GoodJob / Temporal.
- `agent-harness` is the only sanctioned LLM interface (RDR-007). Mutant does not involve LLM calls, so this constraint affects only the *feedback* step that surfaces mutant output into a prompt.
- Agent runs execute inside Docker containers with git worktrees (RDR-004, RDR-005).
- Pre-commit checks are modeled by `PreCommitRequirement` (`app/models/pre_commit_requirement.rb`) with `check_type` ∈ `{shell_command, test_suite, coverage, security_scan}` and `failure_behavior` ∈ `{block, warn, auto_fix}`, scoped account/user/project with resolution priority project > user > account.
- Hook installation in the agent container is handled by `Containers::QualityHooks` and `Containers::GitOperations`. Today it installs only `lint_command` and `test_command` from `Prompts::LanguageCommands::LANGUAGE_{LINT,TEST}_COMMANDS`.
- `QualityMetrics::Collect` is the canonical entry point for per-run automated metrics; outputs feed `QualityGateThreshold` evaluation, `QualityPause::Check`, and the prompt-evolution scoring in `PromptEvolution::Mutate`.
- The A/B-test infrastructure (`AbTest`, `AbTestVariant`, `AbTestAssignment`) and `RDR-035`'s style-guide variant are already wired to consume per-run quality scores.

### Current Gap

`QualityMetric` records `test_pass_rate`, `lint_pass_rate`, review reactions, and human feedback, but has no measure of *test efficacy*. A run that adds 800 lines of green-but-tautological RSpec scores identically to a run that adds 800 lines of genuinely-asserting RSpec. The optimization signal driving prompt and style-guide evolution is therefore blind to one of the most common LLM test-writing failure modes.

## Research Findings

### Why mutant over alternatives

| Tool | Status for Paid |
|------|------|
| **Mutant** (`viamin/mutant`) | Sanctioned source after Amendment 1. Native Ruby AST mutation, RSpec/Minitest support, incremental mode, structured output under `.mutant/results/`, with current adoption blockers tracked in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, `viamin/mutant#12`, and `viamin/mutant#16`. **Selected.** |
| **mutest** | Mutant fork. Less active. No clear advantage for our use. |
| **Stryker (Ruby port)** | Not maintained. |
| **PIT / Stryker JS / Cosmic Ray** | Wrong language. Relevant only if Paid expands beyond Ruby for managed projects — out of scope for this RDR. |
| **Property-based testing** (`rantly`, `prop_check`) | Complementary, not a substitute. Property tests find *missing* invariants; mutation tests find *weak* assertions on stated behavior. Could be a future RDR. |
| **Coverage-based gating** (SimpleCov) | Already easy to hit 100% with no real assertions. Coverage is necessary but not sufficient; this RDR addresses what coverage misses. |

### Runtime cost is the dominant design constraint

Mutant produces dozens to hundreds of mutations per method. A full-suite run on a non-trivial Rails app is *hours*, not minutes. This rules out:

- Running on every commit unconditionally.
- Running synchronously in the interactive agent loop without scope constraint.
- Running across the full codebase per PR.

It does **not** rule out:

- `--since` incremental runs scoped to the diff, which usually finish in seconds-to-minutes per PR.
- Nightly full sweeps as a background workflow.
- Targeted runs against a curated tier-1 subject list of security-critical or high-leverage code.

The design below assumes incremental-by-default and reserves full runs for offline cron.

### Rails / mutant integration realities

- **Database** — Rails specs need a database. Paid's container already provisions Postgres. Mutant parallel workers each need either an isolated template DB or sequential execution. Simplest first cut: `--jobs 1` for the in-container check, accept the runtime, scale via template DBs in a Phase 2.
- **Eager loading** — Mutant relies on constants being loaded. Rails autoloading interacts poorly. Standard fix: `Rails.application.eager_load!` in the spec helper or `requires:` block in `.mutant.yml`. Confirmed in mutant's Rails integration guide.
- **Metaprogramming blind spots** — Concern-heavy modules (`included do ... end`), ActiveRecord callbacks defined via DSL, and `delegate` chains are not mutated. This is a feature, not a bug, for our purposes: we want the score to reflect tests against *the code we wrote*, not framework glue.
- **Process forking** — Each mutation forks a fresh process. Rails boot cost dominates. Use the `--zombie` flag (load once, fork many) to amortize.

### Existing Paid hooks we can lean on

| Paid surface | What it gives us |
|---|---|
| `PreCommitRequirement` | First-class data model for opt-in per-project checks with `failure_behavior` ∈ `{block, warn, auto_fix}`. New `check_type: "mutation_test"` slots in cleanly. |
| `Containers::QualityHooks` | Already installs lint/test hooks into the worktree. Extension point for a third hook command. |
| `QualityMetrics::Collect` | Pipeline that runs after each agent run and produces a `QualityMetric` row. New `mutation_kill_rate` metric attaches here. |
| `PromptEvolution::Mutate` / `AbTests::RecordResult` | Already consume per-run quality scores. No changes needed if mutation score is just one more dimension of `QualityMetric`. |
| `QualityGateThreshold` / `QualityPause::Check` | Same — they read `QualityMetric`, so adding a new metric makes it gateable for free. |

## Proposed Solution

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  MUTATION TESTING IN PAID (mutant)                       │
│                                                                          │
│  LAYER A — Paid itself (same sanctioned viamin/mutant source)            │
│    ├─ .mutant.yml at repo root (rspec integration, eager_load)           │
│    ├─ CI job: mutant --since origin/main on PRs                          │
│    └─ Nightly GHA: full-suite mutant run, score published to dashboard   │
│                                                                          │
│  LAYER B — Paid-managed Ruby projects (per-project, opt-in)              │
│    ├─ PreCommitRequirement{check_type: "mutation_test"} record           │
│    │    ├─ command: "mutant run --since HEAD~1 --use rspec '<subjects>'" │
│    │    ├─ failure_behavior: "warn" (default) | "block" | "auto_fix"     │
│    │    └─ scope: account / user / project (existing resolution)         │
│    │                                                                     │
│    ├─ Containers::QualityHooks#install_quality_hooks installs the        │
│    │   mutant command as a third hook alongside lint/test                │
│    │                                                                     │
│    └─ Live mutations parsed from .mutant/results/ → structured prompt    │
│        snippet fed back to the agent as backpressure (one feedback loop  │
│        iteration, same as RuboCop/Brakeman in RDR-013).                  │
│                                                                          │
│  LAYER C — Quality signal (cross-cutting)                                │
│    ├─ QualityMetric#mutation_kill_rate populated by                      │
│    │   QualityMetrics::CollectMutationScore (called from Collect)        │
│    ├─ QualityGateThreshold can gate on mutation score                    │
│    └─ Prompt/style-guide evolution scoring includes mutation kill-rate   │
│        as one dimension of composite score                               │
└─────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Incremental-only in the agent loop.** Full runs are too slow to sit in a pre-commit hook. `--since HEAD~1` keeps the feedback loop bounded to the agent's own diff, which is exactly the surface we want to gate on anyway.
2. **`PreCommitRequirement` as the opt-in mechanism.** No new top-level configuration model. Customers already configure pre-commit checks per account/project; adding `mutation_test` as a `check_type` is one row, not a new subsystem.
3. **`warn` as the default `failure_behavior`.** Mutant findings are noisy on first adoption (many surviving mutations point at redundant production code that should be deleted, not at missing tests). Defaulting to `warn` lets agents and humans triage rather than blocking commits until the corpus is clean.
4. **Mutation score as one more `QualityMetric`, not a parallel pipeline.** The composite scoring, gating, pause-on-regression, prompt evolution, and style-guide evolution machinery already exists. Surfacing mutation score as a new column rather than a new framework means we get all of those behaviors for free.
5. **Licensing path (historical only after Amendment 1).** ~~Paid uses `--usage opensource`; customers bring their own license for commercial projects. Paid itself is OSS and runs mutant for free under the opensource usage flag. For Paid-managed projects whose source is *not* open source, the customer holds the commercial license. Paid never proxies, stores, or transmits a customer's mutant license — it lives in the customer's `Gemfile`, `MUTANT_LICENSE_KEY` env, or Rails credentials, exposed to the agent container the same way the customer's GitHub PAT and LLM API keys already are. This avoids both legal exposure for Paid and a secrets-proxy detour. The customer-facing setting form for the `mutation_test` requirement surfaces an "Is this project open source?" toggle that switches the rendered command between `--usage opensource` and `--usage commercial`.~~ Amendment 1 supersedes this with the `viamin/mutant` source switch and the cleanup tracked in `viamin/paid#2368`.
6. **Tier-1 subjects for Paid itself before whole-codebase ambition.** Security-critical modules first: `Prompts::BuildForIssue.fetch_trusted_comments`, `Prompts::BuildForPr.select_trusted_comments`, `TenantContext`, `SecretsProxyController` policy, `Pundit` policies for high-blast-radius models. Score these to 100% kill before expanding scope. This keeps the runtime budget honest and the signal-to-noise ratio high while `viamin/mutant` closes the blocker set in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, and `viamin/mutant#12`.

### Technical Design

#### 1. Configuration for Paid itself

`.mutant.yml` at repo root:

```yaml
integration:
  name: rspec
  arguments:
    - --fail-fast
    - --seed
    - '0'
requires:
  - ./config/environment
environment_variables:
  RAILS_ENV: test
includes:
  - lib
  - app
mutation:
  timeout: 10.0
jobs: 4
fail_fast: true
coverage_criteria:
  timeout: false
  process_abort: false
  test_result: true
matcher:
  subjects:
    - Prompts::BuildForIssue#fetch_trusted_comments
    - Prompts::BuildForPr#select_trusted_comments
    - TenantContext*
    - Pundit::Policy*
  ignore:
    - source:app/views/**/*
    - source:db/**/*
    - source:config/**/*
```

The subject list is the curated tier-1 surface. Expansion to `app/services/**` etc. is gated on (a) the tier-1 surface reaching 100% kill, and (b) the CI runtime budget for incremental runs staying under 5 minutes on a typical PR.

#### 2. CI workflow for Paid itself

New job `.github/workflows/mutation.yml`:

```yaml
name: Mutation
on:
  pull_request:
    branches: [main]
  schedule:
    - cron: '17 9 * * *'  # nightly full sweep

jobs:
  incremental:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    services:
      postgres: { image: postgres:16, env: { POSTGRES_PASSWORD: postgres } }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ruby/setup-ruby@v1
        with: { bundler-cache: true }
      - run: bundle exec rails db:test:prepare
      - name: Mutant (incremental)
        run: bundle exec mutant run --since origin/${{ github.base_ref }}

  full:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    # ...same setup, no --since, results posted to internal dashboard
```

Amendment 1 removes any separate usage-flag or license-key path from the target design. The local task and CI job should use the same sanitized `viamin/mutant` invocation once `viamin/paid#2367` and `viamin/paid#2368` land.

#### 3. PreCommitRequirement extension

```ruby
class PreCommitRequirement < ApplicationRecord
  CHECK_TYPES = %w[shell_command test_suite coverage security_scan mutation_test].freeze
  # ...existing code
end
```

Migration adds the new value; no schema change otherwise — `command`, `failure_behavior`, `auto_fix_command`, and `position` already model everything we need.

Seeded default for accounts that opt in after the gem-source switch in `viamin/paid#2367` and the `--usage` cleanup in `viamin/paid#2368`:

```ruby
PreCommitRequirement.create!(
  account: account,
  name: "mutation_test",
  command: "bundle exec mutant run --since HEAD~1 --use rspec --jobs 1",
  check_type: "mutation_test",
  failure_behavior: "warn",
  position: 30
)
```

Historical only after Amendment 1 (2026-05-29): ~~The `--usage` value is driven by the project's open-source flag (a new boolean on `Project`, defaulting to `false` for safety). For `--usage commercial`, the customer must expose a `MUTANT_LICENSE_KEY` env var to the container; Paid surfaces this as a required project credential in the settings UI and forwards it the same way it forwards other customer-provided env vars to agent containers. Paid never stores the key in its own credentials store.~~ The sanctioned `viamin/mutant` direction removes both the proposed `Project#open_source?` flag and customer license-key UX from the design.

The default `failure_behavior: "warn"` is intentional. Promotion to `block` is a per-project decision and should follow a period of `warn`-only operation that establishes a baseline kill rate.

#### 4. Container hook installation

`Containers::QualityHooks` is extended to install a third hook when a `mutation_test` requirement resolves for the project:

```ruby
module Containers
  module QualityHooks
    def install_quality_hooks(git_ops, agent_run)
      language = detect_language(agent_run.project)
      lint_cmd  = Prompts::BuildForIssue::LANGUAGE_LINT_COMMANDS[language]
      test_cmd  = Prompts::BuildForIssue::LANGUAGE_TEST_COMMANDS[language]
      mutation_cmd = resolve_mutation_command(agent_run.project, agent_run.user, language)

      return unless lint_cmd || test_cmd || mutation_cmd

      if DB_DEPENDENT_TEST_LANGUAGES.include?(language) && !agent_run.project.has_running_database_container?
        test_cmd = nil
        mutation_cmd = nil  # mutant for Rails needs the DB too
      end

      git_ops.install_git_hooks(
        lint_command: lint_cmd || "true",
        test_command: test_cmd || "true",
        mutation_command: mutation_cmd || "true"
      )
    end

    private

    def resolve_mutation_command(project, user, language)
      return nil unless language == "ruby"
      req = PreCommitRequirement
              .resolve(project: project, user: user)
              .find { |r| r.check_type == "mutation_test" && r.enabled? }
      req&.command
    end
  end
end
```

The hook runs *after* lint and test pass — a surviving mutation in code that doesn't even compile or whose tests don't pass is not a useful signal.

#### 5. Backpressure feedback loop

`mutant run` produces structured output at `.mutant/results/<run_id>.yml` listing alive mutations with file/line/mutation source. A new parser `QualityFeedback::ParseMutant` reads this and emits the same `CheckResult` struct `QualityFeedbackService` already uses for RuboCop/Brakeman (see RDR-013):

```ruby
module QualityFeedback
  class ParseMutant
    def self.call(results_path:)
      data = YAML.load_file(results_path, permitted_classes: [Symbol, Time])
      alive = data.fetch("alive_mutations", [])
      errors = alive.map do |m|
        {
          file:     m["subject_path"],
          line:     m["source_line"],
          message:  "Surviving mutation in #{m['subject']}: #{m['mutation_diff']}",
          rule:     "alive_mutation",
          severity: "high"
        }
      end
      { errors: errors, warnings: [] }
    end
  end
end
```

The existing feedback-loop in `AgentExecutionWorkflow` consumes this without modification. Surviving mutations become a prompt addendum on the next iteration: "the test for `Foo#bar` did not catch the mutation `return true → return false` at app/models/foo.rb:42 — strengthen the assertion or add a case that triggers the false branch."

Iteration cap stays at the RDR-013 default (3 loops). Mutation-only failures during the warn-default phase do not block PR creation; they attach as a quality warning on the PR body, identical to today's behavior for warn-mode `PreCommitRequirement` failures.

#### 6. QualityMetric extension

Add a `mutation_kill_rate` column to `quality_metrics` (numeric(5,4), nullable). `QualityMetrics::Collect` calls a new collector:

```ruby
module QualityMetrics
  class CollectMutationScore
    def self.call(agent_run:)
      results = MutantResultsReader.read(agent_run.worktree_path)
      return nil unless results

      total  = results.fetch(:total_mutations)
      killed = results.fetch(:killed_mutations)
      return nil if total.zero?

      killed.to_f / total
    end
  end
end
```

Null is meaningful: it means mutation testing did not run for this agent run (no requirement configured, non-Ruby project, or DB unavailable). Composite scoring in `QualityMetrics::CalculateCompositeScore` excludes nil-valued dimensions rather than treating them as zero.

#### 7. Prompt / style-guide evolution integration

No code change required in `PromptEvolution::Mutate` or the style-guide pipeline (RDR-035). They already sample `QualityMetric` rows and feed composite scores into A/B comparisons. Once `mutation_kill_rate` is non-null for runs in Ruby projects with mutation testing enabled, those runs naturally contribute the new dimension. This is the highest-value downstream effect of this RDR: the prompt-evolution loop starts optimizing for tests that *actually test things*, not just tests that *exist*.

#### 8. Nightly sweep workflow (Paid-managed projects)

For projects with a `mutation_test` requirement, a per-project nightly job runs the full suite (no `--since`) against the latest `main` and writes the score to `QualityMetric` with `source: "scheduled_mutation_sweep"`. This catches the indirect-change blind spot mutant's incremental mode documents (constant edits, behavioral changes across subjects). Implementation: GoodJob recurring job, throttled to one project per worker per night.

### Decision Rationale (summary)

| Question | Decision |
|---|---|
| Block or warn by default? | **Warn.** Initial surviving-mutation noise is too high to block. Promote per project after baseline established. |
| Full or incremental in the agent loop? | **Incremental (`--since HEAD~1`).** Full only in nightly sweeps. |
| Per-worker DBs or `--jobs 1`? | **`--jobs 1` in Phase 1.** Template DBs in Phase 2 if runtime becomes a blocker. |
| Where to put mutation score? | **`QualityMetric#mutation_kill_rate`.** No parallel pipeline. |
| Does Paid itself need a mutant license? | **Historical only after Amendment 1:** ~~No. Paid is open source; CI runs `--usage opensource`.~~ The sanctioned `viamin/mutant` source removes this split-path requirement once `viamin/paid#2367` and `viamin/paid#2368` land. |
| Who owns the license for commercial customer projects? | **Historical only after Amendment 1:** ~~The customer. They provide `MUTANT_LICENSE_KEY` as a project env var; Paid forwards it to the agent container but never persists it.~~ Amendment 1 removes customer license-key handling from the target design. |
| Where to start for Paid itself? | **Tier-1 security-critical subjects.** Expand only after they reach 100% kill. |

## Alternatives Considered

### Alternative 1: Coverage thresholds (SimpleCov) only

**Description**: Continue with line/branch coverage gates; do not add mutation testing.

**Pros**: Zero new dependency. No license cost. Familiar.

**Cons**: Does not detect the failure mode in the Problem Statement. An agent can write a 100%-coverage test suite with zero meaningful assertions, and SimpleCov will be happy.

**Reason for rejection**: This is precisely the problem this RDR exists to address.

### Alternative 2: Property-based testing instead

**Description**: Add `prop_check` or `rantly` and have agents write property tests.

**Pros**: Finds invariant violations the developer hadn't thought of. Complementary signal.

**Cons**: Different problem. Property tests find *unknown* invariants; mutation tests find *weak* assertions on *known* behavior. Property tests also place a much higher cognitive load on the agent, which is exactly the test-writing weakness we are trying to compensate for.

**Reason for rejection**: Not a substitute. Could be a future RDR on top of this one.

### Alternative 3: Mutation testing as a hard gate from day one

**Description**: `failure_behavior: "block"` by default; PRs with any surviving mutation are rejected.

**Pros**: Strongest possible signal. Forces the issue.

**Cons**: First-week-of-adoption surviving-mutation count is enormous and dominated by redundant production code, not by missing tests. A hard gate would turn every agent run into a backpressure loop the agent can't escape, and would frustrate human contributors enough to motivate disabling the tool entirely.

**Reason for rejection**: Defaults matter. Promotion path from `warn` → `block` is explicit and per-project.

### Alternative 4: Run mutant as a separate Temporal workflow, not a pre-commit hook

**Description**: Skip the in-container pre-commit integration; run mutant only as a background workflow after the agent run completes.

**Pros**: No runtime cost in the agent loop. Simpler container plumbing.

**Cons**: Loses the backpressure property. The agent never sees the alive mutations, so it cannot self-correct within the same run. The signal becomes a passive scorecard rather than an active feedback loop, which is the whole point of RDR-013.

**Reason for rejection**: Backpressure-in-loop is the highest-value mode. Background-only is the fallback when in-loop runtime is prohibitive — and `--since HEAD~1` keeps it tractable.

### Alternative 5: Per-language mutation tools (Stryker for JS, mutmut for Python, etc.)

**Description**: Polyglot mutation testing from day one across all supported languages.

**Pros**: Same signal across the whole portfolio.

**Cons**: Each tool has its own quirks, output format, license model, and integration story. Adding four at once dilutes the design and quintuples the support surface.

**Reason for rejection**: Start with Ruby because (a) Paid itself is Ruby, (b) mutant is the most mature of the lot, and (c) the per-language quality bars and tooling are different enough to deserve separate RDRs. Future RDR can cover Stryker-JS / mutmut.

## Trade-offs and Consequences

### Positive Consequences

- **Catches the LLM-test pathology directly.** Mutation score is the most honest measure of whether AI-written tests do their job.
- **Composite quality signal gets a new dimension** that downstream consumers (gating, pause, prompt evolution, style-guide evolution) inherit for free.
- **Tier-1 self-quality for Paid.** Security boundaries (trusted comments, tenant context, RBAC policies) get adversarial coverage that line-coverage cannot provide.
- **Customers retain control.** Opt-in per project and configurable failure behavior remain, but Amendment 1 removes customer-owned mutant licensing from the target design.
- **Incremental by default.** Runtime cost is bounded by the diff, not by the codebase size.

### Negative Consequences

- **Signal strength is initially lower.** `viamin/mutant` currently exposes fewer modern mutation operators than the commercial upstream, so early kill-rate scores are weaker than the original design expected.
- **CI time increase.** Even incremental, a tier-1 mutation run on a PR is minutes, not seconds. Nightly full sweep is hours.
- **Adoption noise.** First mutation runs in any codebase surface many alive mutations that point at *redundant production code*, not at missing tests. Triage cost is real until the corpus settles.
- **Metaprogramming blind spots.** ActiveRecord callbacks, concerns, dynamically-defined methods are invisible to mutant. Mutation score is a meaningful but partial coverage of Rails code.
- **DB parallelism cost in containers.** `--jobs 1` keeps things simple but is slow. Template DBs are a Phase-2 lift.

### Risks and Mitigations

- **Risk**: Mutation runs in customer containers exhaust container memory or CPU and crash unrelated work.
  **Mitigation**: Hard timeout per mutation in `.mutant.yml` (`mutation.timeout`), `--jobs 1` default, fail-warn behavior so timeouts don't block.

- **Risk**: Mutation kill-rate noise dominates the composite quality score and destabilizes prompt evolution.
  **Mitigation**: Composite score in `QualityMetrics::CalculateCompositeScore` weights mutation score below explicit human feedback initially. Adjust after baseline.

- **Risk**: Agent gets stuck in a backpressure loop chasing surviving mutations that are actually evidence of redundant production code.
  **Mitigation**: 3-iteration cap (from RDR-013) is enforced. Prompt instruction explicitly authorizes the agent to delete redundant production code when justified by an alive mutation, rather than to add tests that prove the redundancy is desired.

- **Risk**: Customer's Ruby version is unsupported by mutant.
  **Mitigation**: Skip silently when `RUBY_VERSION` is outside the supported range; record `mutation_kill_rate: nil`; log a one-time per-project warning.

- **Risk**: Historical licensing path created compliance and credential UX burden.
  **Mitigation**: Amendment 1 removes that path by switching the sanctioned source to `viamin/mutant`; the remaining adoption risk is upstream readiness, tracked in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, `viamin/mutant#12`, and `viamin/mutant#16`.

## Implementation Plan

### Phase 1: Paid Self-Quality (tier-1 only)

1. Add `mutant-rspec` to `Gemfile` (test group), `bundle install`.
2. Author `.mutant.yml` at repo root with tier-1 subjects.
3. Iterate on tier-1 subjects until kill rate is 100%; any surviving mutation either gets a new test or the production code is deleted.
4. Add `.github/workflows/mutation.yml` with the incremental PR job and nightly cron.
5. Add a Make/Rake task `bin/mutation` for local incremental runs.

Historical only after Amendment 1 (2026-05-29): ~~No mutant license key, secret, or credential entry is added to Paid for its own runs.~~ The current direction is to land the gem-source switch in `viamin/paid#2367`, then remove `--usage` handling in `viamin/paid#2368`.

### Phase 2: PreCommitRequirement and container integration

1. Land `viamin/paid#2367` to switch the sanctioned source to `viamin/mutant`, subject to the upstream blockers in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, and `viamin/mutant#12`.
2. Land `viamin/paid#2368` to remove stale `--usage` plumbing and license-path assumptions from the integration.
3. Migration: add `"mutation_test"` to `PreCommitRequirement::CHECK_TYPES`.
4. `Containers::QualityHooks` extension (Section 4 above).
5. `git_operations.rb` support for `mutation_command` in `install_git_hooks`.
6. `QualityFeedback::ParseMutant` parser and feedback-loop wiring in `AgentExecutionWorkflow`.
7. Land `viamin/paid#2370` for the customer-facing settings UI / Avo admin after the gem-source switch and `--usage` cleanup.

### Phase 3: Quality signal integration

1. Migration: add `mutation_kill_rate numeric(5,4)` to `quality_metrics`.
2. `QualityMetrics::CollectMutationScore` collector; call from `QualityMetrics::Collect`.
3. `QualityMetrics::CalculateCompositeScore` updated to include `mutation_kill_rate` as a nil-tolerant dimension.
4. GoodJob recurring job for nightly per-project full-sweep mutation runs (opt-in).
5. Dashboard widget on `QualityDashboards` for mutation kill-rate trend per project.

### Files to Create / Modify

**Paid self-quality:**

- `Gemfile`, `Gemfile.lock` — add `mutant-rspec`
- `.mutant.yml` (new)
- `.github/workflows/mutation.yml` (new; historical draft assumed `--usage opensource`, Amendment 1 removes that split path after `viamin/paid#2368`)
- `bin/mutation` (new; historical draft assumed `--usage opensource`, Amendment 1 removes that split path after `viamin/paid#2368`)

**Container integration:**

- `app/models/pre_commit_requirement.rb` — `CHECK_TYPES` constant
- `app/services/containers/quality_hooks.rb` — `resolve_mutation_command`
- `app/services/containers/git_operations.rb` — third hook command
- `db/migrate/YYYYMMDDHHMMSS_extend_pre_commit_check_types_for_mutation.rb`

**Feedback loop:**

- `app/services/quality_feedback/parse_mutant.rb` (new)
- `app/services/quality_feedback_service.rb` — register parser
- `app/temporal/workflows/agent_execution_workflow.rb` — no change required (parser slots into existing structure)

**Quality signal:**

- `db/migrate/YYYYMMDDHHMMSS_add_mutation_kill_rate_to_quality_metrics.rb`
- `app/models/quality_metric.rb`
- `app/services/quality_metrics/collect_mutation_score.rb` (new)
- `app/services/quality_metrics/collect.rb` — call new collector
- `app/services/quality_metrics/calculate_composite_score.rb` — nil-tolerant new dimension
- `app/jobs/scheduled_mutation_sweep_job.rb` (new)

### Dependencies

- `mutant` and `mutant-rspec` gems (test group)
- `viamin/paid#2367` to switch the sanctioned source to `viamin/mutant`
- `viamin/paid#2368` to remove `--usage` plumbing
- `viamin/paid#2370` for customer UI work after the source switch
- Postgres template DB tooling (Phase 2 only, if `--jobs > 1` becomes necessary)
- Upstream readiness in `viamin/mutant#9`, `viamin/mutant#10`, `viamin/mutant#11`, `viamin/mutant#12`, and `viamin/mutant#16`

## Validation

### Testing Approach

1. **Parser tests** — `QualityFeedback::ParseMutant` correctly parses real `.mutant/results/*.yml` fixtures.
2. **Hook installation tests** — `Containers::QualityHooks` installs the mutation command iff the requirement is configured, the language is Ruby, and the DB is available.
3. **Metric collection tests** — `QualityMetrics::CollectMutationScore` returns nil when mutant didn't run, returns kill rate when it did.
4. **Composite score tests** — `CalculateCompositeScore` excludes nil-valued dimensions rather than zeroing them.
5. **Resolution tests** — `PreCommitRequirement.resolve` correctly merges mutation_test requirements across account/user/project scopes.
6. **License-absent test** — when `mutant-rspec` is not in the customer's `Gemfile`, the hook is a no-op (`true`).
7. **Fork-readiness tests** — fixture coverage for the `viamin/mutant` switch should track the open compatibility work in `viamin/mutant#16`.

### Test Scenarios

1. **Scenario**: Agent writes a tautological RSpec test (`expect(x).to eq(x)`); mutation runs in container.
   **Expected**: Mutant reports surviving mutations; alive-mutation summary becomes the next iteration's prompt addendum; `QualityMetric#mutation_kill_rate < 1.0`.

2. **Scenario**: Agent run touches no Ruby files (e.g., README-only PR).
   **Expected**: `mutant --since HEAD~1` returns immediately with no subjects; hook passes; `mutation_kill_rate` is nil.

3. **Scenario**: Customer project has `mutation_test` requirement but no mutant gem in `Gemfile`.
   **Expected**: Hook resolves to `true`; warning logged once per project per day; agent run proceeds.

4. **Scenario**: Nightly sweep runs against a project that recently merged a constant-rename PR; incremental mode would have missed the indirect effect.
   **Expected**: Full sweep catches the regression and records the lower kill rate; gate threshold (if configured) fires.

5. **Scenario**: Paid PR introduces a security regression in `Prompts::BuildForIssue.fetch_trusted_comments` (e.g., trusted-comment filter weakened).
   **Expected**: CI tier-1 mutation job surfaces a surviving mutation on that subject; PR fails the mutation check.

### Performance Validation

- Tier-1 incremental run on a typical Paid PR: < 5 min wall clock.
- Container-side `mutant run --since HEAD~1 --jobs 1` on a typical agent diff: < 3 min wall clock.
- Nightly full sweep on Paid itself: < 90 min.
- 2026-05-27 implementation note: the recurring GoodJob sweep is serialized to one project per invocation with a hard per-project timeout of 90 minutes (`MutationSweeps::Run::SWEEP_TIMEOUT`). CI coverage validates the orchestration path with a fixture-backed mutant result and keeps the nightly scheduler from fanning out all opted-in projects at once.
- Composite score calculation overhead from new dimension: < 10 ms per quality metric.

### Security Validation

- Amendment 1 removes customer mutant-license credentials and `--usage` branching from the target design, shrinking the secrets surface.
- Surviving-mutation output never includes raw secret values from the test database (parser strips known-sensitive patterns before generating the prompt addendum).

## References

### Requirements & Standards

- [Don't Waste Your Backpressure](https://banay.me/dont-waste-your-backpressure/) — backpressure principle that this RDR extends to test-quality
- RDR-013 — three-layer quality model this RDR slots into

### Dependencies

- [viamin/mutant on GitHub](https://github.com/viamin/mutant)
- [viamin/mutant blocker #9](https://github.com/viamin/mutant/issues/9)
- [viamin/mutant blocker #10](https://github.com/viamin/mutant/issues/10)
- [viamin/mutant blocker #11](https://github.com/viamin/mutant/issues/11)
- [viamin/mutant blocker #12](https://github.com/viamin/mutant/issues/12)
- [viamin/mutant compatibility follow-up #16](https://github.com/viamin/mutant/issues/16)

### Research Resources

- ["Mutation Testing for the New Era of Software Development"](https://increment.com/testing/in-praise-of-mutation-testing/) — general motivation
- Mutation testing academic survey: Jia & Harman, "An Analysis and Survey of the Development of Mutation Testing" (IEEE TSE 2011)

## Notes

- **Why `warn` and not `block`** — see Alternative 3. The promotion path is intentional and per-project.
- **Why incremental in the loop, full in cron** — see "Runtime cost is the dominant design constraint."
- **What this RDR does *not* do** — it does not introduce property-based testing, it does not extend mutation testing to non-Ruby projects, and it does not modify the A/B test infrastructure. Each of those is a candidate future RDR.
- **Coupling with RDR-035** — once `mutation_kill_rate` lands in `QualityMetric`, style-guide evolution gets a "tests written with style guide X have higher kill rate than tests written with style guide Y" signal. That is the most promising long-term payoff: closing the loop between style guidance, test quality, and the optimization pipeline.
