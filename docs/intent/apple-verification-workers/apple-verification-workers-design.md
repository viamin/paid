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
lifecycle gate, and required/advisory checks. Only an approved revision is
eligible to enforce a gate; a project administrator's serialized approval
supersedes the prior approved revision without mutating it, leaving at most one
approved revision per project. Attempts bind the approved revision, its profile
and lifecycle gate, and exact source.

Waivers are one-attempt records with a project-administrator actor, reason,
expiry, source, revision, gate, and check identities. Execution audit events
and RDR-060 resource ledger rows may point to an attempt and must retain
matching account/project ownership. The ledger's `verification_vm` kind is the
durable external VM identity.
