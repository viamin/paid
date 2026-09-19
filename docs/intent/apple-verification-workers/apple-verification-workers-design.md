# Apple Verification Workers Design

Apple verification is a separate execution boundary: the control plane submits
only fixed VM lifecycle requests to an authenticated macOS host service. The
service delegates provider-specific Tart and Softnet work to a provider, and
never receives project paths, mounts, commands, or executable text.

`AppleVerification::HostService` is the versioned, authenticated host boundary.
`AppleVerification::TartProvider` translates its fixed request vocabulary to
Tart and Softnet adapters. `AppleVerification::Lifecycle` records a
provisioning intent and an external-resource ledger entry before clone, then
persists an opaque handle after start. It registers its configured Apple cleanup
adapter before recording an intent, persists a request ID as the lifecycle
idempotency key, and leaves a created intent reconcileable if a later lifecycle
step fails. Inventory is normalized to `ExecutionRunners::ManagedResource` for
normal reconciliation.

The `apple_verification_workers` feature flag remains default-off. This phase
does not schedule project verification or execute guest jobs.

*HLD:* `docs/high-level-design.md` → isolation by default and portable providers.
*RDR:* `docs/rdrs/RDR-068-apple-platform-verification-workers.md`.
