---
parent: PAID
prefix: APPLE-RESULT
---

# Low-Level Design: Apple Verification Results and Artifacts

## Purpose

This segment defines the contract an Apple verification attempt produces: the
structured result users and agents consume, and the flow of `.xcresult`
bundles, build logs, screenshots, and diagnostics into Paid's artifact storage
with retention and privacy. The presentation layer that renders these records
lives in `docs/intent/apple-verification/`; the execution lifecycle that
produces them lives in `docs/intent/apple-verification-attempts/`.

## Structured result contract

Each attempt returns one structured result that travels through the RDR-057
output manifest whose allowlisted fields `AppleVerificationWorkers` already
validates (`schema_version remote_execution.apple_verification.v1`; attempt,
result, artifacts, lanes sections — APPLE-WORKER-002). The persisted result
retains:

- terminal state, timings, retry lineage, and failure classification
  (APPLE-ATTEMPT-009 taxonomy);
- source digest, commit identity, workflow revision, and lifecycle gate;
- worker profile digest, image digest, and macOS, Xcode, SDK, and Simulator
  runtime versions;
- the selected project, workspace, scheme, test plan, and destination;
- parsed build and test summaries;
- required and advisory check outcomes;
- screenshot metadata with protected artifact references;
- network-policy denials and infrastructure events; and
- external-resource ledger and execution-audit-event references.

Result data is derived from the validated output manifest and the control
plane's own records — never scraped from user-facing logs — so agents and
users see equivalent structured state.

## Artifact flow

Guests upload `.xcresult` bundles, build logs, screenshots, and safe
diagnostics through Paid's artifact lane. Each artifact lands as an
`AppleVerificationArtifact` bound to its attempt, carrying kind, content type,
storage key, safe metadata, and an expiry. Large binaries follow Paid's
existing artifact storage and retention policy; metadata and provenance remain
after the binaries expire, so an attempt's outcome stays explainable after
cleanup. Capture results keep the structured failure detail (launch,
readiness, action, selection, or export) produced by the guest protocol
(`apple-guest-execution` APPLE-VERIFY-004) instead of collapsing it.

## Privacy and safety

Screenshots and recordings are private project artifacts. PR status links to
the protected, authorized artifact views owned by the presentation segment
(`apple-verification` APPLE-VERIFY-004); screenshots are not published into
public PR comments by default. Result metadata and artifact metadata pass the same secret-safe
scanning as manifests (APPLE-WORKER-002) and never contain raw credentials,
proxy credentials, or payload bodies.

## Agent equivalence

Paid-agents receive the same structured verification state through semantic,
project-bound MCP operations — `verify_apple_project`,
`get_apple_verification`, `capture_apple_screenshot`, and
`stop_apple_verification` — available only when the
`apple_verification_workers` rollout flag and the project mode permit. An
assigned paid-agent may submit its source, run draft or approved workflows on
demand, inspect results, and cancel its own active attempts. A capture request
persists the declared `requested_capture` on its attempt, carries it to the
worker, and returns it through verification state so the selected capture
cannot be confused with a general verification request. An agent cannot approve
workflows, enable automatic mode, alter network policy, select privileged
images, create waivers, or exceed project quotas.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Reuse the RDR-057 output manifest as the result contract | One validated, credential-free transfer lane already exists; a second result format would drift. | An Apple-specific result payload posted out-of-band, which would bypass manifest validation and lane audit. |
| Keep metadata after binaries expire | Outcomes must stay auditable (RDR-061) without paying eternal binary retention. | Deleting everything together, which orphans ledger and audit references. |

*HLD:* `docs/high-level-design.md` → isolation by default; observable
everything.
*RDR:* `docs/rdrs/RDR-068-apple-platform-verification-workers.md`.
