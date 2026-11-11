---
parent: PAID
prefix: LIVE-PREVIEW
---

# Low-Level Design: Live Web App Preview

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the shipped preview and verification capabilities from
> RDR-045, including the August 2026 end-to-end closeout.

## Purpose

RDR-045 is implemented. The repository ships real preview/session/browser
infrastructure together with the user-facing lifecycle and verification-result
flows that consume it.

## Shipped Foundations

The repo now includes substantial runtime infrastructure:

- `PreviewSession` plus tunnel-reservation and preview-provision state models
- `Previews::Provision`, tunnel management, and cleanup behavior for booting an
  app, its dependencies, and a preview tunnel
- Playwright trace production plus trace-viewer UI components
- verification browser sidecar provisioning and playwright-mcp MCP attachment
  for agent runs that enable verification
- asynchronous preview lifecycle handling from queued provisioning through
  ready, failure, stopping, and cleanup
- persisted interactive-verification outcomes, app-log tails, and artifact
  metadata for review flows

These are real execution surfaces, not placeholders.

## Interactive Verification Result Contract

After the agent executes, `AgentRuns::VerificationResultRecorder` reads the
agent-written verification result, normalizes it, and persists the outcome on
the `AgentRun` before commit bookkeeping. It also retains app-log and artifact
metadata so review flows can distinguish what the agent verified from merely
having provisioned a browser sidecar. This runs for both successful and
non-zero runner exits, preserving verification evidence when the run fails.

### Reported outcome versus observed evidence

Interactive JSON is agent-authored reporting, not an execution attestation.
The recorder therefore retains its status, browser steps, and criterion claims
as `reported_*` data while separately recording recorder-owned facts: the
tested commit when one is available, normalized runtime configuration, bounded
app-log retention, artifact provenance, and evidence freshness. A claimed
criterion is `unverified` unless a recorder-owned assertion supports it;
reported failures, skips, and not-run states remain explicit. Screenshots and
app logs are useful artifacts but never prove arbitrary behavior merely by
existing.

Reported artifact paths are only assessed relative to the repository and are
never promoted into trusted object-storage keys. Recorder-created app logs are
retained under the existing project object-storage namespace when available;
missing, inaccessible, oversized, and untrusted artifacts remain visible as
explicit states. Evidence becomes stale when its commit differs from the run's
reviewed commit. This supplements RDR-076's shared evidence contract; it does
not create merge authority or a separate acceptance model.

## Repository-Owned Verification Journeys

An application repository may provide `.paid/journeys.md` as concise,
versioned guidance for interactive verification. The guide complements, rather
than duplicates, `.paid/screenshots.yml`: screenshot configuration remains the
source of routes, test authentication, and seed-data setup. A create-PR agent
whose checkout contains the guide receives its path in the verification prompt
and selects the journey that covers its changed surface. The prompt requires
the agent to record the actual browser steps, observed result, and available
run-owned artifacts through the existing verification result contract.

For Paid's own checkout, the pilot guide covers sign-in, the Projects index,
and a project-detail page. Its helper commands prepare the isolated database,
reset only the seeded verification account, and remove that account during
cleanup. Seed creation stamps the account with a persisted `seed_owner`
marker (`accounts.seed_owner`); journey reuse and cleanup require that marker,
so an unmarked account that merely collides on the journey slug or email is
refused with `AccountCollision`/`IdentityCollision` instead of being adopted
or destroyed. The helper refuses to run outside the development and test
environments. The permanent system journey is the maintenance check for the
guide's login and routes, and separately pins the guide's documented
launch command to one the agent's own execution container can run; that
command is intentionally independent of `Screenshots::RuntimePlan`'s
generic `bin/dev`-preferring derivation, since the agent container does not
ship the `tmux`/Overmind supervisor `bin/dev` needs. A separate Paid-managed
implementation run remains required as inspectable operational evidence
before the pilot can be expanded.

### Criterion verification references

Every issue implementation run receives the criterion-result schema and may
report a criterion's selected verification kind and structured references to a
test result or other inspectable evidence, even when the project has not
enabled interactive verification. The recorder preserves these as reported
references only: it never promotes them, their names, browser steps, or prose
into verified coverage. Failed, skipped, and not-run criteria remain visibly
contradicted, skipped, or unverified so a skipped ephemeral job or unavailable
browser flow cannot disappear behind a green broad suite. Runtime
configuration, browser claims, and app-log evidence remain conditional on the
project's interactive-verification setting.

### Criterion input receipts

An issue implementation run may additionally supply a bounded rationale,
limitations, and inspected inputs for each criterion. The recorder validates
only mechanical properties of those inputs: a repository path's containment,
existence, pinned reviewed revision, and digest; the provenance of an artifact
Paid retained for the run; or the shape of an explicit external/human
reference. It labels each input `verified`, `contradicted`, `stale`, or
`unavailable` and records the receipt state as the most severe of those labels,
so a receipt reaches `verified` only when every cited input is verified. The
receipt remains separate from the agent's semantic conclusion: validating
inputs never changes criterion coverage from `unverified` or grants merge
authority. Rationales, limitations, excerpts, and other agent text are bounded
and redacted before persistence, and the receipt repeats only the checked
identity and the mechanical verdict so the reported claim is stored once.

Paid attests only to what it can check itself. A cited test execution is an
agent report rather than a recorder-owned result, so it is not a receipt
input: an agent cites the inspected test file as a `repository_file` input and
reports the observed outcome as a reported reference. The one recorder-owned
artifact an agent may cite is the run-owned application log, cited by the
repository-relative path the agent wrote. The recorder matches that path
against the artifacts it retained for the run, and the storage key it chose
stays internal to Paid.

The receipt path is additive. Existing criterion reports without inputs retain
their reported-only behavior. The receipt creates no second evidence store: a
project with the layered-verification add-on keeps its append-only
`LayeredVerificationCheckResult` records as the durable record for
recorder-owned execution outcomes.

The initial receipt pilot is observational and non-blocking. Its serialized
per-run metrics count mechanically caught false input claims and record
validation runtime and retained receipt bytes. Valid-claim rejection and review
usefulness are explicitly `unavailable` until reviewers supply adjudication
and feedback; these measures must be available before proposing any CI or
merge policy.

## Trace Artifact Contract

Real agent-run trace viewing is tied to the same durable storage contract used
by screenshot capture publishing:
`screenshots/<org>/<repo>/pr-<number>/<commit>/trace.zip`.
The UI only embeds the viewer after a storage existence check succeeds for that
exact object key, so disabled storage and failed uploads degrade to the
"No trace available" state instead of a broken iframe.

Future live-preview session recording may need its own directly shareable trace
links, but that is a separate deferred contract. This segment does not treat
session-specific trace URLs as interchangeable with the screenshot-comment /
agent-run trace artifact path above.

## What this is not

- **Not the polyglot runtime segment.** Phoenix support here is preview-specific
  foundation work; the shared language/runtime contract lives in
  `polyglot-test-execution`.
- **Not a production-data bridge.** Preview sessions remain intended for local
  or seeded data only.
- **Not a host-credential bridge.** Setup and app startup commands executed
  inside the preview container run repo-controlled code, so the environment
  handed to them is built from an explicit non-secret allowlist
  (`Previews::Provision::PREVIEW_ENV_ALLOWLIST`). Host credentials such as
  `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, and `RAILS_TEST_KEY` are not
  forwarded; the only host env vars that cross the trust boundary are
  non-secret runtime selectors (`RAILS_ENV`, `RACK_ENV`).

## Trust Boundary: Upstream Header Allowlist

The preview proxy sits between the Paid browser session and a
repository-controlled app. Repository code is untrusted and must not receive
Paid-origin credentials, so the middleware applies a strict allowlist of
upstream request headers (see `LIVE-PREVIEW-009`). Specifically:

- The browser `Cookie` and `Authorization` headers are dropped on the
  forwarded request. Browsers attach these to every same-origin request
  automatically, so forwarding them would leak the Paid session/Devise
  cookie (and any cached HTTP-auth credential) to repository-controlled code
  purely because the preview shares Paid's origin.
- Any Paid-specific cookie or session header (e.g. the `cable_user_id` cookie
  stamped by `ApplicationController#stamp_cable_auth_cookie`, the Devise
  session cookie) is dropped because it lives inside `Cookie`.
- `X-CSRF-Token` and `X-XSRF-Token` are forwarded, not dropped. Unlike
  Cookie/Authorization, browsers never attach these automatically — they
  only appear when application JS sets them explicitly, so they carry the
  preview app's own CSRF token, not an automatically-leaked Paid credential.
  Dropping them unconditionally broke standard Rails/JS preview apps that
  rely on header-based CSRF protection for POST/fetch requests, violating
  the RDR-045 "forwarded apps require zero changes" contract.
- The proxy continues to rewrite `Host`, `X-Forwarded-*`, and `Origin` itself,
  and it forwards a narrow set of safe-to-pass-through headers (`Accept*`,
  `Cache-Control`, conditional-request headers, `Sec-CH-UA*`, `Sec-Fetch-*`,
  `User-Agent`, `X-CSRF-Token`/`X-XSRF-Token`, and the WebSocket upgrade
  headers when applicable).
- The same allowlist applies to WebSocket upgrades; without it, repository
  code could read browser credentials from the WebSocket handshake request.
