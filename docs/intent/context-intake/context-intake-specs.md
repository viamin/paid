# EARS Specs: Knowledge Context Intake

> Testable claims for project context-intake follow-up questions. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **CONTEXT-INTAKE-004** — When agent-harness returns a
  schema-constrained parsed follow-up-question response, the system SHALL use
  the parsed questions without text cleanup, then apply existing catalog
  normalization and validation. When required fields are missing, or the
  schema response is refused, invalid, or truncated, it SHALL create no
  questions. CLI/subscription callers SHALL retain their JSON parsing path
  until schema output is verified for that authentication mode and SHALL NOT
  be switched to API credentials.
  *Code:* `app/services/knowledge/context_intake/generate_questions.rb`.
  *Test:* `spec/services/knowledge/context_intake/generate_questions_spec.rb`.
