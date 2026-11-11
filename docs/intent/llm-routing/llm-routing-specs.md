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
- [x] **LLM-ROUTING-005** — Standalone text calls SHALL execute through a
  disposable restricted container with no repository or Rails-workspace mount,
  using the selected runner, model, authentication mode, and harness provider;
  a subscription SHALL NOT silently switch to API billing.
- [x] **LLM-ROUTING-006** — A standalone isolated text request SHALL bound
  prompt and output size, deadline, cancellation, and egress; it SHALL remove
  its container after success, failure, timeout, provisioning failure, or
  worker interruption, and SHALL never fall back to host execution. Its
  worker-death orphan-sweep lifetime SHALL not expire during healthy reuse of
  the container. Post-run
  background summaries and diagnostics SHALL route independently of a cleaned-up environment.
- [x] **LLM-ROUTING-007** — Decision drafting SHALL honor the shared fallback
  permissions and each credential-specific runner's availability state. Invalid
  structured output SHALL be rejected without persisting malformed records or
  logging the raw provider payload.
