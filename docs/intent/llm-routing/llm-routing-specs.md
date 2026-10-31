# Application LLM routing specifications

- [x] **LLM-ROUTING-001** — Application text operations SHALL select an
  explicitly configured runner through `Llm::Request`, using the effective
  run runner or the owning user's chat preferences and permitted configured
  alternatives, without hardcoding an application provider or vendor model.
- [x] **LLM-ROUTING-002** — Routing SHALL respect tenant ownership, runner
  usage permissions, and project model policy; missing configuration SHALL
  fail explicitly without consulting another tenant or implicit host provider.
- [x] **LLM-ROUTING-003** — Text generation and JSON assessments SHALL support
  both API-key and subscription runners through `agent_harness`, preserve
  selected authentication mode, and validate structured output locally.
- [x] **LLM-ROUTING-004** — Persisted model provenance SHALL identify the actual
  model returned by the selected runner rather than a hardcoded vendor model.
- [x] **LLM-ROUTING-005** — Standalone text calls SHALL execute a CLI only when
  its driver supports disabling tools, with external-sandbox bypass disabled.
  Other drivers SHALL use the selected runner's API credentials through the
  harness API transport, or fail explicitly requiring an isolated environment;
  a subscription SHALL NOT silently switch to API billing. Candidate widening
  SHALL retain credential-specific routing identifiers and exclude a
  non-standalone subscription when an owned API-key credential is available.
- [x] **LLM-ROUTING-006** — An isolated text request timeout SHALL terminate
  the request process without stopping the run environment. Post-run background
  summaries and diagnostics SHALL route independently of the cleaned-up environment.
- [x] **LLM-ROUTING-007** — Decision drafting SHALL honor the shared fallback
  permissions and each credential-specific runner's availability state. Invalid
  structured output SHALL be rejected without persisting malformed records or
  logging the raw provider payload.
