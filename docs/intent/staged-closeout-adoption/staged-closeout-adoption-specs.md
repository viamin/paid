# EARS Specs: Staged Closeout Adoption

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
