---
parent: PAID
prefix: NO-OUTPUT-ISSUE
---

# Low-Level Design: No-Output Issue Handling

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> defines how issue-scoped runs that produce no PR/commit transition the issue
> into a human-actionable state without disappearing from operator view.

## Purpose

`HandleNoOutputIssueRunActivity` owns the last step of an issue-scoped run that
did not open a pull request. The state transition is consequential:

- `paid_state: "recommend_close"` removes the issue from the auto-pick queue.
- `paid_state: "needs_input"` parks the issue until a human answers.

In both cases the GitHub explanation comment is the only rationale a human sees
on the issue itself. A parked issue with neither that rationale nor a surfaced
error violates the HLD tenet "No silent stops."

## Outcome handling

For human-actionable no-output outcomes (`recommend_close`, `needs_input`,
and `no_code_required`), the activity performs two duties:

1. Transition the issue into its Paid-side parked (or completed) state and
   reconcile labels.
2. Ensure the missing-PR explanation is either visible on GitHub or durably
   surfaced as an execution problem on the agent run.

## Goal-aware classification: agent-declared no-code-required completion

Classifying every no-output issue run as `recommend_close` conflates two very
different situations: the agent gave up on actionable work, versus the agent
correctly determined that an umbrella, verification, or audit issue's
closeout scope does not require a code change (e.g. it required only docs
updates and follow-up issue filing, already done in prior runs). Inferring
which situation occurred from the mere absence of a PR is unreliable — the
classifier has no notion of the issue's goal.

Rather than teach the classifier to infer issue *type*, the agent explicitly
declares the outcome in its own summary output via a marker channel, the same
pattern `ParseCrossRepoIssuePlanActivity` uses for its upstream-issue plan
markers:

```
<!-- paid:no-code-required -->
<!-- no-code-required-rationale-start -->
...rationale markdown explaining why no code change is required...
<!-- no-code-required-rationale-end -->
```

Both the declaration marker and a non-blank rationale block are required for
the declaration to take effect. A bare marker with no rationale is treated as
no declaration at all — it falls through to the existing
`provider_error` / `infrastructure_error` / `needs_input` / `recommend_close`
heuristics — so a malformed declaration can never silently complete an issue
without a human-visible reason.

When the declaration is present and valid, the run is classified
`no_code_required`: distinct from `recommend_close` so operator tooling and
auto-pick candidate selection can tell an agent-asserted completion apart from
a Paid-side guess. The issue transitions to `paid_state: "completed"` — the
same state used elsewhere in the system for no-PR runs that finished the
requested work — and the declared rationale is posted as a marker-tagged
GitHub comment, satisfying the same "no silent stops" visibility guarantee as
the other no-output outcomes.

`paid_state: "completed"` is not terminal by itself: Auto-Pick's
completed-issue recovery path (`DefaultCandidateSource`) deliberately
re-includes open completed issues whose last automatic run finished without a
PR, on the theory the failure may have been transient. That recovery would
otherwise re-pick a no-code-required issue and loop it forever, since the
agent will typically reach the same conclusion again. The issue is also
stamped with `no_code_required_at`, which candidate selection treats as a
permanent exclusion from that recovery path regardless of `paid_state` — the
same style of always-on guard already used for merged-PR-linked issues. Only
a manually triggered run can pick the issue up again. An `epic` umbrella is
the narrow exception: when the completed audit subsequently creates or links
required child/dependency work, Auto-Pick keeps it blocked while that work is
unresolved and permits a later final audit after resolution. This preserves the
no-loop guarantee for ordinary issues while allowing an honest umbrella audit
to reopen its acceptance loop when it found a real gap.

The declaration is parsed from the same wide, most-recent output window used
for error classification — not from the truncated excerpt quoted back in the
GitHub comment. Agents emit the declaration at the end of a run, so a narrow
excerpt window would let a verbose run push the declaration out of view and
silently downgrade an agent-asserted completion to `recommend_close`.
Classification must never turn on where in the output a signal happened to
land.

This declaration channel is deliberately narrow: it only recognizes an
explicit, well-formed marker from the agent's own output. It does not attempt
to infer issue type from title, labels, or body content (that would be
exactly the guess-from-absence pattern this design avoids). Runs whose output
contains no declaration retain today's classification behavior unchanged.

The state transition happens before the comment attempt, so comment-post
failures do not roll back the issue state. Instead the activity records the
failure on the `AgentRun` in two forms:

- `error_message` carries a concise user-visible summary for existing run and
  dashboard surfaces.
- `external_metadata["issue_explanation_comment_failure"]` stores structured
  details (`issue_state`, `marker`, `error`, timestamp) for durable inspection.

This keeps the consequential state change idempotent while satisfying the
visibility requirement when GitHub is unavailable or rejects the comment.

## Retry and deduplication

The activity remains safe to retry:

- Before posting, it checks recent issue comments for the marker corresponding
  to the parked state.
- If the marker is already present, it skips posting and clears any previously
  recorded comment-failure metadata for that run.
- If the post succeeds on a later retry, it also clears the recorded failure.

This preserves marker-based deduplication while allowing a previously surfaced
comment failure to self-heal once the human-visible rationale exists.

## PR-producing partial closeouts

A run that creates a PR can still leave acceptance criteria unmet. The workflow
runs `ReconcilePartialCloseoutActivity` after PR creation but **before**
`UpdateIssueWithPrActivity` — the step that completes the parent issue — so gap
reconciliation lands on a still-incomplete parent (dependency edges, Inbox
subject, and parent-body rewrite all target an open work item, not a terminal
one). The activity uses an agent-harness structured assessment of approved
intent, the run/PR evidence, and current open issues (the assessment prompt
lists the bounded open-issue set so owner reuse is grounded, not guessed from
evidence prose). The assessment follows the same transport routing as the other
schema-boundary services: the API-key schema transport when `Llm::TextMode` is
enabled, the CLI transport otherwise, so a keyless deployment keeps working. The
assessment is persisted on the run on first success and reused across activity
retries, keeping gap indices — the replay keys — stable. The deterministic
reconciler validates that assessment, reuses only current open owners (never the
parent itself), creates bounded focused issues when needed (labeled with the
project's automation/generated labels so they route into auto-pick), and
records local `IssueDependency` edges plus dependency text on the parent in
the project's configured `issue_dependency_format` wording. It persists its
progress on the run so a GitHub failure can resume without duplicate issues.
Human-only prerequisites create one aggregated blocking Inbox notification
covering every prerequisite with its exact next step rather than an agent
retry. Both the analyzer and the deterministic reconciler reject a human gap
whose next step is missing or blank *before* anything is persisted, so an
activity retry regenerates the assessment instead of publishing a generic
"review the prerequisite" placeholder that no operator can act on.

The activity result tells the workflow whether any gaps remain (the persisted
status alone is ambiguous: `reconciled` covers both a gap-free closeout and one
whose gaps all received agent owners). When gaps remain, the workflow splits
`UpdateIssueWithPrActivity`'s two duties: the completion path (which also owns
trigger-label cleanup) is skipped, so the parent issue stays in its
non-terminal state, keeps its trigger label, and remains dependency-blocked.

Keeping the parent open is necessary for a continuation path but not
sufficient: the permanent merged-PR guard in
`Automation::Strategies::AutoPick::DefaultCandidateSource` would keep the
source issue out of Auto-Pick forever once the partial PR merges, stranding it
even after every gap owner resolves. The persisted assessment gaps double as
the durable partial-closeout signal for a re-audit exception to that guard,
keyed on the issue's *latest PR-producing* run: while gap-owner dependencies
are unresolved the shared `ready_for_work` dependency gate keeps the parent
out, while the partial PR is open the open-PR guards keep it out, and once
both clear the parent re-enters selection for a continuation run — through
the shared `eligible_scope`, so the periodic sweep and the eager enqueue on
dependency resolution behave identically. Keying on the latest PR-producing
run keeps the guard terminal after a later gap-free closeout completes the
parent, and keeps the exception intact when a re-audit attempt fails before
publishing another PR (a failed attempt supersedes nothing).

The PR-link evidence does not skip
with it: a dedicated `PostPartialCloseoutEvidenceActivity` posts a
marker-tagged `Partial pull request created: …` comment on the still-open
parent, so the partial PR is visible on the issue where the
dependency-blocked remaining work is listed — not only on the internal
`AgentRun`. The marker embeds the run id and the dedup check restricts
matching to Paid-authored comments, so activity retries never double-post and
a forged marker from another author cannot suppress the evidence. When no
gaps remain, the parent is completed and updated exactly as a full closeout.
