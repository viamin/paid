---
parent: PAID
prefix: INBOX-NAV-INTENT
---

# Low-Level Design: Inbox Detail Navigation-Intent Guard

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment defines a CI guard that prevents "Content missing" regressions in
> the inbox-detail Turbo Frame by requiring every action rendered inside it
> to declare explicit Turbo navigation intent (issue #4502).

## Purpose

Turbo "Content missing" bugs in inbox detail panes keep recurring across
issues 3922, 3822, 4031, 4500, and 4501 because each new inbox kind must
remember to opt its actions out of the `inbox-detail` frame. Fixing them
one button at a time no longer scales, and ad hoc partial-by-partial
review lets the same class of regression re-introduce itself after every
inbox kind is added.

This segment locks the policy in at the test layer so the guard runs on
every CI build and a future reviewer cannot disable it through ordinary code
review.

## The three rules

The guard classifies every `<a>` and `<form>` element rendered by any inbox
detail partial through one of three mutually exclusive rules. Exactly one
must hold; the assertion fails otherwise.

1. **Intentional full-page navigation.** The element carries
   `data-turbo-frame="_top"` on itself (or, for `button_to`/`form_with`
   submissions, on the parent `<form>`). Turbo replaces the whole document,
   not just the `inbox-detail` frame, so a successful POST/PATCH/GET from
   inside the frame never strands a response with no matching frame.

2. **External link.** The element carries `target="_blank"` *and*
   `rel="noopener noreferrer"` and its `href` resolves to an absolute
   external `http(s)` URL. The scheme check is part of the rule, not a
   detail: `target="_blank"` on an in-app path is still internal
   navigation, so accepting it on the strength of the attribute pair alone
   would let a link quietly escape the frame while claiming to be
   conforming. The `noopener`/`noreferrer` pair is required so an
   inadvertently-shipped blanked-out link cannot navigate-in-place via the
   `target` change and leak referrer information.

3. **Whitelisted embedded flow.** The element carries a
   `data-turbo-frame-spec-whitelist="<name>"` marker, and `<name>` is
   listed in `INBOX_DETAIL_WHITELISTED_EMBEDDED_FLOWS`. Contributors
   cannot bypass the guard by typing a one-off string with no name to
   grep for — adding a new embedded flow is a deliberate, reviewed opt-in
   that requires the name to appear both on the element and in the
   whitelist constant, with a comment in the partial explaining why the
   flow intentionally renders inside the frame.

The same guard walks every inbox-kind partial dispatched by
`app/views/dashboard/_inbox_detail.html.erb` automatically — no per-kind
opt-in — so new inbox kinds inherit the policy without remembering to wire
it up. That inheritance is *enforced*, not asserted: each per-kind context
in the guard spec registers the kind it covers in
`INBOX_DETAIL_GUARDED_KINDS`, and a coverage canary fails CI when

- the recorded kinds no longer equal `Inbox::Queue::KINDS` (a kind with no
  context, or a context for a kind the queue dropped),
- a `*_KIND` constant exists outside `KINDS` (an unreachable kind nobody
  can guard), or
- a kind has no matching detail partial dispatched by the dispatcher, which
  would otherwise fall through the `else` fallback and render the
  `plan_review` partial under a kind it does not belong to. The canary
  verifies dispatched partial names rather than predicate text elsewhere in
  the template, because badge styling may mention kinds without dispatching
  their own partials.

## What this segment owns

- The three-rule navigation-intent policy described above, encoded as a
  CI view spec that renders every inbox kind and asserts every action in
  the rendered fragment carries one of the three markers.
- The whitelist constant
  (`INBOX_DETAIL_WHITELISTED_EMBEDDED_FLOWS`) that pins the names of
  intentionally-embedded flows to a grep target.
- The negative-test guarantee: a nonconforming element injected into the
  rendered fragment MUST raise `InboxNavigationIntentViolation`, and a
  conforming element MUST NOT — so the guard cannot be silently disabled
  by a future contributor who edits only the assertion's rule list.
- The coverage canary that ties the guard's per-kind contexts to
  `Inbox::Queue::KINDS` and to the dispatcher's matching detail partials, so
  "new kinds inherit the guard" stays true as the inbox grows.

## What this segment does NOT own

- The Inbox's broader two-pane desktop layout, the mobile master-detail
  flow, the Turbo Frame that hosts the detail pane, or the controller
  wiring that selects which entry is rendered — those live in
  `docs/intent/operator-inbox/` (`OPERATOR-INBOX-003`,
  `OPERATOR-INBOX-015`) and `docs/intent/list-detail-layout/`
  (`LIST-DETAIL-001`–`LIST-DETAIL-007`). This guard runs *on top of* that
  frame; it does not redefine it.
- The merging of new kinds into `Inbox::Queue` or the entry-shape contract
  every partial consumes — those remain segments of their respective
  lanes (e.g. `partial_closeout`, `change_intent_draft`). This guard
  pulls them in via the dispatcher in `_inbox_detail.html.erb`; new kinds
  inherit the policy by adding a new partial and being rendered by the
  shared `assert_navigation_intent!` walk — and the coverage canary fails
  CI until a per-kind context exists to walk them.
- The interaction model of embedded Turbo flows themselves (e.g. "Answer
  in chat" replacing the questions in place, or popup chat opening from
  the inbox). The whitelist is just a marker; the flow's UX is owned by
  `docs/intent/question-exploration/` and other downstream segments.
