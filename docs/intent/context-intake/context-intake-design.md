---
parent: PAID
prefix: CONTEXT-INTAKE
---

# Low-Level Design: Knowledge Context Intake

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the project-scoped questionnaire used to collect business
> context and its agent-generated follow-up questions.

## Generated follow-up questions

`Knowledge::ContextIntake::GenerateQuestions` asks agent-harness for at most
three follow-up questions using project metadata, answered responses, and
recent knowledge artifacts. Each accepted payload is normalized into the
existing question catalog, where existing key uniqueness, parent-question,
section, ordering, review-status, and tenant/project boundaries remain domain
responsibilities.

The generator declares a JSON response schema. Where agent-harness returns a
schema-constrained parsed value, it consumes that value without fence/quote
cleanup while retaining catalog validation. The default Claude CLI/subscription
caller remains on its existing JSON parsing path because the verified
agent-harness schema transport requires API-key authentication. This is an
explicit retained path, not a fallback that changes credentials or billing.

Malformed legacy text, schema refusal, invalid JSON, truncation, missing
required fields, and provider errors create no questions and log the existing
safe failure metadata.
