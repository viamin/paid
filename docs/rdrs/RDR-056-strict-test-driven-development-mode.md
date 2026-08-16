# RDR-056: Test-Driven Development Modes with Human Test Review

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-16
- **Status**: Draft
- **Type**: Architecture + Process
- **Priority**: P1
- **Related RDRs**:
  - [RDR-031](RDR-031-focused-agent-runs.md) (Focused Agent Runs)
  - [RDR-036](RDR-036-mutation-testing-for-ai-generated-tests.md) (Mutation Testing for AI-Generated Tests)
  - [RDR-046](RDR-046-polyglot-language-detection-and-test-execution.md) (Polyglot Language Detection and Test Execution)
  - [RDR-051](RDR-051-lid-aware-agent-runs.md) (LID-Aware Agent Runs)
  - [RDR-053](RDR-053-new-feature-creation.md) (New Feature Creation)
- **Related Issues**: TBD
- **Related Tests**: TBD

## Problem Statement

Paid can generate tests and implementation in a single autonomous pass, but that lets a bad
test plan become the definition of done. This is especially risky for agent-written code:
tests may encode the wrong behavior, miss important edge cases, overfit implementation
details, or diverge from LID intent before a human has reviewed them.

Paid needs two project-level TDD modes:

1. **Strict TDD** - Paid writes tests first, opens a draft PR, and waits for human approval
   of the tests before writing implementation code.
2. **Non-strict TDD** - Paid follows the same test-first, implementation, and refactor
   sequence, but uses an agent review verdict instead of a human pause at the test-review
   boundary.

In both modes, the PR must expose the test plan clearly enough for review without forcing
the reviewer to read every test body.

## Context

### TDD in Paid

TDD here means a three-step red/green/refactor workflow:

1. **Red** - write or update tests for the issue and expect CI to fail because production
   code is not implemented yet.
2. **Green** - write the minimum implementation needed to make the approved tests pass.
3. **Refactor** - improve the implementation while keeping the approved tests green.

Strict TDD adds a human gate between red and green. Non-strict TDD keeps the same sequence
but lets Paid review and approve the tests automatically.

### Human review surface

The output of the red step is a draft PR, not a suspended agent process. The agent run
finishes after creating or updating that draft PR. Paid must not start the implementation
step until test review has produced a verdict label.

The label contract is:

| Label | Meaning |
|---|---|
| `paid-tests-ready-for-review` | The draft PR contains the proposed tests and is waiting for test review. CI is expected to fail. |
| `paid-tests-approved` | The tests are approved; Paid may start the implementation step. |
| `paid-test-changes-requested` | The tests are not approved; Paid should address review comments before implementation starts. |

Paid should not use GitHub's "changes requested" code-review state for this test gate. A
human may approve the tests without intending to approve the whole PR, and GitHub review
state conflates those two approvals.

### PR description test outline

Every Paid PR that includes tests should include a test-outline section rendered in the
style of RSpec's `--format documentation` output: nested contexts and example titles, but
no test bodies or assertion details.

Example:

```text
Test outline

Projects::Import
  when the repository exists
    creates a project
    records the default branch
  when GitHub rejects the token
    reports the authentication failure
```

This section is useful in all modes, not only strict TDD. It gives reviewers a quick map
of behavior coverage before they inspect the actual specs.

### LID interaction

For LID projects, the red step must walk the LID arrow before writing tests:

```
HLD -> LLDs -> EARS -> Tests
```

The strict review gate lets the human review both the changed LID documentation and the
test outline before implementation begins. In non-strict mode, the test-review agent
performs that review and records its verdict with the same labels.

## Research Findings

### Key discoveries

**A label gate is enough.** Paid already models work as discrete agent runs that create or
update PRs. A strict TDD red step does not need resumable mid-run orchestration; it needs a
draft PR and a queue rule that blocks follow-on implementation runs until a test verdict
label exists.

**The approval is about tests, not the PR.** GitHub review states are too broad for this
workflow. A human approving the test plan should not have to approve the finished PR before
implementation exists. Labels keep the test verdict separate from final PR review.

**Non-strict mode still needs the same contract.** If non-strict TDD skipped the labels, the
rest of the pipeline would need separate branching logic. Instead, a `test_review` agent
run reviews the tests and applies either `paid-tests-approved` or
`paid-test-changes-requested`, preserving the same transition rule.

**The PR description should summarize tests for all PRs.** Test outline rendering is not a
strict-TDD feature. Any PR with tests benefits from a behavior-level summary, and the same
formatter can be reused across normal, strict TDD, non-strict TDD, review, and continuation
runs.

## Proposed Solution

### Decision

Add a project-level TDD mode setting with three values:

| Mode | Behavior |
|---|---|
| `off` | Existing Paid behavior. |
| `non_strict` | Paid writes tests first, runs an automated test-review agent, then implements after `paid-tests-approved`. |
| `strict` | Paid writes tests first, opens a draft PR, and waits for human label-based approval before implementation. |

All PRs that include tests get a test-outline section in their PR description.

### Run-scoped write guards

Both strict and non-strict TDD require pre-commit checks that enforce what each run type is
allowed to change:

| Run type | Allowed changes | Forbidden changes |
|---|---|---|
| Test-writing | Tests, and LID docs when applicable | Implementation code |
| Test-fixing | Implementation code | Tests, unless the run returns the PR to test review |
| Refactor | Implementation code | Tests |

If a test-fixing run discovers that the approved tests are wrong or incomplete, it may edit
tests only by removing `paid-tests-approved`, adding `paid-tests-ready-for-review`, and
returning the PR to the test-review gate. It must not change tests and continue as though
the prior approval still holds.

### Strict TDD workflow

1. Paid starts a test-writing agent run for the issue.
2. If the project uses LID, the run updates the relevant LID artifacts before or alongside
   the tests.
3. The run writes tests only, opens or updates a draft PR, adds
   `paid-tests-ready-for-review`, and finishes.
4. Paid does not start implementation while `paid-tests-ready-for-review` or
   `paid-test-changes-requested` is present without `paid-tests-approved`.
5. If the human approves the tests, they remove `paid-tests-ready-for-review` and add
   `paid-tests-approved`.
6. If the human rejects the tests, they add a PR comment and `paid-test-changes-requested`.
   Paid runs another test-writing pass to address the comments, then restores
   `paid-tests-ready-for-review`.
7. Once `paid-tests-approved` exists, Paid starts the implementation run.
8. If implementation exposes a major mismatch in the approved tests or LID docs, Paid stops
   by returning the PR to test review instead of silently rewriting the contract.
9. When tests pass, Paid runs the refactor step with tests frozen and keeps the suite green.

### Non-strict TDD workflow

Non-strict TDD uses the same red/green/refactor sequence and the same labels, with one
replacement: after the test-writing run, Paid starts a `test_review` agent run instead of
waiting for a human. That review run writes a concise verdict comment and applies exactly
one verdict label:

- `paid-tests-approved`
- `paid-test-changes-requested`

Implementation starts only after `paid-tests-approved`, just as in strict mode.

### Test-outline rendering

Paid should add a PR-description section for every PR whose diff includes tests:

````markdown
## Test Outline

```text
<RSpec documentation-style output>
```
````

For RSpec projects, Paid should prefer the suite's own documentation formatter output when
available. For other frameworks, Paid should render the nearest equivalent: suite,
context/class, and test/example title lines without test bodies.

### LID behavior

For LID projects:

- Test-writing runs must update EARS claims before tests when behavior intent changes.
- Test files must carry `@spec` annotations where the project convention requires them.
- The PR description must surface both the LID phase/coherence status and the test outline.
- Strict test review covers both documentation and tests.

If the project is not LID-enabled, TDD mode still works with tests and labels only.

## Alternatives Considered

### Alternative 1: Use GitHub review approvals for the test gate

Rejected. GitHub review approval and changes-requested states apply to the PR as a whole.
The strict TDD gate needs a narrower verdict: "these tests describe the right behavior."

### Alternative 2: Pause an agent run mid-execution

Rejected. The red-step agent run can finish after producing a draft PR. Follow-on runs are
started only after labels permit them, which fits Paid's existing run model without adding
resumable in-container execution.

### Alternative 3: Make test outline output strict-TDD-only

Rejected. Once Paid can produce the outline, every PR with tests benefits from it. Keeping
it universal also makes strict and non-strict PRs look the same to reviewers.

## Trade-offs and Consequences

### Benefits

- Humans can approve behavior before implementation exists.
- CI failure during the red step becomes expected and understandable.
- LID projects get a natural review point for both intent docs and specs.
- Non-strict mode keeps throughput high while preserving the same state machine.

### Costs

- Strict mode adds review latency.
- Queueing logic must treat test-review labels as blockers for implementation runs.
- PR description generation needs framework-aware test outline extraction.

### Risks

- Humans may leave PRs stuck with `paid-tests-ready-for-review`.
- An automated test-review agent may approve weak tests in non-strict mode.
- Implementation may reveal that approved tests encoded the wrong behavior.

Mitigations: surface test-review PRs in the needs-input queue, keep non-strict review
verdicts visible as comments, and return to test review when implementation finds a major
contract mismatch.

## Implementation Plan

1. Add project-level TDD mode configuration: `off`, `non_strict`, `strict`.
2. Add the three `paid-` prefixed labels to project setup/sync.
3. Add a test-writing run path that creates draft PRs with tests and no implementation.
4. Add queue rules that block implementation until `paid-tests-approved`.
5. Add `test_review` agent runs for non-strict mode.
6. Add run-scoped pre-commit checks that block forbidden file changes for test-writing,
   test-fixing, and refactor runs.
7. Add PR-description test-outline rendering for every PR with tests.
8. Add LID-aware prompt clauses so strict review covers changed LID docs and tests together.
9. Add refactor-step prompting that freezes tests and requires the suite to stay green.

## Validation

- A strict-mode project opens a draft PR with tests, `paid-tests-ready-for-review`, failing
  CI, and no implementation run.
- Adding `paid-tests-approved` starts implementation.
- Adding `paid-test-changes-requested` plus a comment starts a test-revision run, not
  implementation.
- A non-strict project runs automated test review and applies the same verdict labels.
- Every PR with tests includes a documentation-style test outline.
- LID projects show changed LID docs, coherence status, and test outline before
  implementation starts.
- Test-writing runs fail pre-commit if they alter implementation code.
- Test-fixing and refactor runs fail pre-commit if they alter tests without returning the
  PR to test review.
