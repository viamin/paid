# EARS Specs: Apple Verification Presentation

- [x] **APPLE-VERIFY-001** — When `apple_verification_workers` is enabled for
  a project, authorized users SHALL see the project mode, inferred profiles,
  workflow revisions, and attempts; when disabled, the UI SHALL not expose the
  capability.
- [x] **APPLE-VERIFY-002** — When an administrator approves a draft workflow,
  Paid SHALL retain its content digest, verification files, worker profile,
  checks, and gate, and supersede the prior approval; non-draft revisions SHALL
  be rejected.
- [x] **APPLE-VERIFY-003** — Each presented attempt SHALL retain and present
  its explicit lifecycle state, retry number, source digest, commit identity,
  workflow, profile, gate, and failure classification; its structured build,
  test, coverage, and policy-decision results with the source of each result;
  and its execution audit evidence.
- [x] **APPLE-VERIFY-004** — Screenshots and recordings SHALL be presented as
  protected artifacts rather than embedded public content, through an
  authorized endpoint that issues a time-limited storage URL.
- [x] **APPLE-VERIFY-005** — When an authorized user selects two workflow
  revisions from the same project, Paid SHALL present every digest,
  verification-file, check, gate, revision, or status field whose values
  differ.
- [x] **APPLE-VERIFY-006** — Project administrators SHALL be able to rerun or
  cancel an attempt, waive required checks for one failed attempt with a
  reason and expiry, and request early cleanup of a retained failed VM. A
  rerun SHALL be idempotent per terminal source attempt and retain its retry
  parent.
