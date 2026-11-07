# EARS Specs: Inbox Decision Brief

- [x] **INBOX-DECISION-BRIEF-001** — When the system renders any Inbox
  entry, it SHALL derive a reusable decision brief from the entry's current
  structured state via `Inbox::DecisionBrief`, covering every
  `Inbox::Queue::KINDS` kind, without a render-time LLM call, and the web
  list, web detail, API serializer, and contextual chat SHALL consume that
  same contract.
  *Code:* `app/services/inbox/decision_brief.rb`.
  *Test:* `spec/services/inbox/decision_brief_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-002** — When the system renders an Inbox list
  row, the row SHALL name the project, the work item, the decision or action
  needed, and the impact in plain language, and the list-mode brief SHALL
  issue no database query or remote call per row.
  *Code:* `app/views/dashboard/_inbox_list.html.erb`,
  `app/services/inbox/decision_brief.rb`.
  *Test:* `spec/requests/inbox_decision_brief_spec.rb`,
  `spec/services/inbox/decision_brief_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-003** — When the system renders a selected
  Inbox detail, the top of the pane SHALL identify the current goal or
  agreed intent, what changed, the exact decision or action, Paid's
  recommendation with its rationale when supported, and what happens after
  the action; one primary action SHALL be visually clear and alternatives
  secondary.
  *Code:* `app/views/dashboard/_inbox_decision_brief.html.erb`,
  `app/views/dashboard/_inbox_detail.html.erb`.
  *Test:* `spec/requests/inbox_decision_brief_spec.rb`,
  `spec/system/dashboard_inbox_decision_brief_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-004** — When a brief carries a question, the
  system SHALL render it as an element separate from explanations, and when
  no recommendation can be grounded, the brief SHALL disclose what is
  unknown and ask at most one focused question. Default brief copy SHALL
  exclude unexplained internal terms, raw JSON, hashes, and policy slugs.
  *Code:* `app/services/inbox/decision_brief.rb`,
  `app/views/dashboard/_inbox_decision_brief.html.erb`.
  *Test:* `spec/services/inbox/decision_brief_spec.rb`,
  `spec/requests/inbox_decision_brief_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-005** — When the system renders a selected
  detail brief with evidence, the evidence, examples, and technical history
  SHALL be retained behind a clearly named expandable disclosure.
  *Code:* `app/views/dashboard/_inbox_decision_brief.html.erb`.
  *Test:* `spec/requests/inbox_decision_brief_spec.rb`,
  `spec/system/dashboard_inbox_decision_brief_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-006** — When the system derives a
  recommendation, it SHALL base it only on current structured state and
  evidence, and SHALL disclose stale, unavailable, or conflicting evidence
  in `unknowns` instead of presenting it as certainty.
  *Code:* `app/services/inbox/decision_brief.rb`.
  *Test:* `spec/services/inbox/decision_brief_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-007** — When the API renders an Inbox entry,
  the detail payload SHALL include the full brief and the list payload SHALL
  include the list-safe brief subset, and the contextual chat context SHALL
  expose the same brief contract for a resolvable entry.
  *Code:* `app/serializers/api/v1/inbox_entry_serializer.rb`,
  `app/services/inbox/chat_context.rb`.
  *Test:* `spec/serializers/api/v1/inbox_entry_serializer_spec.rb`,
  `spec/services/inbox/chat_context_spec.rb`.

- [x] **INBOX-DECISION-BRIEF-008** — After an operator acts on an Inbox
  item, the system SHALL return to the filtered Inbox and present the next
  relevant entry with its own project, goal, and last agreed decision
  visible in its brief, preserving the operator's filters, without
  requiring context from the previously acted item, and without altering
  the lanes' authorization, revision, or action semantics.
  *Code:* `app/services/inbox/decision_brief.rb`,
  `app/controllers/projects/clarifying_questions_controller.rb`.
  *Test:* `spec/requests/inbox_decision_brief_spec.rb`.
