# Apple Verification Workers Design

Apple verification is a separate execution boundary: the control plane submits
only fixed VM lifecycle requests to an authenticated macOS host service. The
service delegates provider-specific Tart and Softnet work to a provider, and
never receives project paths, mounts, commands, or executable text.

`AppleVerification::HostService` is the versioned, authenticated host boundary.
`AppleVerification::TartProvider` translates its fixed request vocabulary to
Tart and Softnet adapters. `AppleVerification::Lifecycle` records a
provisioning intent and an external-resource ledger entry before clone, then
persists an opaque handle after start. It persists a request ID as a lifecycle
idempotency key scoped to its agent run. A failed start leaves its created VM
and ledger entry in a retryable provisioning state; a repeat request resumes
start from the recorded provider ID, while an abandoned created intent remains
reconcileable. Each Rails process builds the
Apple cleanup adapter from `APPLE_VERIFICATION_HOST_URL` and
`APPLE_VERIFICATION_HOST_TOKEN` during boot, so the durable cleanup queue can
recover a VM after the original request process exits. The host boundary returns
plain inventory records; `AppleVerification::TartRunner` normalizes them to
`ExecutionRunners::ManagedResource` for normal reconciliation.

The `apple_verification_workers` feature flag remains default-off. This phase
does not schedule project verification or execute guest jobs.

*HLD:* `docs/high-level-design.md` → isolation by default and portable providers.
*RDR:* `docs/rdrs/RDR-068-apple-platform-verification-workers.md`.
