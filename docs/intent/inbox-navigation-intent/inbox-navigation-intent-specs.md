# EARS Specs: Inbox Detail Navigation-Intent Guard

> Testable claims for the CI guard that locks Turbo navigation intent onto
> every action rendered inside the `inbox-detail` frame (#4502). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r INBOX-NAV-INTENT-001`).

- [x] **INBOX-NAV-INTENT-001** — For every inbox kind dispatched by
  `app/views/dashboard/_inbox_detail.html.erb`, every internal `<a>` and
  every `<form>` rendered by the kind's partial MUST satisfy exactly one
  of three navigation-intent rules: (a) carry `data-turbo-frame="_top"`
  on the element (or on the `<form>` wrapping `button_to`/`form_with`
  submissions), (b) carry both `target="_blank"` and a `rel` containing
  `noopener` and `noreferrer` for an external destination, or (c) carry a
  `data-turbo-frame-spec-whitelist` value listed in
  `INBOX_DETAIL_WHITELISTED_EMBEDDED_FLOWS`, with a code comment in the
  partial explaining why the flow intentionally renders inside the frame.
  In-page anchors (`href` starting with `#`), blank anchors, and any
  element the guard walks but that already satisfies one of the rules
  SHALL be accepted without raising. The guard MUST walk every inbox
  kind (clarifying_questions, plan_review, merge_approval,
  action_required [including its issue / action_url / agent-run subject
  branches], escalated_pr [including its awaiting_approval and
  operational-failures branches], manual_review, intent_conformance,
  feature_decision, retry_limited, change_intent_draft, partial_closeout,
  test_review_pending, project_setup_pending, traceability_gap) so new
  kinds added to the dispatcher inherit the policy automatically.
  *Test:* `spec/views/dashboard/inbox_detail_navigation_intent_spec.rb`.
  *Code:* `spec/views/dashboard/inbox_detail_navigation_intent_spec.rb`
  (`assert_navigation_intent!`,
  `INBOX_DETAIL_WHITELISTED_EMBEDDED_FLOWS`).

- [x] **INBOX-NAV-INTENT-002** — The guard MUST bite: when a nonconforming
  `<a>` or `<form>` is added to the rendered inbox-detail fragment, the
  guard SHALL raise `InboxNavigationIntentViolation` naming the offending
  element; when a conforming `data-turbo-frame="_top"` element is added,
  the guard SHALL NOT raise. A non-whitelisted
  `data-turbo-frame-spec-whitelist` value (a marker whose `<name>` is not
  listed in `INBOX_DETAIL_WHITELISTED_EMBEDDED_FLOWS`) SHALL be treated as
  nonconforming for both anchors and forms, so a future contributor cannot
  bypass the guard by typing a one-off string with no name to grep for.
  The negative test, the positive test, the unwhitelisted-whitelist
  values for anchors, and the unwhitelisted-whitelist values for forms
  MUST all live next to the per-kind coverage in the same spec, so the
  bite guarantee is exercised on the same `assert_navigation_intent!`
  implementation the per-kind tests invoke.
  *Test:* `spec/views/dashboard/inbox_detail_navigation_intent_spec.rb`
  (`describe "guard bites on a nonconforming action (negative test)"`).
  *Code:* `spec/views/dashboard/inbox_detail_navigation_intent_spec.rb`
  (`assert_navigation_intent!`,
  `InboxNavigationIntentViolation`).
