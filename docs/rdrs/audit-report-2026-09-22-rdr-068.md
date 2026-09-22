# RDR-068 Audit Report — 2026-09-22

## Summary

RDR-068 (Apple Platform Verification Workers) was accepted on `main` through
PR #3929 with the `apple_verification_workers` feature flag default-off. The
implementation chain under umbrella issue #3930 shipped the control-plane
contracts, persistence, trusted-host lifecycle boundary, Tart provider
translation, guest protocol/admission, guest network-policy contract, and the
project-facing verification UI.

This closeout audit (issue #3942, following the
[RDR Closeout Checklist](closeout-checklist.md)) compared **every** RDR-068
acceptance criterion against the code, tests, and LID intent actually on
`main`, and re-ran the Apple verification test surface.

**Status decision: Partially Implemented.** The security-shaped control-plane
boundaries are shipped and strongly tested (299 passing examples across
`spec/models/apple_verification*`, `spec/services/apple_verification*`,
`spec/services/agent_runs/apple_verification*`, `spec/lib/apple_verification*`,
`spec/requests/projects/apple_verifications_spec.rb`, and
`spec/migrations/*apple*`). However, several RDR acceptance criteria are not
met by shipped code — most notably `.paid/apple-verification.yml` parsing,
agent-facing MCP tools, scheduling/admission/timeout, completion- and
PR-gate enforcement, retained-VM lockdown expiry, worker quarantine, the
operator setup guide, and all live-VM acceptance evidence (real builds,
launches, captures on a macOS host). Because implementation is not complete,
this closeout does **not** close umbrella issue #3930; gap issues must be
filed from §7 and the flag must remain default-off.

## Audit context

- **RDR**: `docs/rdrs/RDR-068-apple-platform-verification-workers.md`
- **Audit date**: 2026-09-22
- **Closeout issue**: #3942 (part of umbrella #3930; dependencies #3939,
  #3940, #3941)
- **Test evidence run**: `bundle exec rspec` over every Apple-related spec
  path — 299 examples, 0 failures (53 + 246 across two invocations), plus the
  four dbless migration specs.
- **LID coherence**: `bin/coherence-check.mjs` passes with no Apple-related
  findings (all reverse-orphan `@spec` IDs and uncovered `[ ]` specs predate
  RDR-068 and belong to other segments).

## What shipped (with evidence)

### Contracts and persistence (RDR Phase 1)

| Capability | Code | Tests |
|---|---|---|
| Immutable worker profiles; project modes `off`/`on_demand`/`automatic` | `app/models/apple_worker_profile.rb`, `Project#apple_verification_mode` (`app/models/project.rb:238-242`) | `spec/models/apple_verification_workers_spec.rb` ("persists only the three project modes", profile immutability/digest/creator cases) |
| Provider-neutral RDR-057 input/output manifests; forbidden host/credential fields; secret-shaped value rejection | `app/services/apple_verification_workers.rb` | `spec/services/apple_verification_workers_spec.rb` (6 examples) |
| Workflow revisions: `draft`/`approved`/`superseded`/`disabled`; digest-bound approval; one approved revision per project; immutable approved binding; permanent approval record | `app/models/apple_verification_workflow_revision.rb` (`approve!`, `supersede!`, `disable!`, validation chain) | `spec/models/apple_verification_workers_spec.rb` (approval binding/freezing cases), `spec/requests/projects/apple_verifications_spec.rb` |
| Attempts: binding invariants, advisory-draft gate rule, revoked-profile rejection, immutable execution binding | `app/models/apple_verification_attempt.rb` | `spec/models/apple_verification_workers_spec.rb` (attempt gate/binding/revocation cases) |
| One-attempt waivers (actor, reason, expiry, source, revision, gate, check IDs) | `app/models/apple_verification_waiver.rb`, `app/services/apple_verification_attempts/waive.rb` | `spec/models/apple_verification_workers_spec.rb` (waiver ownership/admin/check cases), `spec/requests/projects/apple_verifications_spec.rb` |
| Protected artifacts with tenant RLS | `app/models/apple_verification_artifact.rb`, `db/migrate/20260920173056_create_apple_verification_artifacts.rb` | `spec/migrations/…_create_apple_verification_artifacts…` (dbless) |
| Audit events + resource-ledger linkage to attempts; `verification_vm` ledger kind | `db/migrate/20260919071227_…`, `db/migrate/20260919072053_…`, `AppleVerification::Lifecycle` | `spec/models/apple_verification_workers_spec.rb` ("keeps Apple audit and VM-ledger ownership bound to the attempt") |
| Default-off rollout flag | `app/services/feature_flags.rb:67-73` (`DEFINITIONS`, owner, rollout plan, cleanup criteria) | flag-gating assertions in every gated spec below |

### Trusted host service and Tart provider (RDR Phase 2, control-plane side)

| Capability | Code | Tests |
|---|---|---|
| Authenticated versioned fixed-vocabulary lifecycle API (`readiness clone start inspect stop destroy inventory`); rejects executable text, paths, mounts, unapproved images, off-boundary tags | `app/services/apple_verification/host_service.rb` | `spec/services/apple_verification/host_service_spec.rb` (8 examples incl. "rejects executable text, paths, mounts, and unapproved images before provider work") |
| Authenticated transport to the host service | `app/services/apple_verification/host_client.rb` | via `tart_runner_spec.rb` + `lifecycle_spec.rb` |
| Tart/Softnet translation: idempotent clone/start/stop/destroy/inspect, ownership-tag inventory, restart recovery, request-ID scoping per run | `app/services/apple_verification/tart_provider.rb` | `spec/services/apple_verification/tart_provider_spec.rb` (10 examples) |
| Reconciliation-only runner registered from `APPLE_VERIFICATION_HOST_URL`/`APPLE_VERIFICATION_HOST_TOKEN` | `app/services/apple_verification/tart_runner.rb` | `spec/services/apple_verification/tart_runner_spec.rb` (3 examples) |
| Crash-window provisioning intent, ledger entry before clone, opaque handle persistence, retry-from-recorded-VM, orphan re-linking | `app/services/apple_verification/lifecycle.rb` | `spec/services/apple_verification/lifecycle_spec.rb` (7 examples incl. post-clone crash and tag-discovered orphan convergence) |

### Immutable image catalog and guest execution (RDR Phase 3, control-plane side)

| Capability | Code | Tests |
|---|---|---|
| Image catalog: immutable toolchain/resources/network/GUI-account/smoke-test facts; promotion requires passing smoke test; deprecation/retirement/revocation lifecycle; Logidze history | `app/models/apple_verification_image.rb` | `spec/models/apple_verification_image_spec.rb` (17 examples) |
| Guest protocol v1: closed operation vocabulary, per-operation payload fields, declarative UI actions, capture-failure staging | `lib/apple_verification/guest_protocol.rb` | `spec/lib/apple_verification/guest_protocol_spec.rb` (10 examples) |
| Guest executor transport: HTTPS-only endpoint from image provenance, bearer auth, fail-closed contract attachment | `lib/apple_verification/guest_connection.rb` | `spec/lib/apple_verification/guest_connection_spec.rb` (4 examples) |
| Guest admission boundary: flag check, account-scoped active-image selection, manifest validation, contract destination re-validation (IP literals, schemes) | `app/services/apple_verification/execute_guest_job.rb` | `spec/services/apple_verification/execute_guest_job_spec.rb` (9 examples) |

### Guest network policy (RDR Phase 4, policy side)

| Capability | Code | Tests |
|---|---|---|
| Flag-gated contract production from the run's resolved egress snapshot (proxy-only, `locked` profile); fail-closed when disabled | `app/services/agent_runs/apple_verification/resolve_guest_contract.rb` | `spec/services/agent_runs/apple_verification/resolve_guest_contract_spec.rb` |
| Credential-free declarative contract: Paid DNS, proxy-only routing, deny-by-default, deny host services, blocked override, HTTP(S) only | `app/services/agent_runs/apple_verification/guest_contract.rb` | `spec/services/agent_runs/apple_verification/guest_contract_spec.rb` |
| Request-time enforcement + audited denials: direct IP/IPv6, alternate DNS, proxy override, unsupported protocol, port/scheme mismatches; credential-free audit writes | `app/services/agent_runs/apple_verification/validate_guest_request.rb`, `guest_network_request.rb`, `network_policy_error.rb` | `spec/services/agent_runs/apple_verification/validate_guest_request_spec.rb` (20+ adversarial examples) |

### Project UI (RDR Phase 6, user side)

| Capability | Code | Tests |
|---|---|---|
| Verification surface gated on the flag; mode setting; revision comparison; protected artifact signed URLs; approve/rerun/cancel/waive/destroy-retained-VM controls with `manage_apple_verifications?` policy | `app/controllers/projects/apple_verifications_controller.rb`, `app/policies/project_policy.rb:31`, `config/routes.rb:234-242`, `app/views/projects/apple_verifications/*`, `app/views/projects/show.html.erb:136` | `spec/requests/projects/apple_verifications_spec.rb` (13 examples), `spec/requests/projects_spec.rb:611` |

## Acceptance-criterion audit

Status legend: **S** satisfied by shipped code + tests · **P** partial (core
shipped, named piece missing) · **G** gap (missing or live-evidence-only).

### Functional

| # | Criterion | Status | Evidence / what is missing |
|---|---|---|---|
| F1 | Clean VM clone repeatedly builds, tests, launches, captures the smoke iOS app | G | Control-plane lifecycle + guest dispatch shipped (see §3), but no live-host run exists. No smoke app harness, no repeat-run evidence artifact, and the guest executor itself ships in the VM image (outside this repo). Nothing in-repo or in docs records a post-acceptance clean-clone run. |
| F2 | Same for `viamin/ColorMatching-iOS` | G | Same as F1. The 2026-09-18 manual pilot (RDR §Feasibility pilot) predates the shipped control plane; it is design evidence, not acceptance evidence. |
| F3 | Native macOS GUI app builds, tests, launches, app-window screenshot | G | Protocol supports `capture` platform `macos` target `app_window` (`lib/apple_verification/guest_protocol.rb:115-118`), and `resize_window` UI action exists. No live macOS app run evidence. |
| F4 | Mixed repository executes multiple iOS/macOS profiles sequentially | G | `.paid/apple-verification.yml` parsing/validation/inference is **not implemented** (no parser exists anywhere in `app/` or `lib/`), so multiple profiles cannot even be declared. Sequential execution scheduler is also missing (see R2/R4). |
| F5 | Paid-agent runs an uncommitted draft, inspects results, revises, reruns | G | Model layer supports advisory draft attempts at `agent_iteration` (`apple_verification_attempt.rb:71-73`) and idempotent rerun exists (`AppleVerificationAttempts::Rerun`). Missing: content-addressed workspace-bundle creation from the agent container, and the semantic MCP tools an agent would call. No production caller of `ExecuteGuestJob`/`Lifecycle` exists yet. |
| F6 | Administrator approves a committed digest; required screenshot enforces selected gate | P | Approval is fully shipped and tested (digest-bound, superseding, admin-only). **Enforcement is not wired**: nothing consults an approved revision at `completion_verification`/`pull_request_verification` to block an agent run's success or the PR verification result (grep for those gate names finds only Apple models). |
| F7 | Changing an approved workflow creates a draft and cannot alter the enforced revision | S | Approved bindings are immutable and approval records permanent (`apple_verification_workflow_revision.rb:125-141`); tests "binds and freezes approval inputs while superseding the prior approval", "keeps a superseded revision's approved binding immutable". |
| F8 | Build/test-only profiles work without screenshot requirements | P | `required_checks`/`advisory_checks` are free-form, so build/test-only revisions are representable, and `GuestProtocol` makes `capture` just another (optional) operation. Without the yml parser (F4) there is no end-to-end proof. |

### Security

| # | Criterion | Status | Evidence / what is missing |
|---|---|---|---|
| S1 | Guest project code cannot reach host SSH, filesystem, personal data, keychain, devices, container runtime | P | Shipped, tested defenses: host API cannot express commands/paths/mounts (`host_service_spec.rb`); Softnet profile wiring (`tart_provider.rb:124`); image catalog enforces the isolated GUI-account posture (`apple_verification_image.rb:120-125` + spec "requires every dedicated guest-account isolation assertion"). Missing: the automated live host/guest isolation smoke test (RDR Phase 2 deliverable) and device-isolation proof on a real host. |
| S2 | Host service rejects arbitrary commands, repository paths, unapproved images | S | `host_service.rb` fixed vocabulary + `FORBIDDEN_KEYS` + approved-image allowlist + Paid-tag validation; spec "rejects executable text, paths, mounts, and unapproved images before provider work". |
| S3 | Guest traffic cannot bypass policy via direct IP, alternate DNS, proxy override, unsupported protocol | S (control plane) / G (live guest) | Control plane fully tested: `validate_guest_request_spec.rb` (direct IP + IPv6 with audit redaction, alternate DNS, proxy override, unsupported protocol incl. userinfo redaction), `execute_guest_job_spec.rb` (IP-literal/IPv6/scheme contract destinations), `guest_contract_spec.rb` (frozen destinations, egress-gateway proxy). Live proof that a booted guest actually honors the contract (DNS/proxy enforcement inside the VM image) has no recorded run. |
| S4 | Revoked/expired credentials cannot be used by a retained failed VM | G | No credential revocation or network-disable step runs on failure retention. `DestroyRetainedVm` requests early cleanup and the waiver/rerun paths exist, but the automatic lockdown (revoke credentials, disable networking, 1-hour expiry) is not implemented. |
| S5 | Secret scanning confirms manifests, logs, screenshot metadata, artifacts do not expose credentials | P | Manifest-level: forbidden keys + secret-shaped value rejection shipped and tested (`apple_verification_workers_spec.rb`); audit writes redact credentials/userinfo (tested). No scanner runs over real result artifacts/metadata; artifact ingestion itself is not implemented yet. |
| S6 | No verification path can fall back to host execution | S | The only host boundary (`HostService`) cannot express project commands; the lifecycle API is the sole provider entry; no fallback code path exists. Enforced by construction and by the host-service spec's rejection cases. |

### Reliability and operations

| # | Criterion | Status | Evidence / what is missing |
|---|---|---|---|
| R1 | Provision, start, stop, destroy, retry, reconciliation idempotent | S | `tart_provider_spec.rb` (duplicate requests, restart recovery for start/stop/destroy, request-ID scoping), `lifecycle_spec.rb` (duplicate request reuses handle; retry from recorded VM). |
| R2 | Cancellation, timeout, host restart, control-plane restart, orphaned-VM scenarios converge to known ledger state | P | Host restart, control-plane crash windows (pre-clone, post-clone), and orphan discovery converge with ledger/audit writes (`lifecycle_spec.rb`, `tart_runner_spec.rb`). **Cancellation only flips DB status** (`apple_verification_attempts/cancel.rb`) — it never stops/destroys the VM or records the terminal ledger transition. **Attempt timeout (45 min default) is not implemented at all.** |
| R3 | Infrastructure and policy failures distinguishable from project failures | P | `network_policy` is a distinct audited failure category; capture failures classify by stage; `failure_classification` column + closed output-manifest taxonomy exist. No result-ingestion path populates the taxonomy for real build/test outcomes yet. |
| R4 | Admission prevents a new clone below configured host/guest thresholds | G | No admission control exists: the RDR's operator-configurable defaults (1 active VM, ≥60 GiB host disk, ≥25% free memory, ≥15 GiB guest disk) are not implemented anywhere; `HostService#readiness` reports capacity but nothing consumes it. |
| R5 | One Apple worker alongside three active paid-agent containers within thresholds | G | Only the 2026-09-18 manual pilot table in the RDR records this measurement. It predates the shipped stack; no re-measurement artifact exists. |
| R6 | Successful VMs destroyed promptly; failed VMs lock down and expire as configured | G | Destroy primitives + reconciliation cleanup exist and are tested; prompt destroy on success and timed (default 1 h) expiry with lockdown are not wired to any attempt-completion path. |
| R7 | Quarantined worker cannot receive work until operator smoke test + return to service | G | Image-level revocation/deprecation is shipped and tested, but worker/host-level quarantine after repeated health failures — and the operator return-to-service gate — is not implemented. |

### Product and audit

| # | Criterion | Status | Evidence / what is missing |
|---|---|---|---|
| P1 | Users and agents receive equivalent structured verification state | P | Users: full attempt/revision/artifact surface (`apple_verifications_spec.rb` presents "workflows, attempt results, audit evidence, and protected artifacts"). Agents: **no MCP tools shipped** (`verify_apple_project`, `get_apple_verification`, `capture_apple_screenshot`, `stop_apple_verification` do not exist). |
| P2 | Every approval, waiver, transition, denial, artifact, external resource attributable to actor and attempt | S | `approved_by`/`approved_at`, waiver `created_by`, denial audit events with actor-safe metadata (`validate_guest_request_spec.rb`), ledger entries bound to attempts with ownership matching (model spec), artifact FK + RLS. |
| P3 | Public PR surfaces do not expose screenshots by default | S | Screenshots are protected artifacts behind project authorization + time-limited signed URLs (request specs); no PR-surface integration exists, so nothing is published by default. (PR-status links arrive with the gate-enforcement gap F6.) |
| P4 | Feature unavailable unless both rollout flag and project policy permit | S | `require_feature` in the controller (raising `Pundit::NotAuthorizedError`), view gating (`projects/show.html.erb:136`), flag checks in `Lifecycle`, `ExecuteGuestJob`, `ResolveGuestContract`; specs cover disabled-flag paths everywhere. |
| P5 | Canonical Markdown setup guide sufficient for a new operator | G | No operator guide or guided setup command ships in `docs/` or `bin/`. Only `.env.example:57-60` documents host URL/token. `APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN` (read by `GuestConnection`) is undocumented. |

## Rollout guard verification

- `apple_verification_workers` is registered in `FeatureFlags::DEFINITIONS`
  (`app/services/feature_flags.rb:67-73`) with owner, default-off rollout plan,
  and cleanup criteria tied to this closeout.
- Every shipped runtime surface calls
  `FeatureFlags.enabled?(:apple_verification_workers, project:)` before
  exposing or dispatching: UI controller + views, `Lifecycle#provision`,
  `ExecuteGuestJob`, `ResolveGuestContract`. Verified by tests that assert
  disabled-flag behavior.
- Project mode remains an independent gate (`projects.apple_verification_mode`
  check-constrained to `off`/`on_demand`/`automatic`, default `off`).
- **Staging the rollout**: this closeout finds the Rollout Guard's enablement
  preconditions **not yet met** — the worker profile, network proxy, and
  isolation smoke test must pass on a live macOS host with the shipped stack
  before any pilot project is enabled (gaps F1-F3, R5). The flag therefore
  stays default-off; broad enablement remains blocked on the gap issues below.
  No flag cleanup is performed (correctly — cleanup criteria are not met).

## Capacity and recovery evidence

- **Recovery (control plane)**: durable. The provisioning-intent/ledger design
  survives pre-clone, post-clone, duplicate-request, host-restart, and
  orphan-discovery windows, each asserted against ledger state in
  `lifecycle_spec.rb` / `tart_provider_spec.rb` / `tart_runner_spec.rb`.
- **Capacity**: the only quantitative evidence is the manual 2026-09-18 pilot
  (RDR §Feasibility pilot). No measurement exists for the shipped stack, and
  the admission thresholds that would enforce capacity at runtime are not
  implemented (R4/R5 gaps). Recording live capacity evidence requires a macOS
  host and is filed as part of the live-validation gap issue.

## Gaps and proposed child issues

Per checklist step 3, each unmet criterion needs its own focused issue. The
`gh` CLI is unavailable in this environment, so the issues could not be filed
from here; the bodies below are ready to paste against `viamin/paid`. When
filing, do not apply any effective auto-pick skip label (`planning`,
`research`, `waiting`, `tracking`, `epic`, `needs-manual-setup`) — these must
remain auto-pickable. All live-host issues should carry `needs-manual-setup`
**only if** the project's effective skip set is intentionally extended to keep
them out of automation — otherwise leave unlabeled.

1. **Live RDR-068 acceptance validation on a macOS host** (F1, F2, F3, R5;
   also collects S1/S3 live evidence) — build/test/launch/capture the smoke
   iOS app, `viamin/ColorMatching-iOS`, and a representative native macOS GUI
   app from clean clones through the shipped control plane; record repeat-run
   and capacity-alongside-three-agent evidence; archive the report under
   `docs/rdrs/`.
2. **`.paid/apple-verification.yml` parsing, validation, inference, and
   diagnostics** (F4, F8) — typed schema, unknown-operation rejection,
   multi-profile repositories, user-confirmed inference from shared schemes
   and test plans.
3. **Apple verification scheduling, admission, queueing, and timeout**
   (R2, R4) — fair per-account/project queue with position + cancel; the
   operator-configurable admission defaults (1 active VM, 60 GiB host disk,
   25% free memory, 15 GiB guest disk); 45-minute attempt timeout; runtime
   rechecks; cancellation that actually stops/destroys the VM and converges
   the ledger.
4. **Agent-facing MCP tools for Apple verification** (F5, P1) —
   `verify_apple_project`, `get_apple_verification`,
   `capture_apple_screenshot`, `stop_apple_verification` with project-bound
   authorization and agent-scoped cancellation, plus the uncommitted
   content-addressed bundle lane for draft iteration.
5. **Lifecycle-gate enforcement wiring** (F6) — approved required workflows
   block agent-run success reporting (`completion_verification`) and Paid's PR
   verification result (`pull_request_verification`); waivers unblock; pending
   (not skipped) when capacity is unavailable.
6. **Retained-failure lockdown and timed destruction** (S4, R6) — on failure
   retention: revoke credentials, disable guest networking, destroy after the
   configured window (default 1 h); prompt destroy on success; attempt
   terminal ledger transitions.
7. **Worker quarantine and return-to-service** (R7) — repeated host-health
   failures quarantine the worker, revoke credentials, stop scheduling; an
   operator isolation smoke test gates return to service.
8. **Operator setup guide and guided preflight command** (P5) — canonical
   Markdown guide + read-only preflight validating Tart/Softnet, capacity,
   image registration, and smoke tests; document
   `APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN` in `.env.example`.
9. **Result ingestion and failure taxonomy population** (R3, S5 artifact
   scanning) — persist structured output manifests, parsed build/test
   summaries, required/advisory check outcomes, and screenshot metadata onto
   attempts; run secret scanning over ingested artifacts.

## Status decision

**Partially Implemented.** Roughly the RDR's Phases 1, the control-plane
halves of 2-4, and the user-facing half of 6 shipped with disciplined,
adversarial test coverage and coherent LID intent (four segments, all `[x]`
specs with passing tests). Phases 5's repository-config parsing, 6's agent
interfaces and gate enforcement, 4's scheduling/admission, the operational
lockdown/quarantine/timeout behaviors, the operator guide, and all live-host
acceptance evidence remain open, tracked by the gap issues above.

Consequences per the closeout checklist:

- RDR-068 Metadata status becomes **Partially Implemented**; a dated
  `2026-09-22 Closeout` section records this audit.
- `docs/rdrs/README.md` status column updated to match.
- The closeout PR uses **non-closing** language for umbrella #3930
  ("Tracks #3930") because implementation is incomplete; #3930 must stay
  open until the gap issues land.
- `apple_verification_workers` stays default-off; broad enablement and flag
  cleanup wait for the live validation evidence.
