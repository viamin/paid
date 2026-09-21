---
parent: PAID
prefix: APPLE-WORKER
---

# Low-Level Design: Apple Verification Workers

Apple verification is a provider-neutral, guest-only verification capability.
`AppleWorkerProfile` is an immutable, account-owned description of a permitted
guest image and capability constraints. `AppleVerificationWorkers` accepts only
semantic capabilities and RDR-057-compatible manifests with allowlisted fields;
it rejects unsupported capability combinations and raw or secret-shaped
credential material before any provider is asked to provision.

Each project selects `off`, `on_demand`, or `automatic`. A workflow revision
records its committed digest, verification-file references, worker profile,
lifecycle gate, and required/advisory checks. A draft revision may run only at
the `agent_iteration` advisory gate; only an approved revision is eligible to
enforce a gate, and approval requires an active profile. A project
administrator's serialized approval supersedes the prior approved revision
without mutating it, leaving at most one approved revision per project.
Attempts bind the eligible revision, its profile and lifecycle gate, and exact
source; no attempt may use a revoked profile.

The macOS host service is a separate, authenticated execution boundary. The
control plane submits only fixed lifecycle requests; it never supplies project
paths, mounts, commands, or executable text. `AppleVerification::HostService`
authenticates versioned requests and delegates provider-specific Tart and
Softnet operations to `AppleVerification::TartProvider`. The API uses only
provider-neutral handles and immutable, allowlisted images.

`AppleVerification::Lifecycle` records provisioning intent and an
external-resource ledger entry before cloning, then persists an opaque handle
after start. A request ID is an idempotency key scoped to the agent run. A
failed start leaves its created VM and ledger entry retryable; a repeat request
resumes from the recorded provider ID, while an abandoned intent remains
reconcileable. The cleanup adapter is configured at boot from
`APPLE_VERIFICATION_HOST_URL` and `APPLE_VERIFICATION_HOST_TOKEN`, allowing the
durable cleanup queue to recover a VM after the request process exits.
`AppleVerification::TartRunner` normalizes host inventory to
`ExecutionRunners::ManagedResource` for normal reconciliation.

Waivers are one-attempt records with a project-administrator actor, reason,
expiry, source, revision, gate, and check identities. Execution audit events
and RDR-060 resource ledger rows may point to an attempt and must retain
matching account/project ownership. The ledger's `verification_vm` kind is the
durable external VM identity.

`AppleVerification::ConfigurationParser` reads `.paid/apple-verification.yml`
into a typed `AppleVerification::Configuration`: one or more named profiles,
each with a platform, an optional compatible worker constraint, an Xcode
project or workspace with scheme and optional test plan, an optional
dependency bootstrap declaration limited to Swift Package Manager, a tests
block, and declarative UI-flow captures built from an allowlisted operation
vocabulary. An unknown flow operation or an unsupported bootstrap system
(CocoaPods, Carthage, Bazel, Tuist) raises a deterministic diagnostic before
any provisioning is attempted. `AppleVerification::InferConfiguration`
derives a best-effort starting configuration from a repository file listing —
detected `.xcodeproj`/`.xcworkspace` projects, their shared schemes and test
plans — but the result is always advisory until a user reviews and commits
it; inference never creates an approved revision.
`AppleVerificationWorkflowRevisions::SyncFromConfiguration` parses committed
configuration content, resolves an active worker profile compatible with
every declared platform, and creates or updates the project's current draft
revision with the file's content digest and the required/advisory checks
derived from the configuration. It only ever touches a draft; an approved
revision's binding is immutable, so a functional change always lands in a new
or updated draft, never in place.

The `apple_verification_workers` feature flag remains default-off. This phase
implements the trusted host lifecycle boundary; it does not schedule project
verification or execute guest jobs. Attempt admission, execution ordering,
failure classification, gate enforcement, and recovery intent live in
`docs/intent/apple-verification-attempts/`; the structured results and
artifact contract lives in `docs/intent/apple-verification-results/`.

*HLD:* `docs/high-level-design.md` → isolation by default and portable providers.
*RDR:* `docs/rdrs/RDR-068-apple-platform-verification-workers.md`.
