# Low-Level Design: Automation Activation Labels

> parent: docs/high-level-design.md
> prefix: AUTOMATION-ACTIVATION

## Purpose

Paid already has per-item subtractive control labels (`paid-paused`,
`paid-skip-auto-merge`, auto-pick skip labels). This segment adds the
additive counterpart: activation labels that turn a feature on for one issue or
pull request when the project-level setting is otherwise off.

## Activation model

Activation labels are stored as configurable names in one JSONB map,
`feature_activation_labels`, on `projects`, `user_settings`, and
`tenant_settings`. Resolution mirrors `auto_pick_skip_labels`:

1. project override
2. project owner user-setting override
3. tenant-setting override
4. built-in defaults

`nil` means inherit. An empty hash is an explicit override that disables the
built-in activation-label defaults at that level.

## Canonical features

The built-in map provides these defaults:

- `paid_in_full` → `paid-in-full`
- `auto_pick` → the project's `automation_label_name` (`paid-automation` by
  default) — they are the same trigger, so a project with a customized
  automation label does not grow a second, differently-named trigger label
- `auto_enhance` → `paid-enhance`
- `auto_merge` → `paid-auto-merge`
- `auto_scan_prs` → `paid-scan`
- `auto_scan_security` → `paid-scan-security`
- `auto_fix_merge_conflicts` → `paid-fix-conflicts`
- `auto_release` → `paid-auto-release`
- `tdd_strict` → `paid-tdd-strict`
- `tdd_auto` → `paid-tdd-auto`

`Projects::EnsureStandardLabels` is the canonical provisioning contract for the
resolved names, under a new label `kind: :activation`. When the auto-pick
activation label resolves to `automation_label_name`, the label is provisioned
once under the automation-label definition rather than twice (which would trip
the cross-category collision guard).

## Precedence

The activation resolver is mechanical and shared:

1. Skip beats activate. If an issue carries any effective auto-pick skip label,
   issue-scoped activation labels do not start work for that issue.
2. Specific beats catchall. A specific feature activation label overrides the
   `paid-in-full` catchall for the same work item. In particular,
   `paid-tdd-auto` overrides `paid-in-full`'s strict TDD default.
3. Additive only. When the project setting is already on, the activation label
   is not required and does not narrow automation to labeled items only. The
   PR scan set is the exception: with `auto_scan_prs` on it stays exactly the
   pre-activation-label set (open PRs carrying the automation label); the
   activation-label path widens the scan set only when the scan setting is
   off.
4. Trusted label application is required. Activation labels that cause Paid to
   spend money are honored only when `Automation::LabelPolicy` confirms that a
   project-trusted GitHub user applied the activating label.
5. Item-less runs keep project defaults. Label-based overrides apply only when
   an issue or parent issue is present; runs without either (e.g. manual
   `create_pr` runs with a custom prompt) keep the project-level setting, so a
   strict/non-strict project TDD mode still governs them.
6. The label master switch still gates. The issue-side activation path still
   requires `automation_on_label_enabled`; a project that turned label-triggered
   automation off (e.g. the `observe_only` configuration profile) is not
   re-armed by an activation label. That setting deliberately has no activation
   label of its own.

## Catchall behavior

`paid-in-full` applies to issues and activates the issue-to-PR path:

- auto-pick / explicit issue start
- issue enhancement
- strict TDD
- PR scanning / follow-up
- security scanning
- merge-conflict fixing
- auto-release

It does not activate auto-merge by itself. Auto-merge requires both
`paid-in-full` on the source issue and `paid-auto-merge` on the pull request,
or the normal project-level auto-merge setting.

LID work is not an activation toggle. `paid-in-full` only causes the LID steps
already required by the project to run, and only when `projects.lid_mode` is
present (`full` or `scoped`).
