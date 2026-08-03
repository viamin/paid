# EARS Specs: Free Model Catalog Routing Guardrails

> Testable claims for OpenRouter-backed free model routing and its audit trail.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r FREE-MODEL-001`).

- [x] **FREE-MODEL-001** — When the `openrouter_free` runner builds an
  execution plan, the system SHALL derive `provider_routing` from the
  project's `data_classification`, mapping `restricted` to
  `{ data_collection: "deny", zdr: true }`.
  *Code:* `Runners::FreeModelExecutionPlan`.

- [x] **FREE-MODEL-002** — When a selected free-model path is OpenRouter-routed,
  the data-classification guardrail SHALL record the effective provider-routing
  policy in the orchestration decision context, including `provider_zdr: true`
  for `restricted` projects.
  *Code:* `Guardrails::DataClassificationPolicy`.

- [x] **FREE-MODEL-003** — When a `confidential` or `restricted` project
  selects a free model with `data_training_risk: "possible"` outside an
  OpenRouter-routed path, the data-classification guardrail SHALL emit a
  warning and persist a system log describing the risk.
  *Code:* `Guardrails::DataClassificationPolicy`.
