# RDR-041: Subscription Runner Auth Lifecycle (Detection, Long-Lived Tokens, Self-Heal)

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Status**: Accepted
- **Date**: 2026-06-26
- **Priority**: P1
- **Related Issues**: #2690, #2683, #2685, #2684, #2686, #2687, #2688, #2689
- **Related RDRs**: RDR-004 (Container Isolation), RDR-006 (Secrets Proxy Architecture), RDR-007 (Agent CLI Abstraction), RDR-010 (Multi-Tenancy and RBAC), RDR-025 (Runner Quota Tracking), RDR-040 (Runner Model Compatibility Contracts)

## Implementation Status

Accepted and tracked, not materially implemented yet. Existing pre-RDR plumbing includes the `auth_expired` run status and non-zero auth classification, but the exit-0/preflight auth gap, proactive auth health, managed runner credentials, Claude long-lived token injection, and self-heal flows remain open work tracked by the related phase issues.

## Problem Statement

Subscription-auth runners (Claude Code, Codex, Gemini, Copilot) execute inside agent containers using OAuth credentials **forwarded from the host/devcontainer**, not API keys. When the upstream credential expires, the forwarded credential expires with it, and every container inherits the same dead token. Today this is a **silent breakage**: Paid has no proactive signal that the source credential is stale, the only path that classifies an auth failure requires a non-zero runner exit, and there is no way to re-authorize without shell access to the host/devcontainer.

Claude Code's interactive OAuth access token has a short (~24h) lifetime and does not auto-refresh on headless machines, so the forwarded Claude credential goes stale frequently and quietly. This blocks subscription Claude runs and is invisible until a human notices runs failing — or, worse, until a run is recorded as successful while the runner actually never authenticated.

Two outcomes are required:

1. **Detect** the expired/expiring state and surface it loudly, before runs start failing.
2. **Re-authorize** a runner without requiring a human to open a terminal on the host/devcontainer — including cloud deployments where no terminal exists.

## Context

### Current Forwarding Pipeline

Subscription auth is detected and forwarded at container provision time in `app/services/containers/provision.rb`:

- **Detection is existence-only.** `claude_subscription_auth?` (≈`provision.rb:2259`) returns true iff a `.credentials.json` file exists at `claude_config_host_path` or `claude_local_config_path`. Codex/Gemini/Copilot use the analogous `auth.json` / `oauth_creds.json` / `config.json` checks. No expiry, validity, or token shape is inspected.
- **Mount + seed.** The host config dir is mounted read-only at a staging path (`provision.rb:1851-1879`) and credentials are copied into a writable `/home/agent/.<provider>` tmpfs after start (`seed_claude_credentials!`, `seed_codex_credentials!`, …). A `PAID_<PROVIDER>_SUBSCRIPTION_AUTH=1` env var signals mode, and subscription containers run on the unrestricted `paid_internal` network instead of the firewalled `paid_agent` network (`app/services/network_policy.rb`).

### Claude/Codex Asymmetry (root cause of the silent breakage)

- **Codex self-heals.** `auth.json` is mounted **read-write** with a serializing lock (`provision.rb:1861`, `with_codex_auth_lock` at `provision.rb:1272`). The Codex CLI refreshes headlessly and writes the rotated token back to the host file, so the source stays warm.
- **Claude cannot self-heal the same way.** `.credentials.json` is mounted **read-only** and copied into ephemeral tmpfs. Any in-container refresh dies with the container. And the `claude` CLI does **not** auto-refresh on headless machines (upstream bug), its refresh tokens are **single-use/rotating** (concurrent-refresh race), and its access tokens are ~24h. So the host copy only stays valid if something keeps it warm — and nothing does.

### Detection Gaps in the Run Path

In `app/temporal/activities/run_agent_activity.rb`:

- `auth_expired_error?(runner, output)` (≈`:1799`) pattern-matches runner output against agent-harness `:auth_expired` patterns, but is **only called on non-zero exit** (≈`:1541`).
- The **success path (exit 0)** checks rate-limits, credits, and model-not-found but **not** auth (`:1490-1531`); the preflight path has the same omission (≈`:1672-1706`). A runner that prints an auth error and exits 0 is recorded as a successful run.
- `auth_expired` is a real terminal `AgentRun` status with full plumbing (model status/scope, failure-recovery mapping to `auth_failure`, dashboard stats coloring/label), but nothing surfaces it as an actionable "re-authenticate" prompt. The new dashboard retry-limited widget (`dashboard_controller.rb:32`, `_retry_limited_issues.html.erb`) covers retry-cap/push-blocked abandonment, not auth.

### agent-harness Already Has Auth Scaffolding (and a Gap)

`AgentHarness::Authentication` (agent-harness 0.23.0, `lib/agent_harness/authentication.rb`) already exposes:

- `auth_status(provider)` → `{valid:, expires_at:, error:}`
- `auth_capabilities(provider)` / `auth_url(provider)` (returns `https://claude.ai/oauth/authorize`) / `refresh_auth(provider, token:)` (stores a **pre-exchanged** token under a file lock; explicitly does not perform code exchange).

**Critical gap:** the module reads/writes a **top-level** `oauth_token` / `expiresAt` shape, but a real Claude CLI `.credentials.json` nests everything under `claudeAiOauth` (`{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt", …}}`). As written, `auth_status(:claude)` reports a genuine host credential as "No authentication token found", and `refresh_auth` writes a shape the container CLI will not read. This is a provider-specific correctness gap that belongs upstream.

## Research Findings

Claude Code subscription auth mechanics (verified against Claude Code docs and tracked issues):

- **`claude setup-token`** produces a ~1-year, **non-rotating** OAuth token (prefix `sk-ant-oat01-`) intended for headless/CI use via the `CLAUDE_CODE_OAUTH_TOKEN` env var. Generating it requires an interactive browser once, on **any** machine — not necessarily the deployment host. As a static bearer, it is **not** refreshed by the CLI.
- **Interactive `/login`** uses OAuth 2.0 authorization-code + PKCE: local callback server, browser consent at `console.anthropic.com`, code exchanged server-to-server for access + refresh tokens. This flow can in principle be re-implemented by a web app (generate auth URL + PKCE verifier server-side, user authorizes, paste code back, exchange), but it is undocumented and a mild ToS gray area since it reuses Claude Code's OAuth client.
- **`.credentials.json`** stores `claudeAiOauth.{accessToken, refreshToken, expiresAt, scopes, subscriptionType}`; access token ~24h; **refresh tokens are single-use** (concurrent refresh → one wins, others get 401 / `refresh_token_reused`).
- **Headless refresh is broken upstream**: the CLI does not use the stored refresh token on headless machines and instead prompts for `/login`.
- **`CLAUDE_CODE_OAUTH_TOKEN`** is honored as a static bearer and is **not** stripped by agent-harness's Anthropic provider (`subscription_unset_vars` / `api_key_unset_vars` cover only `ANTHROPIC_*`), so it passes through to the container CLI unmodified.

Implication: for Claude, "self-heal via the refresh token" is **not** "mount RW and let the CLI refresh" (that only works for Codex). It requires Paid or agent-harness to perform the refresh-token→access-token exchange itself. The simpler, more reliable near-term unblock is a long-lived `setup-token` injected via `CLAUDE_CODE_OAUTH_TOKEN`.

### Login CLI surface (for a Paid-initiated, browser-completed login)

We investigated whether Paid could drive the **official** `claude` CLI's login semi-interactively (Paid runs the CLI, the CLI emits an OAuth URL, the user authorizes in their own browser, a code is fed back) — a TOS-clean alternative to re-implementing Claude's OAuth client. Findings (documented behavior unless noted):

- **Subcommands.** `claude auth login` (`--email`, `--sso`, `--console`), `claude auth logout`, `claude auth status` (JSON, or `--text`; exits 0 logged in / 1 not), and `claude setup-token` (prints `sk-ant-oat01-…` to stdout, saves nothing). The interactive REPL also has `/login` and `/logout`.
- **No orchestratable manual mode on the subcommands.** Neither `claude auth login` nor `claude setup-token` documents a `--no-browser`, `--manual`, `--code`, or `--code-file` flag. `--no-browser` (print URL, paste redirect back) exists only for `claude mcp login`, not for Claude Code's own auth.
- **`setup-token` is not headless-bridgeable.** It starts a localhost callback server and auto-opens a browser on the initiating machine; it has no print-URL-and-paste-code fallback. It is designed to be run on a machine that already has a browser, with the resulting token copied elsewhere.
- **Naive stdin relay is blocked by PKCE binding.** The OAuth code is bound to the PKCE challenge of the session that generated the URL. Piping a code into a fresh `claude auth login` opens a *new* flow with a *new* challenge, invalidating the code (`echo code | claude auth login` does not work; tracked upstream in claude-code#47994, closed-as-duplicate, no flag shipped). Requested-but-unshipped flags there include `--code`, `--code-file`, `--no-browser`, and a device-code flow.
- **Code-paste fallback exists only inside the interactive `/login`.** In WSL2/SSH/container sessions the CLI detects the unreachable callback and prints a code for the user to paste at the `Paste code here if prompted` prompt — but only within an already-running interactive session, where the PKCE challenge is held in the same process.
- **Credential landing.** `setup-token` → stdout only (capturable). `/login` and `auth login` → `~/.claude/.credentials.json` (or macOS Keychain), not stdout.
- **Supported headless pattern** per Anthropic docs: a user runs `claude setup-token` locally and supplies the resulting `CLAUDE_CODE_OAUTH_TOKEN` to the orchestrator — which is exactly Phase 2.

## Recommendation

Adopt a phased lifecycle, with a clean ownership boundary consistent with RDR-007: **agent-harness owns provider-specific OAuth/auth facts and flows; Paid owns credential storage, multi-tenancy, container injection, detection surfacing, and UX.**

- **Phase 1 — Detection (fix-agnostic, no new OAuth code).** Turn the silent breakage into a loud, actionable signal: close the exit-0 auth gap, add a proactive source-credential check, surface an "auth expired / expiring — re-authenticate" dashboard banner, and run a periodic health job.
- **Phase 2 — Long-lived token management (primary near-term unblock).** UI-managed, encrypted, account-scoped storage for a long-lived Claude `CLAUDE_CODE_OAUTH_TOKEN`, injected into the container as an env var, with a "mark as long-lived" flag. Removes the host dependency and the refresh problem for ~1 year, and works in cloud/headless deployments.
- **Phase 3 — Self-heal via upstream refresh.** Add refresh-token exchange to agent-harness and a Paid keep-warm path that writes the rotated credential back to the source under a lock. Validates the original refresh hypothesis, and becomes the durability enabler for the Phase 4 interactive login (whose captured credential is short-lived).
- **Phase 4 — Browser-completed real login (full host-independence).** A real, TOS-clean login the user completes in their own browser from the Paid UI, by surfacing the official `claude` interactive login over a server-side PTY (form-bridged, or a full xterm.js terminal). Falls back to a headless CLI drive if an upstream `--code`/device-code flag ships (claude-code#47994), or a re-implemented PKCE flow only as a last resort.

Phases 1 and 2 are the committed near-term scope. Phases 3 and 4 are sequenced behind them and tracked upstream.

## Proposed Design

### Ownership boundary (agent-harness vs Paid)

agent-harness owns, per provider:

- Correct native credential parsing for `auth_status` (fix the `claudeAiOauth` shape gap).
- `auth_url` / code-exchange (PKCE) and refresh-token exchange APIs.
- Auth error classification patterns (already consumed via `RunnerSupport.error_classification_patterns_for`).

Paid owns:

- Encrypted, account-scoped credential storage and its UI.
- Resolving and injecting credentials into containers.
- Detection surfacing (banner, job, run-path classification).

Where Phase 1 needs correct expiry parsing before the upstream `auth_status` fix ships, Paid uses a narrow native-shape parser guarded by `TODO(#<agent-harness-issue>)` and switches to `AgentHarness::Authentication.auth_status` once upstream is correct.

### Phase 1 — Detection

1. **Exit-0 auth check.** In `run_agent_activity.rb`, add `auth_expired_error?(runner, sanitized_output)` to the `result.success?` branch (`:1490-1531`) and the preflight path (≈`:1672-1706`), mirroring the existing rate-limit/credits checks, raising `RunnerAuthExpiredError`.
2. **Auth-health service.** `Runners::AuthHealth` reports, per account and subscription runner: `{ valid, expires_at, source: :managed_token | :host_forwarded, error }`. For managed tokens it reads stored metadata. For host-forwarded credentials, prefer the **supported** `claude auth status` CLI primitive (JSON output, exit 0 valid / 1 not) over parsing the credential file; fall back to a native `claudeAiOauth.expiresAt` parse (interim) and switch to a fixed `AgentHarness::Authentication.auth_status` once the upstream shape gap is resolved.
3. **Dashboard banner.** Load `@auth_health` in `DashboardController#show` and render `dashboard/_auth_health_banner`, mirroring the `_retry_limited_issues` wiring (`show.html.erb:60`). Banner links to the credential UI from Phase 2.
4. **Periodic job.** `ClaudeAuthHealthCheckJob` mirroring `app/jobs/github_token_health_check_job.rb`, registered in `config/initializers/good_job.rb` (≈ every 4h), flagging expired/expiring credentials.

### Phase 2 — Long-lived token management

1. **Storage — `RunnerCredential` model.** Account-scoped, mirroring `IntegrationCredential`:
   - `encrypts :token` (Rails 7+), `has_logidze`, `belongs_to :account`, `belongs_to :created_by` (User, optional).
   - Columns: `runner_key`, `name`, `auth_kind` (default `oauth_token`), `long_lived` (boolean), `expires_at`, `last_used_at`, `revoked_at`, `metadata` jsonb.
   - Unique on `(account_id, runner_key, name)`; created via `rails generate migration` + `rails generate logidze:model`; table/column comments per project convention.
   - `long_lived = true` ⇒ skip expiry-tracking and refresh; treat as a static bearer.
2. **Runtime resolution (no hard FK on `runners`).** Resolve the active `RunnerCredential` by `(account, runner_key)` at provision time. This avoids modifying the subscription check constraint (`auth_type != 'subscription' OR provider_api_key_id IS NULL AND integration_credential_id IS NULL …`) and keeps runners user-scoped while credentials are shareable account-wide.
3. **Injection.** In `provision.rb`:
   - Make `claude_subscription_auth?` also return true when a managed token exists for the run's account+runner.
   - In the `claude_subscription_auth?` branch (≈`:2103`), append `CLAUDE_CODE_OAUTH_TOKEN=<token>` to the container env.
   - When a managed token is used, **skip seeding the host `.credentials.json`** so the env token is the unambiguous source (avoids precedence conflicts).
4. **UI.** `RunnerCredentialsController` + views mirroring `IntegrationCredentialsController`, with an entry point from the runner edit form (`app/views/runners/_form.html.erb`). A single labeled field ("paste your `claude setup-token` value") plus a "long-lived" checkbox — never raw JSON. Pundit policy and account scoping consistent with other credential models.

### Phase 3 — Self-heal via upstream refresh (experimental)

- Upstream: add a refresh-token exchange API to `AgentHarness::Authentication` and fix the native credential shape so a refreshed credential is written back in a form the CLI reads.
- Paid: a keep-warm path (provision preflight and/or periodic job) that, for host-forwarded Claude credentials, calls the exchange, persists the rotated credential to the source under a lock (the Codex `with_codex_auth_lock` pattern), and re-seeds. Classify `refresh_token_reused` as `auth_expired`.

### Phase 4 — Browser-completed real login (full host-independence)

Goal: a user authorizes a real Claude login from the Paid UI using only their browser — no terminal, SSH, or shell on the host/devcontainer, and nothing installed locally. The OAuth code is PKCE-bound to the session that generated the URL (claude-code#47994), so the reliable, TOS-clean way to do this is to keep the **official `claude` login running as one live process** and let the human complete the browser step against it. Three routes, in preference order:

- **4a — Real interactive login over a server-side PTY (preferred).** Paid spawns the official interactive `claude` `/login` (or `claude auth login`) inside an ephemeral, single-tenant container with an isolated `CLAUDE_CONFIG_DIR`. In a headless container the CLI falls back to the documented "open this URL, paste the code here" mode (WSL/SSH/containers). The user opens the URL in their own browser tab, authorizes with their Anthropic account, and returns the code; Paid feeds it to the **same** live process, so the PKCE challenge matches. On success Paid reads the resulting `.credentials.json` (access + **refresh** token) from the isolated config dir, stores it as a `RunnerCredential`, and tears down the container. Two UI variants:
  - **(i) Form-bridged (lighter, smaller surface).** Paid drives the login; the UI shows only the authorize URL and a "paste your code" field, and Paid writes the code to the process stdin. No general terminal is exposed. Fragility: parsing the CLI's prompt/URL from TUI output (version-dependent).
  - **(ii) Full browser terminal (xterm.js + PTY over WebSocket).** The live session is surfaced to the browser via xterm.js so the human reads and drives the real terminal — robust to CLI TUI changes, at the cost of more infrastructure and a larger surface. (Terminalwire is an adjacent model but streams a server-side CLI to a *native thin client the user installs locally*, reintroducing a local-install requirement; xterm.js keeps it browser-only.)

  This is the pattern cloud IDEs and bastions already use (Codespaces, Gitpod, Coder, Teleport web terminals): the official tool, run by a human, surfaced over the web — no OAuth reimplementation. It yields the short-lived interactive credential (~24h) plus a refresh token, so it **depends on Phase 3** (Paid-side refresh) to stay durable; `setup-token`'s 1-year token is not obtainable here because it relies on a localhost callback with no cross-host paste fallback.
- **4b — Headless CLI drive without a live session (pending upstream).** If `claude auth login` gains a `--code`/`--code-file`/`--no-browser` or device-code flag (requested in claude-code#47994), the live-process requirement disappears and a simple URL→code exchange suffices. Watch that issue; adopt if it ships.
- **4c — Re-implement the PKCE flow in Paid (TOS gray area, last resort).** Generate the authorize URL + verifier (agent-harness `auth_url` + an upstream code-exchange API), accept the code, exchange it, store a `RunnerCredential`. Reuses Claude Code's OAuth client ourselves rather than the CLI, so only if 4a/4b are infeasible.

All routes land their credential in the Phase 2 `RunnerCredential` store and reuse the Phase 2 injection path. **Security is the dominant cost of 4a:** a browser→process→container bridge is effectively web-exposed command execution, so it must be authenticated to the Paid user, authorized via Pundit to their own account, run a *constrained* session (an auto-launched login-only wrapper, not a general shell), use an ephemeral single-tenant container on a restricted network, time-box the WebSocket/session token, capture-then-destroy the credential, and audit the action.

## Alternatives Considered

- **Raw `.credentials.json` paste (original "option 1").** Rejected as the primary UX: obtaining and pasting the nested OAuth JSON (including the refresh token) is a power-user operation. The encrypted store is retained as the substrate; only the ingestion UX changes (long-lived token paste, later in-app OAuth).
- **Mount Claude `.credentials.json` read-write like Codex.** Rejected: the Claude CLI does not refresh headlessly, so an RW mount would not self-heal; it would also expose more of `~/.claude` to container writes and hit single-use refresh-token races without serialization.
- **Force subscription Claude onto API-key/proxy mode.** Rejected: defeats the purpose of subscription runners (using the user's plan) and changes the cost/billing model; orthogonal to the auth-resilience problem.
- **User-scoped credentials (like `ProviderApiKey`).** Rejected in favor of account scoping (like `IntegrationCredential` / `GithubToken`) for team sharing and a consistent audit trail; runners remain user-scoped and resolve a shared credential at runtime.
- **Refresh-token self-heal first (user's initial instinct).** Deferred to Phase 3: it is net-new OAuth-exchange code with real uncertainty (headless-refresh bug, rotation race, undocumented endpoint), whereas long-lived tokens are a faster and more reliable unblock.
- **Paid-orchestrated `setup-token` to capture a 1-year token automatically.** Rejected as infeasible today: `setup-token` requires a browser + localhost callback on the initiating machine and has no headless/manual mode, so an orchestrator cannot bridge it. Captured under Phase 4 as a "watch upstream" item rather than a current option.
- **Naive stdin relay of `claude auth login` (URL out, code in via pipe).** Rejected: the code is PKCE-bound to the originating session, so feeding it to a fresh process fails (claude-code#47994). Only a same-process flow (PTY-driven `/login`, or a future `--code` flag) can work; folded into Phase 4a.

## Trade-offs

**Positive**

- Eliminates the silent failure: expired auth becomes a loud, actionable dashboard signal and a correctly classified run outcome.
- Decouples runner auth from host/devcontainer state; enables cloud/headless deployments (Phase 2 onward).
- Keeps provider-specific OAuth logic upstream in agent-harness, consistent with RDR-007 and the "no provider-specific behavior scattered in Paid" rule.
- Reuses proven encryption/audit/multi-tenancy patterns (`IntegrationCredential`, `GithubToken`, logidze).

**Negative / Risks**

- Long-lived tokens are higher-value secrets with a ~1-year blast radius; mitigated by `encrypts`, account scoping, revoke, logidze audit, and `last_used_at`.
- Generating a `setup-token` still requires one interactive browser session somewhere until Phase 4 ships.
- agent-harness's current `auth_status`/`refresh_auth` shape gap requires an interim Paid-side parser; carries `TODO` debt until the upstream fix lands.
- Phases 3/4 depend on undocumented Claude OAuth endpoints and an agent-harness release; treat as experimental and gate behind validation.
- Phase 4a adds a browser→process→container bridge — effectively web-exposed command execution. It is the highest-risk surface in this RDR and must be tightly scoped (constrained login-only session, ephemeral single-tenant container, Pundit authz, time-boxed session, audit) per RDR-004/RDR-010; a full xterm.js terminal is riskier than the form-bridged variant.
- Phase 4's captured credential is short-lived (~24h), so a durable Phase 4 requires Phase 3; the two ship together for a complete host-independent story.

## Implementation Plan

**Phase 1 (detection) — small, low risk, immediate value**

1. Add exit-0 + preflight auth classification in `run_agent_activity.rb`.
2. Add `Runners::AuthHealth` (prefer `claude auth status`; interim native-shape parser as fallback).
3. Add `DashboardController#show` loader + `_auth_health_banner` partial.
4. Add `ClaudeAuthHealthCheckJob` + GoodJob cron registration.
5. Specs: exit-0 auth classification; auth-health service for valid/expired/missing; banner rendering; job flagging.

**Phase 2 (long-lived token) — migration + UI + injection**

1. `RunnerCredential` model + migration + logidze; schema dump.
2. Runtime resolution by `(account, runner_key)`.
3. `provision.rb`: detection + `CLAUDE_CODE_OAUTH_TOKEN` injection + skip host seed when managed token present.
4. `RunnerCredentialsController` + views + Pundit policy + runner-form entry point.
5. Specs: model (encryption, scoping, revoke, validation); injection (env var present, host seed skipped, detection true); request specs for the credentials UI/policy.

**Phase 3 / Phase 4 — sequenced behind Phases 1–2**

- File agent-harness issues: (a) `auth_status`/`refresh_auth` native `claudeAiOauth` shape; (b) refresh-token exchange API; (c) code-exchange API for the 4c fallback.
- Phase 3: refresh-token exchange (upstream) + Paid keep-warm writeback under a lock (the Codex `with_codex_auth_lock` pattern); classify `refresh_token_reused` as `auth_expired`.
- Phase 4a: server-side PTY login in an ephemeral, constrained, single-tenant container; credential capture from the isolated `CLAUDE_CONFIG_DIR` + teardown; start with the form-bridged variant before the xterm.js terminal. Scope the bridge per RDR-004/RDR-010 (authn, Pundit authz, login-only wrapper, time-boxed session, audit).
- Watch claude-code#47994 for a headless/`--code`/device-code flag on `claude auth login`; if it ships, implement Phase 4b and skip the 4c PKCE re-implementation.
- Reference these with `TODO(#…)` at the interim Paid parser and any injection seams.

**Cross-cutting**

- Feature branch + PR; no direct commits to `main`. Conventional Commits. No `--no-verify`.
- Update this RDR's status to Final before implementation; Implemented after.

## Validation

- **Detection.** Simulate an expired host credential (past `expiresAt`) and a missing credential; assert `Runners::AuthHealth` reports invalid with the right `source`, the banner renders, and the job flags it. Simulate a runner exit-0 with an auth-error body; assert it is classified `auth_expired` rather than recorded as success.
- **Long-lived token.** With a stored `RunnerCredential`, assert `claude_subscription_auth?` is true with no host file, `CLAUDE_CODE_OAUTH_TOKEN` is present in the container env, the host `.credentials.json` seed is skipped, and a real subscription Claude run authenticates end-to-end.
- **Security.** Token is encrypted at rest, scoped to account, revocable, audit-tracked (logidze), and never logged in plaintext or placed on a command line.
- **Interactive login (Phase 4a).** A user with only a browser completes `claude` login end-to-end: the URL is surfaced, the pasted code reaches the same live process, and the captured credential (with refresh token) is stored as a `RunnerCredential` and then refreshed by Phase 3. The bridge rejects unauthenticated/cross-account access, exposes only the login-only session (no arbitrary shell), and the container is torn down after capture.
- **Regression.** Existing host-forwarded Claude and Codex (RW self-heal) paths remain unchanged when no managed credential is present.
