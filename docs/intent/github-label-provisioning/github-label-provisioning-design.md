# LLD: GitHub Label Provisioning

> parent: docs/high-level-design.md
> prefix: GH-LABELS

## Problem

Paid recognizes and applies a growing set of GitHub labels as part of runtime
behavior — pause/resume, escalation, auto-merge opt-out and outcomes, the
strict-TDD review gate, issue enhancement, model-health alerts, release
automation, and the built-in auto-pick skip labels. Before this segment,
`Projects::EnsureStandardLabels` provisioned only a subset of that contract
(the four config-driven labels, `recommend_close`, `paused`, the three TDD
labels, and priority tiers). Everything else — `paid-escalated`,
`paid-dismiss-escalation`, `paid-skip-auto-merge`, `paid-auto-merged`,
`paid-auto-merged-dependabot`, `paid-auto-released`, `model-health`, and the
auto-pick skip labels (`planning`/`research`/`waiting`/`tracking`/`epic`/
`needs-manual-setup`) — was assumed to already exist by the code paths that
apply, remove, or query them.

Two separate risks follow from that gap:

- GitHub's issue-labels API (unlike its web UI) does **not** auto-create a
  label that doesn't yet exist on the repository — a write can 404.
- Even where a write succeeds, a label a human discovers in GitHub's label
  picker with no (or a stale) description doesn't communicate that applying
  or removing it changes Paid's behavior. This is most dangerous for the
  labels a human or a non-Paid bot might apply directly (`paused`, the
  auto-pick skip labels, `paid-skip-auto-merge`), since the label name alone
  doesn't say what it does.

The prior service also only *reported* description drift (`divergent`) rather
than fixing it, so a stale description persisted across every future sync.

## Design

`Projects::EnsureStandardLabels` is the single canonical provisioning
contract for every GitHub label with a Paid behavioral consequence. Its
`LABEL_DEFINITIONS` constant is the inventory: each entry declares `color`,
`description`, and a `kind` —

- `:control` — applying or removing the label changes automation
  (`paid-automation`, `paid-paused`, `paid-escalated`,
  `paid-skip-auto-merge`, the three TDD gate labels, the auto-pick skip
  labels).
- `:status` — applied by Paid as an output/status marker with no further
  automation effect (`paid-generated`, `paid-enhanced`,
  `paid-needs-input`, `paid-recommend-close`, `paid-dismiss-escalation`,
  `paid-auto-merged`, `paid-auto-merged-dependabot`, `paid-auto-released`,
  `paid-ready`).
- `:informational` — descriptive taxonomy (`model-health`, priority tiers).

Every description states the applying/removing consequence in plain
language and stays within GitHub's 100-character label description limit
(enforced by a spec assertion over the whole catalog, not eyeballed per
entry).

### Where each name comes from

Label *names* have three different sources, and `EnsureStandardLabels` reads
every one of them rather than re-declaring the literal:

- **Project-configurable columns** — `generated_label_name`,
  `automation_label_name`, `enhance_issue_*_label_name`, `label_mappings`
  (`recommend_close`, `needs_input`), `priority_labels` (P1/P2/P3), and
  `effective_auto_pick_skip_labels` (project → user → tenant → the
  `AutoPickSkipLabels::DEFAULTS` fallback). Reconciling these labels by their
  *configured* name — not a hard-coded one — is what keeps custom label
  names working without Paid creating or touching a differently-named label
  the project didn't ask for. The `needs_input` stage mapping
  (`HandleNoOutputIssueRunActivity#add_needs_input_label`) resolves
  independently of `enhance_issue_needs_input_label_name` and defaults to
  the same literal name, so `EnsureStandardLabels` only adds a second entry
  for it when a project has configured the two to diverge — otherwise the
  shared default would trip the cross-category collision guard on every
  unconfigured project.
- **Hard-coded, cross-file canonical constants** — `Issue::ESCALATED_LABEL`,
  `Issue::DISMISS_ESCALATION_LABEL`,
  `Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL`,
  `Activities::MergePullRequestActivity::PAID_AUTO_MERGED_LABEL`,
  `DependabotAutoMergeJob::PAID_AUTO_MERGED_LABEL`,
  `AutoReleaseEvaluationJob::PAID_AUTO_RELEASED_LABEL`,
  `Activities::MarkPrReadyActivity::PAID_READY_LABEL`,
  `Models::FileModelHealthIssue::LABEL`, `Issue::PAUSED_LABEL`. Each of these
  is defined exactly once on the class that owns the behavior; every other
  file that reads or writes the label references that constant instead of
  repeating the string literal. `Issue::ESCALATED_LABEL` in particular
  replaces five independent `"paid-escalated"` literals that had drifted
  into `MarkEscalatedActivity`, `FetchIssuesActivity`,
  `MergePullRequestActivity`, `ScanPaidPrsActivity`, and
  `PullRequests::Unblock`.
- **Literal, non-configurable names** — the three TDD gate labels
  (`paid-tests-ready-for-review`/`paid-tests-approved`/
  `paid-test-changes-requested`), because Paid's queue and label-gate logic
  matches on the exact string. `Tdd::ReturnToTestReview` and
  `ScanPaidPrsActivity` already read these back out of
  `LABEL_DEFINITIONS` rather than duplicating them — the same pattern
  `Models::FileModelHealthIssue` now follows for `model-health`'s color and
  description.

### Reconciliation, not just reporting

When an existing label's color or description no longer matches its
canonical definition, `EnsureStandardLabels` calls the new
`GithubClient#update_label` (a thin wrapper over Octokit's `PATCH
/labels/{name}`) instead of only recording the drift. The result exposes
`reconciled` (`{ name:, fields: [...] }`) instead of the old `divergent`
bucket. A permission failure on the update is recorded in `errors` with the
same actionable phrasing used for failed creates, so a caller checking
`any_errors?` — the "Sync Labels" controller action already does, and the
best-effort provisioning call at project creation logs it — never treats
reconciliation failure as success.

### Create failures are verified, not guessed

A 422 from a label create is ambiguous: GitHub returns the same status both
when another writer created the label between our list and create calls and
for real validation failures (an invalid custom name, a description past
GitHub's 100-character limit). `EnsureStandardLabels` therefore never assumes
the race interpretation from the status code alone — it re-fetches the single
label (`GithubClient#label`) and records the label in `existing` only when
that fetch confirms it exists. A 422 whose verification comes back 404, or
whose verification call itself fails, is recorded in `errors`, so a caller
gating a control transition on `any_errors?` (e.g. `MarkEscalatedActivity`)
never proceeds without the label actually existing (@spec GH-LABELS-008).
The mirror race on the update side — another writer *deleting* the label
between our list and update calls — surfaces as a 404 on the update; it is
recorded in `errors` for that one label rather than aborting the remaining
labels' sync, and the next sync re-creates the label.

### What stays untouched

`expected_labels` is a closed list: only names resolved from the sources
above are ever created or updated. A repository's unrelated taxonomy labels
(`bug`, `documentation`, third-party bot labels, etc.) are never inspected
for divergence and never rewritten, because they never appear in that list.

### Rejecting cross-category name collisions before syncing

`expected_labels` is the union of every category's resolved labels (the four
configurable columns, `recommend_close`, the eight fixed constants, the
three TDD labels, the auto-pick skip list, the priority tiers). GitHub
treats label names case-insensitively for matching, so two categories that
resolve to the same name (e.g. `generated_label_name == "paid-auto-merged"`,
a custom priority tier reusing `paid-paused`, two priority tiers pointing
to the same name) would otherwise be processed twice and the later
`reconcile_divergence` would PATCH the shared label into whichever
definition ran last — a silent regression from the previous report-only
behavior.

To prevent that, `call` groups the expected entries by `name.downcase`
before any GitHub call: any group with more than one entry becomes one
`Result#errors` entry that names every category claiming that label, and
the colliding label is skipped from both creation and reconciliation so
the misconfiguration has to be fixed at the project level rather than
being silently overwritten. Cross-category collision detection is a closed
contract over the same canonical inventory, so a future category added to
`expected_labels` only has to emit a `category:` in its entry to be
covered (@spec GH-LABELS-007).

### Auto-pick skip labels are provisioned, not just matched

`AutoPickSkipLabels::DEFAULTS` (`planning`, `research`, `waiting`,
`tracking`, `epic`, `needs-manual-setup`) already gate auto-pick by matching
against an issue's synced `labels` array — that matching is unchanged. What
was missing is that nothing ever created these labels on GitHub with a
description explaining the auto-pick consequence, so a human applying
`planning` to an issue for an unrelated reason had no way to discover that it
also excludes the issue from auto-pick. `EnsureStandardLabels` now
provisions the project's `effective_auto_pick_skip_labels` (defaults or a
project/tenant/user override) with a per-default-label description, falling
back to a generic "excludes this issue from Paid auto-pick while applied"
description for a custom name. Provisioning treats these the same as any
other canonical label — including reconciling a stale description — because
the behavioral consequence exists regardless of who created the label or why.

### Provisioning trigger points

Full-catalog provisioning happens at the same two points it always has:
automatically, best-effort, when a project is connected
(`ProjectsController#ensure_labels_best_effort`, called from both project
creation paths), and on demand via the "Sync Labels" action
(`ProjectsController#ensure_labels`). This segment does not add a
per-write "ensure it exists" guard to every individual label-writing call
site (escalation, auto-merge, release automation, etc.) — GitHub's API
returning a 404 on an unrecognized label is a real but rare failure mode
once the full catalog exists, and duplicating a list-labels-and-create
round trip into every write call site would trade a rare, cheaply-recovered
failure for a GitHub API call on every automation write. Two narrow
exceptions stay in place:

- `FileModelHealthIssue` calls `create_label` defensively immediately before
  filing a model-health issue, because that label is filed by a background
  job with no "Sync Labels" UI trigger in its path.
- `MarkEscalatedActivity` calls `Projects::EnsureStandardLabels` and bails out
  if the sync reports any errors before it writes `paid-escalated` remotely
  or flips `Issue#pr_review_phase` locally. Escalation is a control-state
  transition whose recovery instructions explicitly depend on the label's
  presence on GitHub, so claiming the local phase without a remotely
  dismissible label would violate the user-visible contract. Only the sync
  bails: if the catalog synced cleanly but the subsequent label write itself
  fails transiently, the activity still escalates (the hold must reach the
  owner) and the escalated-phase scan re-applies the missing label, so remote
  state converges with the local phase
  (`pr-escalation-recovery` specs PR-ESCALATION-019/021).

## Code

- `app/services/projects/ensure_standard_labels.rb` — the canonical
  provisioning contract (`LABEL_DEFINITIONS`, `expected_labels`,
  reconciliation).
- `app/services/github_client.rb#update_label` — PATCH wrapper used for
  reconciliation.
- `app/models/issue.rb` — `ESCALATED_LABEL`, `DISMISS_ESCALATION_LABEL`
  (alongside the pre-existing `PAUSED_LABEL`).
- `app/services/models/file_model_health_issue.rb` — reads `LABEL_COLOR`/
  `LABEL_DESCRIPTION` from `EnsureStandardLabels::LABEL_DEFINITIONS` instead
  of duplicating them.
- `app/temporal/activities/mark_escalated_activity.rb` — fronts the
  `paid-escalated` transition with `EnsureStandardLabels` and aborts the local
  escalation when provisioning reports errors.
- `app/controllers/projects_controller.rb` — `ensure_labels` (manual sync)
  and `ensure_labels_best_effort` (project creation) call sites, unchanged.

Test: `spec/services/projects/ensure_standard_labels_spec.rb`,
`spec/services/github_client_spec.rb`,
`spec/temporal/activities/mark_escalated_activity_spec.rb`.

## What this segment does NOT own

- The auto-pick candidate-filtering logic that matches issue labels against
  `effective_auto_pick_skip_labels` (`Automation::Strategies::AutoPick`) —
  unchanged, tracked under the auto-pick-queue segment.
- The escalation state machine and dismissal detection
  (`Issue#clear_escalation!`, `ScanPaidPrsActivity#escalation_dismissed?`) —
  unchanged, tracked under pr-escalation-recovery.
- The TDD mode configuration and gate behavior — tracked under tdd-mode;
  this segment only owns the three labels' canonical color/description now
  that they live in the same `kind`-tagged catalog as everything else.
- Per-write existence guards on individual automation call sites (see
  "Provisioning trigger points" above for the rationale).
