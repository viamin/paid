---
parent: root
prefix: SETTINGS-COPY
---

# Design: Settings Visible Copy

Settings present configuration choices in terms of their behavior and
consequences. Internal decision-record identifiers, issue numbers, and
repository-specific example paths remain implementation documentation; they
are not operator-facing copy.

## Scope

This segment owns the visible copy for project screenshot verification, TDD
mode, existing design-document input, tenant chat controls, feature-flag
metadata rendered in tenant configuration, and shared decision-copy rules for
operator screens. It does not change setting keys, form values, feature-flag
names, rollout behavior, or runtime policy.

## Plain-language decision copy

Lead with the situation and the recommended next step. Use the fewest words
that retain uncertainty, authority, and material consequences. Name the
primary action for what it changes (for example, **Resume automatic work**),
not for the internal operation. Mark a recommended choice with “Recommended:”;
name a non-primary choice as an alternative and say when to use it. State
unknown as “Unknown” and say what will establish it rather than implying a
healthy or failed result.

Every mutating action states its effect before the control and, where relevant,
who may take it and what does not change. A confirmation repeats the material
effect. The default view uses plain-language labels, not raw JSON, internal
identifiers, database IDs, implementation names, or jargon where a translation
exists. Native `details`/`summary` is the standard expandable “Why?” or
“Technical details” disclosure: it remains keyboard-operable and announced to
screen readers. Put examples, implementation identifiers, policy detail, and
diagnostics there unless they are essential to choosing the next action.

| Situation | Before | After |
| --- | --- | --- |
| Decision | “Evaluation policy: solo” | “Recommended: start the review when you can make every judgment.” |
| Technical failure | “`missing_test_command`: command_not_found” | “This review cannot start yet. Resolve the recorded prerequisite, then return here.” |
| Wait state | “Bootstrap run pending” | “Setup is still running. You do not need to act yet.” |
| Mutating action | “Resume” | “Resume automatic work — this allows future automatic work; it does not start a run now.” |

## First delivery slice and audit

The audit covered the high-traffic decision surfaces: Inbox, project setup,
pull-request review, closeout, and evaluation. This delivery changes the
non-Inbox project-quality resume, readiness-evaluation start, and conformance-
evaluation start screens. Each keeps authorization and failure recovery visible
while moving diagnostics into native disclosure.

Inbox is covered by #4864 and remains outside this slice. Pull-request review
and closeout need focused follow-ups for their separate authority and evidence
models: #4883 and #4884. Desktop/mobile
readability and keyboard/screen-reader operation are checked against the native
disclosure markup; localization readiness keeps user-facing prose separate from
internal IDs and avoids composing sentences from fragments. Decision-time and
comprehension comparison require representative human observation and are not
claimed from automated tests.

## Verification plan

| Acceptance criterion | Evidence |
| --- | --- |
| Project and account settings render no Paid-owned RDR identifier or the old RDR path example | Request spec renders the project edit/show and tenant configuration pages, rejects RDR identifiers, and checks the generic design-document example. |
| Keys, values, flag names, and behavior remain unchanged | Focused request spec renders the existing controls; review the diff for copy-only changes. |
| Visible project, tenant, and feature-flag description copy is covered | The same request spec uses the real `FeatureFlags::DEFINITIONS` registry and asserts visible replacement copy. |
