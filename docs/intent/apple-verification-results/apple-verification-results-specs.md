# EARS Specs: Apple Verification Results and Artifacts

> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Identifiers are reserved ahead of the implementation issues (RDR-068
> Phase 0); the `Tests:` and `Code:` surfaces below are the ones those issues
> will add.

- [ ] **APPLE-RESULT-001** — Each terminal Apple verification attempt SHALL
  retain a structured result with terminal state, timings, retry lineage,
  failure classification, source digest and commit identity, workflow revision
  and lifecycle gate, worker profile and image digests with macOS, Xcode, SDK,
  and Simulator runtime versions, the selected project, workspace, scheme,
  test plan, and destination, parsed build and test summaries, required and
  advisory check outcomes, network-policy denials, and infrastructure events.
  *Tests:* `spec/services/apple_verification_results/assemble_spec.rb`
  *Code:* `AppleVerificationResults::Assemble`

- [ ] **APPLE-RESULT-002** — When an attempt reports its outcome, the result
  SHALL travel through the validated RDR-057 output manifest sections
  (attempt, result, artifacts, lanes) with only allowlisted fields and no raw
  or secret-shaped credential values.
  *Tests:* `spec/services/apple_verification_results/ingest_spec.rb`
  *Code:* `AppleVerificationResults::Ingest`

- [ ] **APPLE-RESULT-003** — Each uploaded `.xcresult` bundle, build log,
  screenshot, or diagnostic SHALL be ingested as an attempt-bound
  `AppleVerificationArtifact` carrying its kind, content type, storage key,
  safe metadata, and expiry; large binaries SHALL follow Paid's existing
  artifact storage and retention policy while result metadata and provenance
  remain after the binaries expire.
  *Tests:* `spec/services/apple_verification_results/ingest_spec.rb`
  *Code:* `AppleVerificationResults::Ingest`

- [ ] **APPLE-RESULT-004** — Screenshots and recordings SHALL remain private
  project artifacts: PR status SHALL link only to protected, authorized
  artifact views, and public PR surfaces SHALL NOT expose screenshots by
  default.
  *Tests:* `spec/services/apple_verification_results/pr_status_spec.rb`
  *Code:* `AppleVerificationResults::PrStatus`

- [ ] **APPLE-RESULT-005** — Result and artifact metadata SHALL NOT contain
  raw credentials, proxy credentials, or payload bodies and SHALL pass the
  same secret-safe scanning applied to manifests.
  *Tests:* `spec/services/apple_verification_results/ingest_spec.rb`
  *Code:* `AppleVerificationResults::Ingest`

- [ ] **APPLE-RESULT-006** — Paid-agents SHALL receive the same structured
  verification state as users through the project-bound semantic operations
  `verify_apple_project`, `get_apple_verification`, `capture_apple_screenshot`,
  and `stop_apple_verification`, available only when the rollout flag and
  project mode permit; an agent SHALL NOT be able to approve workflows, enable
  automatic mode, alter network policy, select privileged images, create
  waivers, or exceed project quotas.
  *Tests:* `spec/lib/apple_verification/agent_tools_spec.rb`
  *Code:* `AppleVerification::AgentTools`
