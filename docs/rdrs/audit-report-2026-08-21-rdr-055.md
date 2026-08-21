# RDR-055 Audit Report — 2026-08-21 Closeout

- **RDR**: [RDR-055: Agent Container Egress Allowlisting](RDR-055-agent-container-egress-allowlisting.md)
- **Audit date**: 2026-08-21
- **Umbrella issue**: [#3441](https://github.com/viamin/paid/issues/3441) (remains open pending the remaining RDR-055 gaps)
- **Conclusion**: Partially Implemented. Steps 1, 2, 3, 4, and 7 of the
  RDR-055 implementation plan are shipped and covered by passing spec suites
  (see [Validation Evidence](#validation-evidence)). EARS specs
  `EGRESS-POLICY-001` through `EGRESS-POLICY-006` and `CONTAINER-RUNTIME-020`
  are implemented and `@spec`-annotated on the relevant code/tests. Steps 5
  and 6 (per-host egress gateway + production fail-closed enforcement and
  brokered research) remain open and are tracked by [#3438](https://github.com/viamin/paid/issues/3438)
  and [#3439](https://github.com/viamin/paid/issues/3439). The umbrella
  [#3441](https://github.com/viamin/paid/issues/3441) stays open because
  [#3434](https://github.com/viamin/paid/issues/3434),
  [#3435](https://github.com/viamin/paid/issues/3435),
  [#3438](https://github.com/viamin/paid/issues/3438), and
  [#3439](https://github.com/viamin/paid/issues/3439) remain open in the
  dependency chain.

## Validation Evidence

Executed during the 2026-08-21 closeout audit recorded against umbrella issue
[#3441](https://github.com/viamin/paid/issues/3441). The umbrella remains
open because the remaining RDR-055 gaps are still tracked in its blocking
dependencies. All suites passed in full; no failures, no pending examples.

```console
$ bundle exec rspec \
    spec/services/agent_runs/egress_policy/host_pattern_spec.rb \
    spec/services/agent_runs/egress_policy/required_destinations_spec.rb \
    spec/services/agent_runs/egress_policy/resolve_spec.rb \
    spec/models/egress_allowlist_entry_spec.rb \
    spec/models/egress_security_event_spec.rb \
    spec/temporal/activities/provision_container_activity_spec.rb \
    spec/requests/account_egress_allowlist_entries_spec.rb \
    spec/requests/projects/egress_allowlist_entries_spec.rb \
    spec/migrations/expand_egress_allowlist_entries_for_audit_and_ui_dbless_spec.rb
147 examples, 0 failures

$ bundle exec rspec \
    spec/services/execution_runners_spec.rb \
    spec/services/execution_runners/local_docker_runner_spec.rb \
    spec/services/containers/provision_spec.rb
509 examples, 0 failures
```

## Acceptance Criteria vs. Shipped Implementation

### Criterion 1: A project admin can add, disable, and delete project allowlisted domains without editing deployment config

**Status**: Implemented.

**Shipped**:

- The persisted `egress_allowlist_entries` table with account scope (null
  `project_id`) and project scope, plus the `EgressAllowlistEntry` model
  with the shared `AgentRuns::EgressPolicy::HostPattern` validator:
  `app/models/egress_allowlist_entry.rb:11-78`,
  `app/services/agent_runs/egress_policy/host_pattern.rb:16-89`.
- The shared validator rejects bare/nested/trailing wildcards, wildcard
  TLDs, URL paths, userinfo, inline ports, query strings, fragments,
  IP literals (private, loopback, link-local, and metadata IPs), localhost
  names, single-label hosts, out-of-range ports, and schemes other than
  `http`/`https`:
  `app/services/agent_runs/egress_policy/host_pattern.rb:28-50`.
- Account-scoped CRUD exposes add/disable/delete without touching
  deployment config:
  `app/controllers/accounts/egress_allowlist_entries_controller.rb:16-93`.
- Project-scoped CRUD exposes add/disable/delete without touching
  deployment config:
  `app/controllers/projects/egress_allowlist_entries_controller.rb:14-101`.

**Tests**:

- `spec/models/egress_allowlist_entry_spec.rb` — model validation,
  write-time rejection of unsafe rules, scope queries, account inheritance
- `spec/services/agent_runs/egress_policy/host_pattern_spec.rb` — shared
  validator behavior (single source of truth)
- `spec/requests/account_egress_allowlist_entries_spec.rb` — controller
  request coverage
- `spec/requests/projects/egress_allowlist_entries_spec.rb` — controller
  request coverage

**Verdict**: Implemented.

---

### Criterion 2: An account admin can define account-wide domains inherited by projects

**Status**: Implemented.

**Shipped**:

- Account-wide entries (null `project_id`) are loaded by the resolver
  alongside project entries, in deterministic id order, so the inherited
  set is the source of truth before any project extension:
  `app/services/agent_runs/egress_policy/resolve.rb:175-187`.
- Account-scoped CRUD (see Criterion 1) plus the
  `EgressAllowlistEntry#account_level?` / `for_account(account)` /
  `account_wide` / `for_project(project)` scopes provide the inheritance
  surface: `app/models/egress_allowlist_entry.rb:24-29`,
  `app/models/egress_allowlist_entry.rb:43-49`.

**Tests**:

- `spec/services/agent_runs/egress_policy/resolve_spec.rb` — account-set
  is loaded before project-set; project entries extend (never replace) the
  inherited set
- `spec/models/egress_allowlist_entry_spec.rb` — `account_wide`,
  `for_account`, `for_project` scope coverage

**Verdict**: Implemented.

---

### Criterion 3: An agent run records its effective egress policy before provisioning

**Status**: Implemented.

**Shipped**:

- `ProvisionContainerActivity` calls
  `AgentRuns::EgressPolicy::Resolve.resolve_and_persist!(agent_run, container_host: input[:container_host])`
  before any Docker provisioning work, so the snapshot is on the run even
  if the subsequent provision fails:
  `app/temporal/activities/provision_container_activity.rb:46-72`.
- The snapshot is persisted to
  `agent_runs.external_metadata["egress_policy"]` via
  `Snapshot#persist!`:
  `app/services/agent_runs/egress_policy/snapshot.rb:67-72`.
- The secrets-proxy destination is resolved against the planned container
  host and networking policy (restricted-local `paid-proxy`,
  unrestricted-local `web`, or the remote backend's external proxy URL)
  via `Containers::ProxyUrl.resolve`, not a hardcoded value:
  `app/services/agent_runs/egress_policy/resolve.rb:107-118`,
  `app/services/containers/proxy_url.rb:31-50`.

**Tests**:

- `spec/temporal/activities/provision_container_activity_spec.rb` —
  `Resolve.resolve_and_persist!` is called before `provision_container`;
  snapshot is on the run even when downstream provisioning raises
- `spec/services/agent_runs/egress_policy/resolve_spec.rb` — snapshot
  `to_h`/`from_h`/`persist!`/`from_record` round-trip, plus the
  secrets-proxy destination reflects the policy and backend

**Verdict**: Implemented.

---

### Criterion 4: Proxy-mode runs can reach Paid-required endpoints, GitHub, service containers, and approved tenant domains, but not arbitrary public hosts

**Status**: Implemented.

**Shipped**:

- Required destinations (egress gateway, secrets proxy, GitHub) plus
  provider destinations for direct-egress modes are sourced from code, not
  tenant settings:
  `app/services/agent_runs/egress_policy/required_destinations.rb:14-94`.
- The resolver merges, in deterministic order — platform, GitHub,
  provider, account entries, project entries, run-local services/preview —
  with first-occurrence dedupe so required destinations can never be
  removed by tenant entries:
  `app/services/agent_runs/egress_policy/resolve.rb:133-264`.
- A tenant entry whose host collides with a required destination is
  dropped (not merged) before snapshot construction so a tenant entry
  cannot shadow or extend a required destination:
  `app/services/agent_runs/egress_policy/resolve.rb:137-162`.
- Run-local service destinations carry the Docker network alias
  provisioning actually grants (`Containers::ServiceRuntimeNaming.runtime_name`),
  not the user-facing service name, so the snapshot matches the host the
  container can actually resolve:
  `app/services/agent_runs/egress_policy/resolve.rb:216-238`.
- The existing iptables firewall (`NetworkPolicy`) and Docker network
  isolation remain the v1 transport-level enforcement layer; the
  per-Docker-host egress gateway is the accepted gap tracked by
  [#3438](https://github.com/viamin/paid/issues/3438).

**Tests**:

- `spec/services/agent_runs/egress_policy/required_destinations_spec.rb` —
  registry platform/github/provider surface
- `spec/services/agent_runs/egress_policy/resolve_spec.rb` — merge order,
  dedupe, provenance, account-set precedence over project-set duplicates,
  required-host precedence over tenant entries, run-local service
  destination shape

**Verdict**: Implemented at the policy-resolution layer; gateway-level
enforcement is the open follow-up (Criterion 9).

---

### Criterion 5: Claude Code subscription-auth runs can reach the required Anthropic hosts without giving all outbound internet access

**Status**: Implemented.

**Shipped**:

- The fixed-host provider registry names Anthropic, OpenAI, Google, and
  GitHub Copilot hosts so subscription-auth runs reach the required
  provider endpoints without granting arbitrary internet access:
  `app/services/agent_runs/egress_policy/required_destinations.rb:29-36`.
- Direct-outbound runners (`opencode`/`kilocode`/`pi`/`omp`) get an
  additional required host from their configured API provider; pi/omp host
  drift from `Runner::PI_API_PROVIDER_KEYS` raises `KeyError` at
  resolution instead of silently omitting the required destination:
  `app/services/agent_runs/egress_policy/required_destinations.rb:40-132`.
- Provider destinations are added only when the run's network mode is
  `subscription_auth` or `direct_outbound`; proxy-restricted runs reach
  providers via the secrets proxy and carry no provider destination:
  `app/services/agent_runs/egress_policy/resolve.rb:127-131`.

**Tests**:

- `spec/services/agent_runs/egress_policy/required_destinations_spec.rb` —
  fixed-host and direct-outbound provider coverage, plus the
  drift-raises contract
- `spec/services/agent_runs/egress_policy/resolve_spec.rb` — provider
  destinations excluded for proxy-restricted runs and included for
  subscription-auth / direct-outbound runs

**Verdict**: Implemented.

---

### Criterion 6: A research-enabled run can fetch approved web evidence through Paid without broad direct container egress *(gap)*

**Status**: Gap.

**What is missing**:

- The `:research` egress profile is defined and propagates through the
  provider-neutral runner contract
  (`ExecutionRunners::NetworkingPolicy#egress_profile`,
  `#research?`, `#open?`) but no broker service is implemented.
- No URL fetch/search service exists. The implementation needs a
  Paid-side broker that runs only when `egress_profile == :research`,
  validates scheme/host/size/timeout/redirects, enforces byte/token
  budgets, records `EgressSecurityEvent` rows for both blocked
  (`redacted_secret_extraction`) and completed requests, and redacts or
  quarantines fetched credential-looking content before it can reach the
  agent prompt.

**Evidence**:

- `app/services/execution_runners.rb:731-740` — `NetworkingPolicy`
  declares the `:locked`/`:research`/`:open` enum
- `app/services/execution_runners.rb:867-877` — `locked?` / `research?` /
  `open?` predicates
- `app/services/containers/provision.rb:423-434` —
  `networking_policy_with_egress_profile` threads the profile through
  without leaking Docker concepts
- `app/models/egress_security_event.rb:14` —
  `redacted_secret_extraction` event kind is reserved in the schema but
  no caller writes it today

**Follow-up**: [#3439](https://github.com/viamin/paid/issues/3439)

**Verdict**: Gap — the profile is reserved and propagates, but no broker
implementation exists.

---

### Criterion 7: A brokered research request containing a secret-looking token is blocked before the outbound call and records a redacted security event *(gap)*

**Status**: Gap.

**What is missing**:

- No broker implementation means no outbound secret-extraction scanner
  today; the schema reserves the `redacted_secret_extraction` event kind
  but no caller writes it.
- Response-side quarantine/redaction is similarly unimplemented; this
  criterion depends entirely on the brokered-research service from
  Criterion 6.

**Evidence**:

- `app/models/egress_security_event.rb:14` — `EVENT_KINDS` reserves the
  `redacted_secret_extraction` event kind
- `app/models/egress_security_event.rb:11-13` — model comment documents
  that records are immutable from the tenant perspective and that
  `redacted_evidence` carries fingerprints/redacted snippets only, never
  raw secret material

**Follow-up**: [#3439](https://github.com/viamin/paid/issues/3439)

**Verdict**: Gap — schema is reserved; no producer writes the events.

---

### Criterion 8: A runtime that cannot enforce the selected egress profile is rejected for production restricted runs *(partial)*

**Status**: Partial.

**Shipped**:

- `ExecutionRunners::NetworkingPolicy` carries the `:locked`/`:research`/`:open`
  profile through the portable runner contract, and `validate_egress_profile!`
  rejects unknown values at construction so typos fail loudly instead of
  silently serializing into the manifest:
  `app/services/execution_runners.rb:804-814`,
  `app/services/execution_runners.rb:816-818`.
- `Containers::Provision.networking_policy_with_egress_profile` threads
  the profile through `derived_networking_policy` without leaking Docker
  concepts:
  `app/services/containers/provision.rb:423-434`.

**What is missing**:

- The runner-side gate that rejects a production restricted run when its
  backend cannot enforce the requested profile (per-Docker-host egress
  gateway reachability, etc.) is part of the per-host gateway work tracked
  by [#3438](https://github.com/viamin/paid/issues/3438). The provider-neutral
  contract is in place; the runtime-specific fail-closed check is not.

**Evidence**:

- `app/services/execution_runners.rb:696-720` — `egress_profile` enum
  doc + RDR-055 intent
- `app/services/execution_runners.rb:731-877` — `NetworkingPolicy`
  closed-enum validation and `locked?`/`research?`/`open?` predicates

**Tests**:

- `spec/services/execution_runners_spec.rb:752-761` — every factory
  defaults the profile to `:locked` and accepts the closed-enum override
- `spec/services/containers/provision_spec.rb:288-306` —
  `networking_policy_for` defaults to `:locked`, threads the override,
  and rejects values outside the closed enum

**Follow-up**: [#3438](https://github.com/viamin/paid/issues/3438)

**Verdict**: Partial — the provider-neutral contract is in place;
runtime-side fail-closed eligibility is the open follow-up.

---

### Criterion 9: Invalid tenant rules for paths, broad wildcards, localhost, private IPs, and metadata IPs are rejected

**Status**: Implemented.

**Shipped**:

- The shared `AgentRuns::EgressPolicy::HostPattern` validator is the
  single source of truth for write-time validation and the resolver's
  read-time defensive re-validation, so legacy or manually-inserted rows
  can never widen a run's policy:
  `app/services/agent_runs/egress_policy/host_pattern.rb:16-89`,
  `app/models/egress_allowlist_entry.rb:39`,
  `app/models/egress_allowlist_entry.rb:106-132`.
- Rejection reasons cover bare/nested/trailing wildcards, wildcard TLDs,
  URL paths, userinfo, inline ports, query strings, fragments, IP literals
  (private, loopback, link-local, metadata), localhost names, single-label
  hosts, out-of-range ports, and schemes other than `http`/`https`:
  `app/services/agent_runs/egress_policy/host_pattern.rb:28-50`,
  `app/models/egress_allowlist_entry.rb:100-158`.

**Tests**:

- `spec/services/agent_runs/egress_policy/host_pattern_spec.rb` — every
  rejection reason exercised against the shared validator
- `spec/models/egress_allowlist_entry_spec.rb` — model-side rejection
  messages for paths, wildcards, localhost, private/metadata IPs, bad
  ports, and bad schemes

**Verdict**: Implemented.

---

### Criterion 10: Production provisioning fails if the required egress enforcement cannot be applied *(gap)*

**Status**: Gap.

**What is missing**:

- The per-host egress gateway is not deployed. Restricted runs rely on the
  existing iptables firewall + Docker network isolation rather than a
  domain-aware gateway. There is no production-time check that refuses a
  restricted run when the gateway is unreachable, no integration with
  `NetworkPolicy` / `LocalDockerRunner` to enforce that check, and no
  `EgressSecurityEvent` row producer that observes live denied egress
  today.
- `EgressSecurityEvent` rows are written by tests only; no production
  caller writes `denied_egress` or `redacted_secret_extraction` rows in
  shipped code today (audit-visible scope is shipped, the producer is
  not).

**Evidence**:

- `app/models/egress_security_event.rb:11-13` — model comment describes
  the expected gateway/broker producer path that is not yet wired
- `app/services/agent_runs/egress_policy/resolve.rb:189-209` — the
  resolver records `denied_reason` for unsafe persisted entries and
  raises `DeniedPolicyError`, but the gateway-failure path is not
  implemented

**Follow-up**: [#3438](https://github.com/viamin/paid/issues/3438)

**Verdict**: Gap — policy-resolution fail-closed (unsafe persisted
entries) is shipped; gateway fail-closed (runtime enforcement
unavailable) is not.

---

## Gaps

The following gaps remain after this audit. Each is owned by an open
issue — none is "implicitly satisfied" by the shipped code.

1. **Per-host egress gateway + production fail-closed enforcement** —
   tracked in [#3438](https://github.com/viamin/paid/issues/3438). The
   policy-resolution fail-closed path
   (`EgressPolicy::Resolve.resolve_and_persist!` raising
   `DeniedPolicyError` when unsafe persisted entries are rejected) is
   shipped, but the gateway-failure path is not. Restricted runs rely on
   the existing iptables firewall + Docker network isolation rather than
   a domain-aware gateway.

2. **Brokered research fetch/search service with outbound
   secret-extraction scanning and response quarantine/redaction** —
   tracked in [#3439](https://github.com/viamin/paid/issues/3439). The
   `:research` egress profile is reserved and propagates through the
   runner contract, but no broker service exists. `EgressSecurityEvent`
   reserves the `redacted_secret_extraction` event kind but no caller
   writes it.

3. **Runner-side gate that rejects a production restricted run whose
   backend cannot enforce the requested profile** — covered by
   [#3438](https://github.com/viamin/paid/issues/3438). The
   provider-neutral `egress_profile` enum and its closed-enum validation
   are shipped; the runtime-specific fail-closed eligibility check is not.

Items 1-3 are tracked in their respective issues; this audit does not
file new child issues because each already names the RDR-055 work item.
The umbrella status of [RDR-055](RDR-055-agent-container-egress-allowlisting.md)
remains **Partially Implemented** as long as any of gaps 1-3 are open.

## Child Issues

None filed by this audit. Existing blocking dependencies on the closeout
issue [#3441](https://github.com/viamin/paid/issues/3441) are sufficient:

- [#3434](https://github.com/viamin/paid/issues/3434) — account/project
  allowlist entries and validation. **Open**. The work for this child is
  shipped (`EgressAllowlistEntry` model + `HostPattern` validator,
  shipped in [#3496](https://github.com/viamin/paid/pull/3496)). The
  issue itself is not yet closed, so it remains a blocking dependency
  in the umbrella tracker.
- [#3435](https://github.com/viamin/paid/issues/3435) — required platform
  and runner destination registry. **Open**. The work for this child is
  shipped (`AgentRuns::EgressPolicy::RequiredDestinations`, including the
  drift-raises contract, shipped in [#3496](https://github.com/viamin/paid/pull/3496)).
  The issue itself is not yet closed, so it remains a blocking
  dependency in the umbrella tracker.
- [#3436](https://github.com/viamin/paid/issues/3436) — per-run egress
  policy resolution and snapshot persistence. **Open**. The work for this
  child is shipped (`AgentRuns::EgressPolicy::Resolve` + `Snapshot`,
  including `ProvisionContainerActivity` persistence, shipped in
  [#3496](https://github.com/viamin/paid/pull/3496)). The issue itself is
  not yet closed, so it remains a blocking dependency in the umbrella
  tracker.
- [#3437](https://github.com/viamin/paid/issues/3437) — portable runner
  networking contract propagation. **Open**. The work for this child is
  shipped (`ExecutionRunners::NetworkingPolicy#egress_profile` plus
  `Containers::Provision#networking_policy_with_egress_profile`, shipped
  in [#3495](https://github.com/viamin/paid/pull/3495)). The issue itself
  is not yet closed, so it remains a blocking dependency in the umbrella
  tracker.
- [#3438](https://github.com/viamin/paid/issues/3438) — per-host egress
  gateway + production fail-closed enforcement. **Open**. See gap 1
  above.
- [#3439](https://github.com/viamin/paid/issues/3439) — brokered research
  access with secret-extraction guards. **Open**. See gap 2 above.
- [#3440](https://github.com/viamin/paid/issues/3440) — settings UI/API
  and run audit visibility. **Open**. The work for this child is shipped
  (`Accounts::EgressAllowlistEntriesController`,
  `Projects::EgressAllowlistEntriesController`, the run-detail
  `EgressSecurityEvent` audit surface, and the persisted snapshot
  rendering on `Projects::AgentRunsController#show`, shipped in
  [#3497](https://github.com/viamin/paid/pull/3497)). The issue itself is
  not yet closed, so it remains a blocking dependency in the umbrella
  tracker.

## Blocking Dependencies Reconciliation

The closeout issue [#3441](https://github.com/viamin/paid/issues/3441)
links seven child issues. This section reconciles each against the
2026-08-21 audit.

| Dependency | State | Reconciliation |
|------------|-------|----------------|
| [#3434](https://github.com/viamin/paid/issues/3434) — account/project allowlist entries and validation | Open | RDR-055 step 1 work is shipped (criterion 1). The issue itself has not been closed in the tracker, so the umbrella still lists it as a blocking dependency. The shipped code is the evidence the issue can be closed when the tracker is reconciled. |
| [#3435](https://github.com/viamin/paid/issues/3435) — required platform and runner destination registry | Open | RDR-055 step 2 work is shipped (criterion 5). The issue itself has not been closed in the tracker, so the umbrella still lists it as a blocking dependency. |
| [#3436](https://github.com/viamin/paid/issues/3436) — per-run egress policy resolution and snapshot persistence | Open | RDR-055 step 3 work is shipped (criterion 3 + 4 + 9). The issue itself has not been closed in the tracker, so the umbrella still lists it as a blocking dependency. |
| [#3437](https://github.com/viamin/paid/issues/3437) — portable runner networking contract propagation | Open | RDR-055 step 4 work is shipped (criterion 8 partial). The issue itself has not been closed in the tracker, so the umbrella still lists it as a blocking dependency. |
| [#3438](https://github.com/viamin/paid/issues/3438) — per-host egress gateway + production fail-closed enforcement | Open | Remaining RDR-055 scope (gaps 1 and 3). The gateway service, container network plumbing, and runtime-side fail-closed eligibility check are not implemented. |
| [#3439](https://github.com/viamin/paid/issues/3439) — brokered research fetch/search with secret-extraction guards | Open | Remaining RDR-055 scope (gap 2). The `:research` profile is reserved and propagates, but no broker implementation exists. |
| [#3440](https://github.com/viamin/paid/issues/3440) — settings UI/API and run audit visibility | Open | RDR-055 step 7 work is shipped (criterion 1 + run-detail audit surface). The issue itself has not been closed in the tracker, so the umbrella still lists it as a blocking dependency. |

Because [#3438](https://github.com/viamin/paid/issues/3438) and
[#3439](https://github.com/viamin/paid/issues/3439) are open and represent
remaining RDR-055 scope, and because the umbrella's child-link tracker
still lists [#3434](https://github.com/viamin/paid/issues/3434),
[#3435](https://github.com/viamin/paid/issues/3435),
[#3436](https://github.com/viamin/paid/issues/3436),
[#3437](https://github.com/viamin/paid/issues/3437), and
[#3440](https://github.com/viamin/paid/issues/3440) as open, the umbrella
closeout [#3441](https://github.com/viamin/paid/issues/3441) must remain
open. Closing the umbrella while any child stays open would overstate the
RDR's reach. This audit recommends keeping the umbrella open and re-running
the closeout after [#3438](https://github.com/viamin/paid/issues/3438) and
[#3439](https://github.com/viamin/paid/issues/3439) land (and the
remaining children are reconciled in the tracker).
