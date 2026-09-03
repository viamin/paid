---
parent: PAID
prefix: FREE-MODEL
---

# Low-Level Design: Free Model Catalog Routing Guardrails

> Companion to [`docs/high-level-design.md`](../../high-level-design.md) and
> [RDR-038](../../rdrs/RDR-038-free-models-catalog-and-runner.md). This LLD
> covers the security-sensitive routing contract for OpenRouter-backed free
> model execution and the audit trail emitted during model selection.

## Purpose

Paid's free-policy runners (direct-outbound runners with `model_policy:
"free"` — RDR-065, #3671) are useful only if the privacy guarantees the
user configures at the project level are enforced consistently in two places:

1. **Execution** — the request sent to OpenRouter must carry the correct
   `provider` routing options for the project's `data_classification`.
2. **Audit / guardrails** — the selection-time decision record must describe
   the same routing contract so operators can verify what policy was applied.

If these two paths drift, a `restricted` project could execute with Zero Data
Retention enabled while the audit trail incorrectly reports only
`data_collection=deny`, obscuring the stronger privacy posture.

## Shared Routing Contract

`Runners::OpenRouterDataRouting` is the single source of truth for mapping
`Project#data_classification` to OpenRouter provider routing options:

| Classification | Routing |
|---|---|
| `open` | `{ data_collection: "allow" }` |
| `internal` | `{ data_collection: "allow" }` |
| `confidential` | `{ data_collection: "deny" }` |
| `restricted` | `{ data_collection: "deny", zdr: true }` |

Any component that needs to express OpenRouter routing for OpenRouter-routed
work must use this shared mapping rather than re-encoding part of it locally.

## Enforcement Points

### Execution plan

`Runners::FreeModelExecutionPlan` builds the direct-outbound runtime for any
free-policy runner. OpenRouter-backed specific-model direct-outbound runs
reuse the same routing mapping when they build their runtime. The plan or
runtime includes:

- the selected model id,
- the OpenRouter base URL,
- the `OPENROUTER_API_KEY` env binding,
- and `provider_routing`, derived from the shared routing contract.

### Guardrail / decision log

`Guardrails::DataClassificationPolicy` runs during selection. It has two jobs:

1. warn when a sensitive project (`confidential` or `restricted`) selects a
   free model with possible training risk outside an OpenRouter-routed path;
2. record the effective OpenRouter routing policy in the orchestration
   decision context whenever the selected path is OpenRouter-routed,
   including specific OpenRouter-backed `opencode` runs.

For `restricted` projects, that recorded context must include `provider_zdr:
true` in addition to `provider_data_collection: "deny"`.

## What this is not

- **Not a per-model privacy database.** The enforcement mechanism is OpenRouter
  provider routing, not a curated allow/block list of individual models.
- **Not a blocking guardrail for non-OpenRouter paths.** The policy warns and
  records context; it does not prevent selection outright.
