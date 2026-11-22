---
parent: PAID
prefix: SUBSCRIPTION-RUNNER-AUTH
---

# Low-Level Design: Subscription Runner Auth

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment backfills the implemented managed subscription-runner auth lifecycle
> described in `docs/rdrs/RDR-041-subscription-runner-auth-lifecycle.md`.

## Purpose

Paid supports subscription-auth CLI runners whose credentials are native OAuth
or session artifacts rather than normal provider API keys. The system must keep
the canonical credential state in Paid, materialize only the runtime form each
CLI expects, and preserve the shipped exceptions around remote safety and
host-forwarded fallback.

## Shipped Behavior

The provider-neutral contract lives in `Runners::SubscriptionAuthProviders` and
`Runners::SubscriptionAuthMaterializers`. Together they classify managed
credentials, describe how each provider materializes runtime auth, and expose
whether that managed materialization is remote-safe.

Claude remains remote-safe through managed env/native-file materialization with
server-side refresh semantics. Codex materializes a managed `auth.json`, uses a
lease-through-run refresh/harvest lifecycle, and intentionally remains
`remote_safe: false` until the broader hardening bar is met. Gemini and
Copilot regenerate minimal native config files from managed credentials and are
remote-safe for the shipped acceptance scope, while their provider-owned login
flows and harvest behavior remain deferred follow-on work.

Provisioning records managed-versus-host-forwarded auth telemetry and preserves
the legacy host-path fallback when managed rollout is disabled or when no
managed credential exists.

The runner login UI is now registry-driven. A single Connect Runner surface
enumerates only the registered flows, then delegates to the existing Claude
browser-capture or OpenAI device-code engines with a target `runner_key`.
This lets Claude-browser login capture credentials for both `claude` and `omp`,
and lets the OpenAI device-code flow capture credentials for both `codex` and
`opencode`, while preserving the legacy routes.

That picker is now the single nav-level entry point. The Operations menu
(desktop and mobile) links to it as "Runner Logins," replacing the
Codex-only "Codex Login" item; visibility is gated the same way the picker
itself authorizes (`RunnerCredential` — owner/admin), so the nav item never
promises a flow the viewer can't start. The Runners page no longer has a
standalone "Connect Runner" header button — that verb collided with "Add
Runner," which creates a `Runner` record rather than a credential.
Discoverability for subscription auth is preserved at the two points users
actually need it: the Runners page empty state (when no more runner types
can be added) and the Add Runner form's runner-key field, both of which
link to the same picker. The legacy `new_codex_login_session_path` route
stays mounted for deep links; it just lost its dedicated nav entry.

The Connect Codex and Claude Browser Login pages surface the account's active
managed credential (name, status, expiry — never token material) before a new
login is started, mirroring the one-active-credential guard the runner
credentials UI applies. The login flows themselves stay permissive: completing a
login under a different `credential_name` still creates a concurrent active
credential; the banner warns about it rather than hard-rejecting, so
rotation-by-relogin under the same name keeps working without a revoke step.

Managed materialization now includes `opencode` and `omp`. OpenCode reuses the
managed OpenAI `auth.json` payload at its native credentials path and, like
Codex, keeps that rotating credential on a per-credential lease with pre-run
refresh and post-run harvest/writeback into the canonical `RunnerCredential`.
OMP materializes a broker-import JSON derived from the canonical Claude
credential, refreshes that canonical Claude credential before materialization
when it is near expiry, installs it through `omp auth-broker import`, and
harvests the broker's rotated OAuth state back into the canonical
`RunnerCredential` before releasing the per-credential lease. Both remain
`remote_safe: false` until broader remote-hardening is proven.

Credential readiness is shared by agent provisioning and isolated text
execution. It classifies fresh access, refreshable expiry, revoked state,
missing refresh material, and unsupported refresh without inspecting or
logging token contents. An expired Codex or OpenCode credential is selected
only while its canonical unrevoked auth state can reach the configured
provider-owned OpenAI OAuth client; OMP uses the agent-harness Claude exchange.
The same row and lease serialize refresh and later rotation harvest. If that
exchange cannot make the record fresh, no expired native file is materialized.
When concurrent records exist, a usable fresh credential takes precedence over
a newer expired credential that cannot reach refresh; the latter cannot shadow
the former at routing, readiness, materialization, or harvest boundaries.
All isolated-text routing and dashboard readiness surfaces use this shared
classification, so a recoverable expiry is not reported as missing.
Host-forwarded rotation remains intentionally separate: it is not imported
into a managed record unless an existing authorized identity/writeback boundary
already establishes equivalence.

Codex recovery adapts the published harness's explicit native-store contract.
While holding the canonical row lease, Paid writes only the selected managed
record into a private temporary `auth.json` with mode `0600`. The public harness
metadata selects its generation and account; recovery receives that explicit
path, generation, account and a 45-second deadline. Paid validates the returned
credentials/metadata envelope against the resulting private store, subscription
billing, the selected identity and fresh usable native credentials before the
existing canonical persistence action. A changed canonical generation or revoked
record cannot be overwritten. Temporary native state is removed on success and
failure, including cancellation. Provider transport and token interpretation stay
in the harness and existing credential interface; no host auth is imported.
OpenCode and OMP retain their separate existing exchange contracts. Release
adoption and actual selected-credential operating acceptance remain separate
gates from this adapter (#5280, #5262 and #5208).

## Exceptions Preserved

- **Codex remote placement is still gated off.** The managed materializer is
  shipped, but remote-safe scheduling remains intentionally disabled.
- **Gemini and Copilot refresh/harvest remain deferred.** Their shipped scope
  is managed materialization plus fallback preservation, not full provider-owned
  lifecycle management.
