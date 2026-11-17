# EARS Specs: Staged Closeout Adoption

- [x] **STAGED-CLOSEOUT-ADOPTION-006** — When an authorized maintainer opens project acceptance-check settings, Paid SHALL provide HTML controls to inspect and change enrollment, review or replace a mapping using current criteria and permitted registry targets, revoke a mapping, and inspect revision history with reviewer identity, time and eligibility reasons; equivalent JSON actions SHALL remain available.
  *Test:* `spec/requests/projects/staged_closeout_adoptions_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-007** — When a reviewed mapping is changed or admitted, Paid SHALL reject in-place changes to its reviewed inputs and reject admission for a different source issue, project, account or enrollment.
  *Test:* `spec/services/staged_closeout_adoption/mappings_eligibility_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-001** — When a project has no staged-closeout enrollment, it SHALL be disabled, regardless of auto-merge or auto-pick settings.
  *Test:* `spec/services/staged_closeout_adoption/enroll_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-002** — When an authorized maintainer enables, disables, approves, changes, or revokes staged-closeout adoption, Paid SHALL persist the actor and time and retain superseded mapping history.
  *Test:* `spec/services/staged_closeout_adoption/mappings_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-003** — When a mapping is reviewed, Paid SHALL accept only a current stable criterion, permitted registry target with pinned version and digest, matching stage/phase, and project/account scope; untrusted proposals SHALL not approve it.
  *Test:* `spec/services/staged_closeout_adoption/mappings_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-004** — When an enrollment is disabled, a mapping is replaced or revoked, or its target changes, mapping admission SHALL reject it with an inspectable reason while retaining history.
  *Test:* `spec/services/staged_closeout_adoption/mappings_eligibility_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-005** — When a project or account with reviewed staged-closeout mappings is deleted, Paid SHALL delete its mappings, source issues, enrollment, and owning tenant records without a dependency-order failure.
  *Test:* `spec/models/project_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-008** — When Paid authoritatively observes a source PR merge for an enabled project, it SHALL admit one queued synthetic `closeout_verification` run for every eligible current `merged_revision` mapping, pinning project, source issue, criterion, source PR, observed merged SHA, recipe version, and recipe digest; it SHALL not dispatch that run through ordinary agent execution.
  *Test:* `spec/services/closeout_verifications/admit_spec.rb`.

- [x] **STAGED-CLOSEOUT-ADOPTION-009** — When the same merge is observed by Paid auto-merge, a GitHub webhook, concurrent delivery, or a bounded reconciliation sweep, Paid SHALL converge to the same run identity; an invalid mapping, unavailable authority, pause, absent lineage, current result, or unconfirmed live target SHALL produce an inspectable no-run reason.
  *Test:* `spec/services/closeout_verifications/admit_spec.rb`, `spec/requests/api/github_webhooks_spec.rb`, `spec/jobs/closeout_verification_reconciliation_sweep_job_spec.rb`.
