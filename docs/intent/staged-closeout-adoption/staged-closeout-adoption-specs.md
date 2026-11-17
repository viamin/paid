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

- [x] **STAGED-CLOSEOUT-ADOPTION-008** — When the curated Fully Automatic (`solo_automated`) profile is planned or (re)applied, Paid SHALL treat staged-closeout enrollment as an explicit profile target — enabled by Fully Automatic and explicitly off for every other curated profile — persist the enrollment through the authorized profile workflow with reviewer identity and revision history, serialize concurrent first enrollment creation, restore the prior value on profile rollback, and SHALL NOT enable a deployment executor, Operations remediation, or bypass a disabled phase or missing required authorization; absent an approved mapping or available target the project SHALL receive an inspectable waiting reason.
  *Test:* `spec/services/configuration/profiles/solo_automated_staged_enrollment_spec.rb`, `spec/services/staged_closeout_adoption/enrollment_target_spec.rb`, `spec/services/automation/effective_policy_staged_verification_spec.rb`, `spec/services/configuration_profiles/applier_staged_enrollment_spec.rb`.
