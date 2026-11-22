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
  selected authentication mode, identify standalone application requests as
  text operations to the harness, make the selected API credential available
  to provider-owned transport selection without exposing it in Docker exec
  environment entries, and validate structured output locally.
- [x] **LLM-ROUTING-004** — Persisted model provenance SHALL identify the actual
  model returned by the selected runner rather than a hardcoded vendor model.
- [x] **LLM-ROUTING-005** — Standalone text calls SHALL execute through a
  disposable restricted container with no repository or Rails-workspace mount,
  using the selected runner, model, authentication mode, and harness provider;
  a subscription SHALL NOT silently switch to API billing.
- [x] **LLM-ROUTING-006** — A standalone isolated text request SHALL bound
  prompt and output size, deadline, cancellation, and egress. Its container SHALL
  have a 1 GiB memory limit with no additional swap allowance while preserving
  CPU and process limits (#5206), a 256 MiB private home tmpfs and a separate
  64 MiB temporary tmpfs (#5211); it SHALL remove
  its container after success, failure, timeout, provisioning failure, or
  worker interruption, and SHALL never fall back to host execution. Its
  worker-death orphan-sweep lifetime SHALL not expire during healthy reuse of
  the container. Request input SHALL reach the container through an upgraded
  Docker exec stdin connection that verifies its declared length and waits for command completion; a missing
  exec exit status SHALL fail explicitly. The container root filesystem SHALL
  remain read-only. Harness preparation paths beginning with `~/` SHALL resolve
  within the container user's home before validation and materialization.
  Post-run
  background summaries and diagnostics SHALL route independently of a cleaned-up environment.
- [x] **LLM-ROUTING-007** — Decision drafting SHALL honor the shared fallback
  permissions and each credential-specific runner's availability state. Invalid
  structured output SHALL be rejected without persisting malformed records or
  logging the raw provider payload.
- [x] **LLM-ROUTING-008** — When a post-push source-closure assessment cannot
  complete with the run's pinned runner, it SHALL try the owning user's enabled,
  configured, policy-permitted fallback runners within the assessment activity
  deadline before parking the run. Disabled fallbacks SHALL not authorize a
  different runner or billing mode. A subscription runner without an active
  managed credential SHALL be skipped before provisioning a text container; if
  no usable runner remains, routing SHALL report a configuration failure.
- [x] **LLM-ROUTING-009** — The application SHALL keep a source-checked
  inventory of every non-chat direct or wrapped `Llm::Request` caller. The
  inventory SHALL classify project-only, account-only, live-run, and post-run
  work and require all of them to use the isolated text route, including when
  a persisted run container handle is stale or absent.

- [x] **LLM-ROUTING-010** — Runner readiness and issue-analysis selection
  SHALL report and admit a subscription only when an active managed credential
  permits the isolated text executor to materialize that subscription inside
  its disposable container. An uncredentialed subscription SHALL report
  `missing_credential`, be excluded from isolated-text candidates, and never
  trigger host CLI execution or API-key billing substitution.

- [x] **LLM-ROUTING-011** — Before excluding a rotating managed subscription
  credential from isolated text routing, the system SHALL distinguish an expired
  but refreshable unrevoked credential from missing or revoked authentication.
  The former SHALL reach the provider-owned serialized refresh lifecycle at
  every isolated-text routing and readiness surface; only
  a fresh result may be materialized. A Test Runner result using host-forwarded
  authentication SHALL identify that source and SHALL NOT imply standalone
  managed-audit readiness.
  A newer expired credential that cannot refresh SHALL NOT shadow an older fresh
  credential at those surfaces.
  *Tests:* `spec/services/llm/request_spec.rb`,
  `spec/requests/api/standalone_text_credentials_spec.rb`,
  `spec/services/runners/managed_credential_lifecycle_spec.rb`.
  *Code:* `Llm::Request`, `Runners::ManagedCredentialLifecycle`,
  `Api::StandaloneTextCredentialsController`.

- [x] **LLM-ROUTING-012** — For a bounded report-only acceptance request,
  `Llm::Request` SHALL retain at most five safe route-attempt entries: owned
  runner identity, resolved provider and model when execution began, ordinal,
  allocated and elapsed time, execution phase or `unknown`, normalized outcome,
  and request correlation identifiers. Candidates not executed because policy,
  availability, credentials, or the total deadline prevented execution SHALL be
  marked `skipped`. The terminal raised failure SHALL identify the actual
  producing attempt; permanent authentication/configuration failures retain
  their existing precedence over transient failures. No entry may contain a
  prompt, response, credential, URL, HTTP body, or unbounded error text.
  *Tests:* `spec/services/llm/request_spec.rb`,
  `spec/services/llm/analyze_partial_closeout_spec.rb`.

- [x] **LLM-ROUTING-013** — An isolated text request SHALL carry one finite
  monotonic deadline from `Llm::Request` into each candidate executor. Candidate
  setup, credential materialization or refresh, command execution, output
  handling, and cleanup SHALL consume that candidate's allocation within the
  shared request deadline. The executor SHALL reserve a bounded cleanup margin
  before beginning command execution; setup that consumes the executable budget
  SHALL not receive a new command allocation, and an exhausted shared deadline
  SHALL not start a fallback. Physical cleanup remains best-effort. Managed
  credential lease acquisition and the container rotation read SHALL be bounded
  by the remaining candidate deadline; an incomplete read SHALL be deferred and
  logged without extending the candidate lifetime. Once a native rotation has
  been read, persistence that cannot finish by the candidate deadline SHALL
  transfer the captured rotation and its lease to a bounded recovery write. The
  request SHALL return at its deadline; recovery SHALL either persist the
  captured rotation atomically or report a deferred harvest without dropping,
  overwriting, or exposing the credential.
  *Tests:* `spec/services/llm/request_spec.rb`,
  `spec/services/containers/standalone_text_executor_spec.rb`.
