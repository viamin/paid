# EARS Specs: Apple Verification Presentation

- [x] **APPLE-VERIFY-001** — When `apple_verification_workers` is enabled for
  a project, authorized users SHALL see the project mode, inferred profiles,
  workflow revisions, and attempts; when disabled, the UI SHALL not expose the
  capability.
- [x] **APPLE-VERIFY-002** — When an administrator approves a draft workflow,
  Paid SHALL retain its digest, referenced files, constraints, checks, and
  gate, and supersede the prior approval.
- [x] **APPLE-VERIFY-003** — Each attempt SHALL retain queue, retry lineage,
  outcome, provenance, explicit failure class, cancellation, rerun, and
  one-attempt waiver state.
- [x] **APPLE-VERIFY-004** — Screenshots and recordings SHALL be presented as
  protected artifacts rather than embedded public content.
