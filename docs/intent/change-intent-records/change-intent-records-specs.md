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

- [ ] **CHANGE-INTENT-004** — When issue enhancement or other issue-scoped
  intake surfaces encounter constraint-heavy human direction, the system SHALL
  offer a Change Intent Record creation path instead of limiting capture to
  chat-only sessions.

- [D] **CHANGE-INTENT-005** — Heuristics for automatically suggesting that a
  direction is CIR-worthy may expand over time, but the current contract
  remains explicit human confirmation of a drafted record.
