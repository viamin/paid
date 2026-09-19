# EARS Specs: Apple Verification Presentation

- [x] **APPLE-VERIFY-001** — When `apple_verification_workers` is enabled for
  a project, authorized users SHALL see the project mode, inferred profiles,
  workflow revisions, and attempts; when disabled, the UI SHALL not expose the
  capability.
- [x] **APPLE-VERIFY-002** — When an administrator approves a draft workflow,
  Paid SHALL retain its digest, referenced files, constraints, checks, and
  gate, and supersede the prior approval; non-draft revisions SHALL be
  rejected.
- [x] **APPLE-VERIFY-003** — Each attempt SHALL retain queue, retry lineage,
  outcome, provenance, explicit failure class, cancellation, rerun, and
  one-attempt waiver state. Reruns SHALL require an on-demand-capable project
  mode and create a queued attempt without dispatching until a worker lifecycle
  can execute it and ingest a terminal result; only queued or running attempts
  may be cancelled; only failed required attempts may be waived; and only
  failed attempts without a recorded destruction may record retained-VM
  destruction.
- [x] **APPLE-VERIFY-004** — Screenshots and recordings SHALL be presented as
  protected artifacts rather than embedded public content.
