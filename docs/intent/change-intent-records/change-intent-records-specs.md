# EARS Specs: Change Intent Records

> Testable claims for Change Intent Record creation, activation, and retrieval.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r CHANGE-INTENT-001`).

- [x] **CHANGE-INTENT-001** — When a project-scoped chat session calls
  `record_change_intent`, the system SHALL create a draft Change Intent Record
  linked to the current project and, when available, the current issue context.
  *Code:* `app/mcp/tools/record_change_intent.rb`.
  *Test:* `spec/mcp/tools/record_change_intent_spec.rb`.

- [x] **CHANGE-INTENT-002** — When a human approves a drafted Change Intent
  Record, the system SHALL activate it and synchronize it into the knowledge
  artifact pipeline; when the human denies it, the draft SHALL be discarded.
  *Code:* `app/mcp/tools/record_change_intent.rb`,
  `app/services/change_intents/activate.rb`.
  *Test:* `spec/mcp/tools/record_change_intent_spec.rb`.

- [x] **CHANGE-INTENT-003** — When a project has active or draft Change Intent
  Records, context-bundle assembly SHALL include them after stronger decision
  artifacts so future agent prompts can reuse the directional intent.
  *Code:* `app/services/knowledge/context_bundle/build.rb`.
  *Test:* `spec/services/knowledge/context_bundle/build_spec.rb`.

- [x] **CHANGE-INTENT-004** — When issue enhancement or other issue-scoped
  intake surfaces encounter constraint-heavy human direction, the system SHALL
  offer a Change Intent Record creation path instead of limiting capture to
  chat-only sessions.
  *Code:* `app/temporal/activities/enhance_issue_activity.rb`,
  `app/services/change_intents/draft_from_issue.rb`,
  `app/controllers/projects/change_intents_controller.rb`.
  *Test:* `spec/temporal/activities/enhance_issue_activity_spec.rb`,
  `spec/services/change_intents/draft_from_issue_spec.rb`,
  `spec/requests/projects/change_intents_spec.rb`.

- [D] **CHANGE-INTENT-005** — Heuristics for automatically suggesting that a
  direction is CIR-worthy may expand over time, but the current contract
  remains explicit human confirmation of a drafted record.

- [x] **CHANGE-INTENT-INBOX-001** — When a draft Change Intent Record exists
  in `draft` or `requested_changes` status on a project the operator can see,
  the system SHALL surface it as a `change_intent_draft` Inbox entry with the
  CIR's title, intent, behavior, constraints, rejected alternatives, and (for
  `requested_changes`) the operator's review reason and timestamp. The entry
  SHALL clear when the record transitions to `active`, `superseded`, or
  `reverted`. Approving from the Inbox (`Projects::ChangeIntentsController#approve`)
  SHALL activate the draft and synchronize the record into the knowledge
  artifact pipeline (`ChangeIntents::Activate`); requesting changes
  (`#request_changes`, backed by `ChangeIntents::RequestChanges`) SHALL keep
  the entry actionable in the `requested_changes` state with the operator's
  reason and review timestamp stamped on the record itself. The Inbox detail
  pane SHALL expose an inline `Chat about this` button that opens the
  canonical interactive chat session for the entry via the existing
  `Inbox::OpenInteractiveChat` flow, so a follow-up chat or MCP-driven
  revision overwrites the draft in place and the operator can re-approve.
  Approve, discard, and request-changes actions SHALL honour a
  `return_to` parameter scoped to `/inbox…` and otherwise fall back to the
  pre-inbox project page, so the bell/notification surface is never invoked.
  `Inbox::Count`'s cached badge SHALL invalidate on transitions into and out
  of the lane via `ChangeIntent`'s `after_commit :bump_inbox_cache_version`
  callback, so the nav badge tracks `pending_review` records.
  *Code:* `app/models/change_intent.rb`,
  `app/services/change_intents/request_changes.rb`,
  `app/services/change_intents/activate.rb`,
  `app/controllers/projects/change_intents_controller.rb`,
  `app/services/inbox/queue.rb`, `app/services/inbox/count.rb`,
  `app/views/dashboard/_inbox_detail_change_intent_draft.html.erb`,
  `app/views/inbox/index.html.erb`, `config/routes.rb`,
  `app/helpers/inbox/path_helper.rb`.
  *Test:* `spec/models/change_intent_spec.rb`,
  `spec/services/change_intents/request_changes_spec.rb`,
  `spec/services/inbox/queue_spec.rb`, `spec/services/inbox/count_spec.rb`,
  `spec/requests/projects/change_intents_spec.rb`,
  `spec/requests/inbox_spec.rb`.
