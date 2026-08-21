# EARS Specs: Container Egress Allowlisting

> Testable claims for RDR-055 egress policy resolution. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a grep
> target across specs, tests, and code (`grep -r EGRESS-POLICY-001`).

- [x] **EGRESS-POLICY-001** — The system SHALL persist tenant-managed egress
  allowlist entries at account scope (null `project_id`) and project scope,
  and server-side validation SHALL accept only exact public hostnames and
  leading-wildcard subdomains, rejecting bare/nested/trailing wildcards,
  wildcard TLDs, URL paths, userinfo, inline ports, query strings, fragments,
  IP literals (private, loopback, link-local, and metadata), localhost names,
  single-label hosts, out-of-range ports, and schemes other than http/https.
  *Tests:* `spec/models/egress_allowlist_entry_spec.rb`,
  `spec/services/agent_runs/egress_policy/host_pattern_spec.rb`
  *Code:* `EgressAllowlistEntry`, `AgentRuns::EgressPolicy::HostPattern`

- [x] **EGRESS-POLICY-002** — The system SHALL provide a code-owned
  required-destination registry exposing platform destinations (egress
  gateway, secrets proxy resolved from the run's backend and networking
  policy via `Containers::ProxyUrl`), GitHub destinations (github.com,
  api.github.com), and runner/provider destinations, where provider hosts are
  resolved from the run's runner key (claude → Anthropic, codex → OpenAI,
  gemini → Google, copilot → GitHub Copilot, openrouter_free /
  openrouter_pareto → OpenRouter) or its configured direct-outbound API
  provider, and every container-executable runner key SHALL be classified
  (fixed-host, config-derived, or explicitly proxy-only) so direct-egress
  runner traffic never silently drops out of the registry. Registry drift
  (a pi/omp provider key with no mapped host, or a malformed
  direct-outbound `base_url`) SHALL raise at resolution rather than
  silently omitting required destinations from the snapshot.
  *Tests:* `spec/services/agent_runs/egress_policy/required_destinations_spec.rb`
  *Code:* `AgentRuns::EgressPolicy::RequiredDestinations`

- [x] **EGRESS-POLICY-003** — `AgentRuns::EgressPolicy::Resolve` SHALL return
  a snapshot resolved in deterministic merge order — platform, GitHub,
  provider (only for `subscription_auth`/`direct_outbound` modes), enabled
  account entries by id, enabled project entries by id, then run-local
  service and preview destinations — deduplicated by host+port with first
  occurrence winning, and each destination SHALL carry provenance (source,
  entry/service identifiers, reason). Run-local service destinations SHALL
  record the Docker network alias provisioning grants
  (`Containers::ServiceRuntimeNaming.runtime_name`, the host behind the run's
  `SERVICE_*_HOST` env vars), never the user-facing service name, so the
  snapshot matches the host the container can actually resolve.
  *Tests:* `spec/services/agent_runs/egress_policy/resolve_spec.rb`
  *Code:* `AgentRuns::EgressPolicy::Resolve`,
  `AgentRuns::EgressPolicy::Snapshot`

- [x] **EGRESS-POLICY-004** — Enabled account entries SHALL be inherited by
  every project run in the account, project entries SHALL extend (never
  replace) the inherited set, and neither scope SHALL be able to remove or
  shadow a platform-, GitHub-, or provider-required destination.
  *Tests:* `spec/services/agent_runs/egress_policy/resolve_spec.rb`
  *Code:* `AgentRuns::EgressPolicy::Resolve`

- [x] **EGRESS-POLICY-005** — Policy resolution SHALL defensively re-validate
  persisted allowlist entries before container startup: an unsafe entry is
  excluded from the snapshot's destinations, recorded in `denied_reason` with
  the entry id and rejection reason, and `Resolve.resolve_and_persist!` SHALL
  fail closed by raising `DeniedPolicyError` so no container starts under a
  policy containing an unsafe rule.
  *Tests:* `spec/services/agent_runs/egress_policy/resolve_spec.rb`,
  `spec/temporal/activities/provision_container_activity_spec.rb`
  *Code:* `AgentRuns::EgressPolicy::Resolve`

- [x] **EGRESS-POLICY-006** — `ProvisionContainerActivity` SHALL resolve and
  persist the egress policy snapshot to
  `agent_runs.external_metadata["egress_policy"]` before provisioning starts,
  so a run whose provisioning fails still carries an auditable record of the
  intended policy, including mode, egress profile, destinations, required
  destinations, and resolution timestamp. The secrets-proxy required
  destination SHALL be resolved against the run's planned container host and
  networking policy (restricted-local `paid-proxy`, unrestricted-local `web`,
  or the remote backend's external proxy URL), never hardcoded.
  *Tests:* `spec/temporal/activities/provision_container_activity_spec.rb`,
  `spec/services/agent_runs/egress_policy/resolve_spec.rb`
  *Code:* `AgentRuns::EgressPolicy::Snapshot`,
  `AgentRuns::EgressPolicy::Resolve`,
  `Activities::ProvisionContainerActivity`

- [ ] **EGRESS-POLICY-007** — The resolved snapshot SHALL be wired into
  `ExecutionRunners::NetworkingPolicy#allow_destinations` and enforced by a
  per-Docker-host egress gateway, with production restricted runs failing
  closed when enforcement cannot be applied. (RDR-055 steps 4–5; future work.)
