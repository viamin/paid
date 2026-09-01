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
  `paid-auto-merged`, `paid-auto-merged-dependabot`, `paid-auto-released`).
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
  (`recommend_close`), `priority_labels` (P1/P2/P3), and
  `effective_auto_pick_skip_labels` (project → user → tenant → the
  `AutoPickSkipLabels::DEFAULTS` fallback). Reconciling these labels by their
  *configured* name — not a hard-coded one — is what keeps custom label
  names working without Paid creating or touching a differently-named label
  the project didn't ask for.
- **Hard-coded, cross-file canonical constants** — `Issue::ESCALATED_LABEL`,
  `Issue::DISMISS_ESCALATION_LABEL`,
  `Automation::Strategies::AutoMerge::SKIP_AUTO_MERGE_LABEL`,
  `Activities::MergePullRequestActivity::PAID_AUTO_MERGED_LABEL`,
  `DependabotAutoMergeJob::PAID_AUTO_MERGED_LABEL`,
  `AutoReleaseEvaluationJob::PAID_AUTO_RELEASED_LABEL`,
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
failure for a GitHub API call on every automation write. `FileModelHealthIssue`
keeps its existing narrow exception to this: it calls `create_label`
defensively immediately before filing a model-health issue, because that
label is filed by a background job with no "Sync Labels" UI trigger in its
path.

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
- `app/controllers/projects_controller.rb` — `ensure_labels` (manual sync)
  and `ensure_labels_best_effort` (project creation) call sites, unchanged.

Test: `spec/services/projects/ensure_standard_labels_spec.rb`,
`spec/services/github_client_spec.rb`.

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
