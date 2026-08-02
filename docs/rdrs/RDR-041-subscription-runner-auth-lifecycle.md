# RDR-041: Subscription Runner Managed Auth Lifecycle

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Status**: Implemented
- **Date**: 2026-06-26
- **Revised**: 2026-08-02
- **Priority**: P1
- **Related Issues**: [#2690](https://github.com/viamin/paid/issues/2690), [#2683](https://github.com/viamin/paid/issues/2683), [#2685](https://github.com/viamin/paid/issues/2685), [#2684](https://github.com/viamin/paid/issues/2684), [#2686](https://github.com/viamin/paid/issues/2686), [#2687](https://github.com/viamin/paid/issues/2687), [#2688](https://github.com/viamin/paid/issues/2688), [#2689](https://github.com/viamin/paid/issues/2689), [#2958](https://github.com/viamin/paid/issues/2958), [#2959](https://github.com/viamin/paid/issues/2959), [#2960](https://github.com/viamin/paid/issues/2960), [#2961](https://github.com/viamin/paid/issues/2961), [#2962](https://github.com/viamin/paid/issues/2962), [#2963](https://github.com/viamin/paid/issues/2963), [#2964](https://github.com/viamin/paid/issues/2964), [#2965](https://github.com/viamin/paid/issues/2965), [#2966](https://github.com/viamin/paid/issues/2966)
- **Related RDRs**: RDR-004 (Container Isolation), RDR-006 (Secrets Proxy Architecture), RDR-007 (Agent CLI Abstraction), RDR-010 (Multi-Tenancy and RBAC), RDR-025 (Runner Quota Tracking), RDR-040 (Runner Model Compatibility Contracts), RDR-048 (Multi-Host Docker Backend Support)

## Implementation Status

RDR-041 is implemented as of 2026-08-02. The audit completed in
[#2966](https://github.com/viamin/paid/issues/2966) found that the six work
items that were listed as "Still open" in the 2026-07-16 revision are now
shipped for this RDR's acceptance scope. A few follow-on enhancements remain,
but they extend the lifecycle beyond the scope locked here rather than blocking
implementation status:

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Feature-flagged rollout (`managed_subscription_runner_auth` in `FeatureFlags::DEFINITIONS`) | Implemented | `app/services/feature_flags.rb`; tenant-scoped via `FeatureFlags.enabled?` |
| Production-style auth-attempt telemetry (`runner_auth_attempts`) | Implemented | `db/migrate/20260720200906_create_runner_auth_attempts.rb`; analytics queries in `app/services/analytics/runner_auth_attempts/` |
| Canonical materialization contract (provider-neutral adapter/materializer registry) | Implemented | `app/services/runners/subscription_auth_materializers.rb`; `app/services/runners/subscription_auth_providers.rb` |
| Codex managed subscription auth (device-code login, `auth.json` materialization, refresh/harvest, lease-through-run) | Implemented (#2962) | Device-code login, canonical secret storage, lease-through-run refresh/harvest, and managed `auth.json` materialization ship in `app/services/runners/subscription_auth_providers.rb`, `app/services/codex_credentials/secret.rb`, `app/services/codex_login_sessions/device_flow.rb`, and `spec/services/containers/provision_codex_managed_auth_2962_spec.rb`; remote placement intentionally stays gated by `remote_safe: false` in `app/services/runners/subscription_auth_materializers.rb` until later hardening proves it should be broadened |
| Gemini and Copilot remote-safe native config materializers | Implemented (#2964) | Remote-safe native config materializers ship in `spec/services/containers/provision_managed_subscription_auth_2964_spec.rb` and the provisioning path in `Containers::Provision`; provider-owned login flows and lease-through-run refresh/harvest are follow-on enhancements, not part of this RDR's acceptance scope |
| RDR-048 scheduler/readiness integration | Implemented | `app/services/runners/subscription_auth_eligibility.rb`; `app/services/runners/subscription_auth_host_paths.rb`; `app/services/containers/host_readiness.rb` |

### Follow-on Enhancements

These items remain useful future work, but they do not block this RDR from
being `Implemented`:

- **Codex remote placement** is gated at `remote_safe: false` in the
  materializer registry until refresh/writeback is proven by tests and
  telemetry. Once flipped to `true`, all RDR-048 host-eligibility wiring
  picks it up automatically.
- **Gemini and Copilot provider login flows and lease-through-run harvest**
  are deferred until telemetry proves managed-auth reliability. The
  materializer registry entries are `remote_safe: true`, and provisioning
  handles native config writing directly. Dedicated adapter subclasses
  (`Gemini < Base`, `Copilot < Base`) will host those lifecycle methods
  when they land.

### Provider Matrix (August 2026)

| Provider | Managed auth | Remote-safe | Login flow | Refresh/harvest |
|----------|-------------|-------------|------------|-----------------|
| Claude Code | Managed `CLAUDE_CODE_OAUTH_TOKEN` or native `.credentials.json` | Yes | Browser capture + keep-warm refresh | Server-side refresh only |
| Codex | Managed `auth.json` from device-code login | No (gated) | Device-code Connect Codex flow | Lease-through-run + harvest |
| Gemini | Managed native `oauth_creds.json` from `RunnerCredential` | Yes | Deferred | Deferred |
| Copilot | Managed native `config.json` from `RunnerCredential` | Yes | Deferred | Deferred |

## Issue Plan

The original Claude-focused issue chain ([#2690](https://github.com/viamin/paid/issues/2690), [#2683](https://github.com/viamin/paid/issues/2683), [#2685](https://github.com/viamin/paid/issues/2685), [#2684](https://github.com/viamin/paid/issues/2684), [#2686](https://github.com/viamin/paid/issues/2686), [#2687](https://github.com/viamin/paid/issues/2687), [#2688](https://github.com/viamin/paid/issues/2688), [#2689](https://github.com/viamin/paid/issues/2689)) is complete. The revised provider-neutral and RDR-048-compatible work is tracked by this dependency-ordered issue chain. These issues are auth-related and should remain `P1`.

| Issue | Priority | Scope | Dependency |
|-------|----------|-------|------------|
| [#2958](https://github.com/viamin/paid/issues/2958) | P1 | Umbrella tracking issue for the revised managed subscription auth lifecycle | None |
| [#2959](https://github.com/viamin/paid/issues/2959) | P1 | Gate managed subscription auth rollout and add runtime auth-source metadata | Depends on [#2958](https://github.com/viamin/paid/issues/2958) |
| [#2960](https://github.com/viamin/paid/issues/2960) | P1 | Add runner auth attempt telemetry for managed versus host auth | Depends on [#2959](https://github.com/viamin/paid/issues/2959) |
| [#2961](https://github.com/viamin/paid/issues/2961) | P1 | Extract subscription auth provider adapter/materializer contract | Depends on [#2959](https://github.com/viamin/paid/issues/2959), [#2960](https://github.com/viamin/paid/issues/2960) |
| [#2962](https://github.com/viamin/paid/issues/2962) | P1 | Implement remote-safe Codex managed subscription auth | Depends on [#2961](https://github.com/viamin/paid/issues/2961), [#2960](https://github.com/viamin/paid/issues/2960) |
| [#2963](https://github.com/viamin/paid/issues/2963) | P1 | Enforce subscription auth host eligibility in RDR-048 scheduler and readiness | Depends on [#2961](https://github.com/viamin/paid/issues/2961), [#2962](https://github.com/viamin/paid/issues/2962) |
| [#2964](https://github.com/viamin/paid/issues/2964) | P1 | Add Gemini and Copilot managed subscription auth materializers | Depends on [#2962](https://github.com/viamin/paid/issues/2962), [#2963](https://github.com/viamin/paid/issues/2963) |
| [#2965](https://github.com/viamin/paid/issues/2965) | P1 | Cut over managed subscription auth after telemetry proves reliability | Depends on [#2960](https://github.com/viamin/paid/issues/2960), [#2963](https://github.com/viamin/paid/issues/2963), [#2964](https://github.com/viamin/paid/issues/2964) |
| [#2966](https://github.com/viamin/paid/issues/2966) | P1 | Final implementation audit, gap filing, and RDR status update | Depends on [#2965](https://github.com/viamin/paid/issues/2965) |

The final issue ([#2966](https://github.com/viamin/paid/issues/2966)) should
update this RDR to `Implemented` once the shipped scope above is verified and
the remaining items are clearly classified as follow-on work rather than open
RDR acceptance criteria.

## Problem Statement

Subscription-auth runners (Claude Code, Codex, Gemini, Copilot) run paid local CLIs inside Paid-managed containers. Their credentials are OAuth/session artifacts for the user's subscription plan, not normal provider API keys.

The original implementation forwarded host/devcontainer credential directories into agent containers. That has two hard limits:

1. **Availability.** A remote Docker daemon cannot mount a credential directory from the Paid control-plane host.
2. **Refresh ownership.** For rotating credentials, the important state is not just the initial token; it is where the refreshed credential lands. If a container refreshes a copied credential and exits, Paid keeps a stale parent credential and future runs fail.

RDR-048 makes this urgent. Multi-host Docker placement can only send a subscription runner to a remote backend when the runner has a remote-safe credential source. Host-mounted local auth must remain supported for local Docker, but it cannot be the only path.

## Goals

1. Let a Paid user initiate subscription auth from the Runners UI and store the result in Paid.
2. Use that auth for both local and remote Docker containers.
3. Keep refresh/rotation state owned by Paid, not by an ephemeral container.
4. Preserve the existing local host-mounted path while the new path rolls out.
5. Measure managed-auth success rates against legacy local-container auth before forcing cutover.
6. Keep provider-specific OAuth behavior isolated in provider adapters or agent-harness, not scattered across provisioning code.

## Current Provider Matrix

| Provider | Current local behavior | Current remote behavior | Managed-auth status | Required next step |
|----------|------------------------|--------------------------|---------------------|--------------------|
| Claude Code | Host `.credentials.json`, managed `CLAUDE_CODE_OAUTH_TOKEN`, or captured native credential | Works when managed `RunnerCredential` exists; host file is not required | Implemented | Continue hardening behind the provider-neutral contract as telemetry accumulates |
| Codex | Host `auth.json` bind mount with lock/writeback, or managed `auth.json` materialized from `RunnerCredential` | Managed auth works for the shipped path; remote placement remains gated by `remote_safe: false` until later hardening widens eligibility | Implemented (#2962) | Prove remote-safe broadening with additional tests and telemetry before enabling remote placement |
| Gemini | Host `oauth_creds.json`/config copy, or managed native `oauth_creds.json` from `RunnerCredential` | Works when managed `RunnerCredential` exists; host file is not required | Implemented (#2964) | Add provider login flow and lease-through-run harvest once telemetry proves reliability |
| Copilot | Host `config.json`/local config copy, or managed native `config.json` from `RunnerCredential` | Works when managed `RunnerCredential` exists; host file is not required | Implemented (#2964) | Add provider login flow and lease-through-run harvest once telemetry proves reliability |

## External Prior Art: Oh My Pi

The Oh My Pi `@oh-my-pi/ai` package is MIT licensed and provides useful source material:

- Provider OAuth login flows for Anthropic/Claude, OpenAI Codex, Gemini, and GitHub Copilot.
- A provider registry with `login`, `refreshToken`, `storeCredentialsAs`, and provider-specific credential metadata.
- A Codex device-code flow (`loginOpenAICodexDevice`) that maps well to a Paid "Connect Codex" button because it avoids localhost callback assumptions.
- An auth broker/gateway architecture where a server owns refresh tokens, exposes redacted snapshots, performs refresh centrally, and only gives clients resolved credentials or API responses.

It is not a drop-in replacement for Paid:

- Oh My Pi primarily serves its own clients and provider gateway flows; Paid runs external CLIs inside Docker containers.
- Claude in Paid already has an official-CLI capture path. Replacing it with a custom Anthropic PKCE flow would increase ToS and maintenance risk.
- Codex/Gemini/Copilot still need native CLI config files or an equivalent provider-specific runtime materializer; an API gateway alone does not make those CLIs authenticated.

Decision: borrow the architecture and provider-flow code where useful, especially Codex device auth and broker-owned refresh semantics, but keep the Paid abstraction explicit: encrypted `RunnerCredential` records plus provider-specific materializers for CLI runtime state.

## Recommendation

Promote `RunnerCredential` from "Claude credential storage" to the canonical account-scoped credential store for all subscription runners. Add a provider-neutral lifecycle around it:

```text
Connect in Paid UI
  -> encrypted RunnerCredential
  -> server-side refresh/lease before run
  -> container-specific materialization
  -> optional rotated credential harvest
  -> success/failure telemetry
```

Host bind mounts become a legacy/local fallback, not the primary subscription-auth story.

## Proposed Design

### Ownership Boundary

Paid owns:

- account-scoped encrypted credential storage;
- auth/connect UI and authorization;
- credential leases and refresh orchestration;
- materializing credentials into the selected container;
- run-level telemetry and RDR-048 host eligibility decisions.

Provider adapters or agent-harness own:

- provider-specific login flows;
- provider-specific refresh-token exchange;
- native credential parsing and validation;
- native CLI file generation;
- auth error classification patterns.

Provider-specific facts may live in Paid while upstream support is missing, but each interim adapter must be narrow, tested with fixtures, and removable once agent-harness exposes the same contract.

### Credential Record

Extend `RunnerCredential` conceptually without replacing the shipped table:

- `runner_key`: `claude`, `codex`, `gemini`, `copilot`.
- `auth_kind`: `oauth_token`, `api_key`, `signing_token`, or provider-specific OAuth session.
- `token`: encrypted primary secret. For structured OAuth sessions, this may be an encrypted serialized payload rather than a single bearer string.
- `expires_at`, `long_lived`, `last_used_at`, `revoked_at`: existing lifecycle fields.
- `metadata`: provider account identity, scopes, source flow, native format version, and non-secret diagnostics.

Do not store raw native files as opaque permanent truth when a normalized provider credential is available. Native files are runtime artifacts generated from the canonical credential and provider metadata. Exception: short-term Claude native capture may continue storing the captured JSON until the provider adapter can normalize it losslessly.

### Provider Adapter Contract

Introduce a small contract per subscription provider:

```text
provider_key
supported_connect_flows
credential_status(credential)
refresh_if_needed(credential)
materialize_for_container(credential, target)
harvest_after_run(target)
rotation_risk
remote_safe?
```

`materialize_for_container` returns one of:

- environment variables, such as `CLAUDE_CODE_OAUTH_TOKEN`;
- native file writes into `/home/agent/.<provider>/...`;
- a broker/proxy configuration when the CLI can use one;
- an explicit unsupported result with a reason safe to show in the UI.

`rotation_risk` tells orchestration whether the credential can be shared concurrently:

- `none`: non-rotating setup token or API key;
- `server_refresh_only`: Paid refreshes before the run and containers should not rotate;
- `container_may_rotate`: the CLI may mutate the native file during the run, so the run needs a credential lease and post-run harvest;
- `unsupported`: do not schedule without a different auth mode.

### Refresh and Lease Rule

For every managed subscription credential:

1. Before provisioning, acquire a per-credential lease.
2. Refresh if the credential is near expiry and the provider supports server-side refresh.
3. Materialize only a fresh credential into the container.
4. If the provider may rotate in-container, keep the lease for the run and harvest the native file afterward.
5. Persist any rotated credential before releasing the lease.
6. Mark the credential `auth_expired` if refresh fails with an invalid/reused refresh token.

This intentionally favors correctness over concurrency for rotating OAuth sessions. Higher concurrency is only allowed when the provider can use a non-rotating token, broker-owned refresh, or access-token-only runtime.

### Provider-Specific Paths

#### Claude Code

Keep the shipped managed setup-token path as the default remote-safe Claude path:

- user provides or captures a credential through Paid UI;
- Paid stores it as `RunnerCredential`;
- provisioning injects `CLAUDE_CODE_OAUTH_TOKEN` or writes native `.credentials.json`;
- remote Docker is eligible because no host bind mount is required.

For browser-completed native Claude login, durability depends on server-side keep-warm refresh. Continue using the official CLI capture path unless upstream ships a supported device-code/manual-code flow. Do not replace it with custom Anthropic PKCE unless the official path remains too brittle and the ToS risk is accepted explicitly.

#### Codex

Codex is the first missing provider to implement because it directly blocks RDR-048 remote subscription auth.

Recommended path:

1. Add a "Connect Codex" flow using a device-code login modeled on Oh My Pi's Codex provider.
2. Store access token, refresh token, expiry, account identity, and native-format metadata in `RunnerCredential`.
3. Before provisioning, refresh under a per-credential lease if near expiry.
4. Generate a valid `/home/agent/.codex/auth.json` in the container from the canonical credential.
5. If the Codex CLI may rotate `auth.json` during execution, keep the lease through the run and copy the resulting file or parsed token state back into `RunnerCredential`.
6. Until post-run harvest is proven, serialize runs that share the same Codex credential or force API-key/proxy mode for remote Docker.

Do not claim "Codex works remotely" merely because Paid can copy an initial `auth.json`. The acceptance criterion is that refresh state remains valid after the run.

#### Gemini and Copilot

Implement after Codex unless a customer need prioritizes them:

- add provider login adapters or documented setup-token ingestion;
- normalize credential state in `RunnerCredential`;
- generate only the minimal native CLI config in the container;
- reject remote scheduling when the provider cannot be materialized without host files.

### RDR-048 Host Eligibility Contract

Scheduler and readiness decisions must evaluate provider/auth capability, not just backend type:

```text
if runner uses managed RunnerCredential and materializer.remote_safe?
  local and remote Docker are eligible
else if runner uses host-forwarded subscription auth
  only backends with supports_host_paths? are eligible
else if runner uses API-key/proxy auth
  any backend with proxy/network readiness is eligible
else
  reject with "runner is not authenticated"
```

Host readiness should surface auth incompatibility as a named reason, for example:

- `requires_host_bind_mount`;
- `managed_auth_missing`;
- `provider_materializer_missing`;
- `credential_expired`;
- `credential_refresh_failed`;
- `remote_proxy_unreachable`.

RDR-048 setup docs should not instruct users to copy local subscription credential directories to remote hosts. They should direct users to managed `RunnerCredential` flows where supported, and clearly mark provider gaps where remote placement is intentionally blocked.

### Feature Flag and Rollout

Add a tenant-scoped feature flag, tentatively `managed_subscription_runner_auth`, following `FeatureFlags` and `tenant_settings.features` conventions.

Rollout stages:

1. **Shadow/read-only.** Keep legacy host-mounted auth active. For runs with a managed credential available, compute the materialization plan and record whether it would have been remote-safe, without using it.
2. **Opt-in per tenant/provider.** Use managed auth for selected providers and accounts. Fall back to host-mounted auth only when no managed credential exists.
3. **Remote enforcement.** Allow remote Docker placement only when managed auth or API-key/proxy auth is available.
4. **Default-on.** Prefer managed auth everywhere; host-mounted subscription auth remains a local-only escape hatch.
5. **Cleanup.** Remove provider-specific legacy code only after success metrics show managed auth is at least as reliable as legacy local auth for the same provider.

### Success Metrics and Telemetry

Add a durable way to compare new and old auth paths. Existing `agent_runs.status`, `agent_runs.container_host`, `agent_runs.auth_provider`, `agent_runs.final_runner`, `agent_run_logs`, and `orchestration_decisions` are useful but not specific enough for credential materialization outcomes.

Recommended: add a small `runner_auth_attempts` table or equivalent structured event stream keyed to `agent_run_id` and `runner_credential_id`.

Record:

- `runner_key`;
- `container_host`;
- backend capability (`supports_host_paths?`, `remote?`);
- auth source (`managed`, `host_forwarded`, `api_key_proxy`);
- materialization mode (`env`, `native_file`, `broker`, `host_mount`);
- feature flag state;
- refresh state (`not_needed`, `refreshed`, `refresh_failed`, `expired`);
- lease state (`none`, `acquired`, `waited`, `timeout`);
- result (`materialized`, `skipped`, `failed`, `harvested`, `harvest_failed`);
- failure reason safe for UI;
- timing and retry counts.

Use these events to report:

- success rate by provider/auth source/container host;
- auth-expired rate before and after managed auth;
- refresh failure rate;
- remote placement rejection reasons;
- managed-vs-legacy local run outcomes for the same runner family.

Do not log plaintext tokens, native credential files, authorization codes, or refresh tokens.

## Alternatives Considered

- **Keep host bind mounts and document remote copying.** Rejected. Copying secrets to remote Docker hosts multiplies credential sprawl and still fails the refresh ownership problem unless the remote host can write back to the canonical source.
- **Only support Claude remotely.** Rejected as a temporary state, not an architecture. RDR-048 needs an explicit eligibility contract for all subscription runners so the scheduler does not place unsupported providers on remote hosts.
- **Use Oh My Pi wholesale.** Rejected. Its provider flows and broker are valuable, but Paid's execution model is Dockerized external CLIs, not only brokered API calls. Paid needs a native CLI materialization layer.
- **Let containers own refresh.** Rejected for rotating credentials unless the refreshed state is harvested before the lease is released. Otherwise every successful in-container refresh creates a stale parent credential.
- **Serialize all subscription runs forever.** Rejected as the default. It is acceptable during rollout for rotation-risk providers, but the target is broker-owned refresh, non-rotating setup tokens, or access-token-only runtime where providers allow it.
- **Force subscription runners into provider API-key mode.** Rejected. That changes user billing and defeats the purpose of subscription runners.

The implementation phases below are complete for the scope locked by the
2026-08-02 audit in [#2966](https://github.com/viamin/paid/issues/2966). See
the Implementation Status table above for evidence traces per criterion.
## Implementation Plan

### Phase 1: Gate Existing Runtime State

- Add `managed_subscription_runner_auth` to `FeatureFlags::DEFINITIONS`.
- Add explicit auth-source metadata to provisioning logs for Claude's current managed path and legacy host-mounted paths.
- Add scheduler-facing helper methods that answer whether a runner/auth mode requires host paths.

### Phase 2: Auth Attempt Telemetry

- Add `runner_auth_attempts` or structured orchestration events for materialization, refresh, lease, and harvest outcomes.
- Add query/UI reporting for success rate by provider, auth source, and container host.
- Backfill no secrets; only start collecting new events.
- Use these metrics during rollout to compare managed local auth with legacy host-mounted local auth before broadening remote placement.

### Phase 3: Provider Adapter Interface

- Extract Claude's current managed-token and native-credential behavior behind the provider adapter contract.
- Keep existing Claude runtime behavior unchanged while moving decisions out of `Containers::Provision` branches.
- Add contract specs with fixture credentials and redaction checks.

### Phase 4: Codex Managed Auth

- Add the Codex connect flow, preferably device-code based.
- Store Codex OAuth state in `RunnerCredential`.
- Generate native `auth.json` inside the agent container.
- Implement refresh-before-run and, if needed, lease-through-run plus post-run harvest.
- Keep remote placement disabled for Codex until refresh/writeback is proven by tests and telemetry.

### Phase 5: RDR-048 Scheduler Integration

- Teach host selection to reject remote hosts for host-forwarded subscription auth.
- Allow remote hosts when managed materialization is remote-safe.
- Surface auth incompatibility in readiness, queue explanations, and setup guide output.
- Update RDR-048 remote setup docs to point to managed credential flows instead of remote secret copying.

### Phase 6: Gemini and Copilot

- Add provider adapters and connect/materialization flows.
- Start in shadow mode, then opt-in per tenant/provider.
- Use telemetry gates before allowing remote placement.

### Phase 7: Cutover and Cleanup

- Make managed auth the default when a credential exists.
- Keep host-mounted subscription auth local-only.
- Remove obsolete provider-specific provisioning branches only after metrics prove managed auth reliability and every provider has a maintained adapter.

## Validation

- **Credential storage.** `RunnerCredential` remains encrypted, account-scoped, revocable, logidze-tracked, and never exposes plaintext secrets in logs, events, or UI.
- **Provider contract.** Each adapter has fixture-based tests for valid, expired, malformed, refreshable, and unrefreshable credentials.
- **Materialization.** Claude env-token and Codex native-file materializers produce exactly the runtime state the CLI expects without host bind mounts.
- **Refresh ownership.** A rotating provider updates `RunnerCredential` after refresh; a simulated stale parent credential cannot survive a successful run.
- **Lease behavior.** Concurrent runs sharing a rotation-risk credential serialize, wait, or fail with a safe reason instead of racing refresh tokens.
- **RDR-048 compatibility.** Remote Docker placement is allowed for managed remote-safe auth and rejected for host-forwarded auth on `supports_host_paths? == false` backends.
- **Feature flag.** Disabling `managed_subscription_runner_auth` preserves the legacy local host-mounted path.
- **Telemetry.** Managed and legacy auth attempts can be compared by provider, host, auth source, and outcome without exposing secrets.
- **End-to-end smoke.** In development, run the same subscription runner through local Docker with legacy host auth, local Docker with managed auth, and remote Docker with managed auth; compare recorded success rates and failure reasons.
