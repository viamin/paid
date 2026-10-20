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
  `noopener` and `noreferrer` for a destination whose `href` is an
  absolute `http(s)` URL, or (c) carry a
  `data-turbo-frame-spec-whitelist` value listed in
  `INBOX_DETAIL_WHITELISTED_EMBEDDED_FLOWS`, with a code comment in the
  partial explaining why the flow intentionally renders inside the frame.
  An in-app `href` SHALL NOT satisfy rule (b) regardless of `target` or
  `rel` — an internal link opened in a new tab is still internal
  navigation and must declare rule (a)'s `data-turbo-frame="_top"` or be
  reported as nonconforming.
  In-page anchors (`href` starting with `#`), blank anchors, and any
  element the guard walks but that already satisfies one of the rules
  SHALL be accepted without raising. The guard MUST walk every inbox
  kind (clarifying_questions, plan_review, merge_approval,
  action_required [including its issue / action_url / agent-run subject
  branches], escalated_pr [including its awaiting_approval and
  operational-failures branches], manual_review, intent_conformance,
  feature_decision, retry_limited, change_intent_draft, partial_closeout,
  test_review_pending, project_setup_pending, traceability_gap) so new
  kinds added to the dispatcher inherit the policy automatically, with
  that inheritance enforced by INBOX-NAV-INTENT-003.
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

- [x] **INBOX-NAV-INTENT-003** — The "new inbox kinds inherit the guard
  automatically" property MUST be enforced by CI, not asserted in prose.
  The set of inbox kinds this spec walks (each per-kind context registers
  the kind it covers in `INBOX_DETAIL_GUARDED_KINDS`) MUST equal
  `Inbox::Queue::KINDS` — a kind with no context, or a context for a kind
  the queue no longer defines, SHALL fail. Every `*_KIND` constant
  `Inbox::Queue` declares MUST appear in `KINDS`, since a kind missing from
  `KINDS` never reaches the inbox and therefore cannot be guarded. Every
  kind in `KINDS` MUST have a matching `dashboard/inbox_detail_<kind>`
  partial dispatched by `app/views/dashboard/_inbox_detail.html.erb`, so a
  kind whose branch is missing cannot fall through the `else` fallback and
  render the `plan_review` partial while passing CI. The check MUST derive
  dispatches from rendered partial names rather than `entry.<kind>?` text,
  because kinds also appear in unrelated badge-class predicates.
  *Test:* `spec/views/dashboard/inbox_detail_navigation_intent_spec.rb`
  (`describe "coverage canary"`).
  *Code:* `spec/views/dashboard/inbox_detail_navigation_intent_spec.rb`
  (`INBOX_DETAIL_GUARDED_KINDS`).
