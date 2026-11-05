# EARS Specs: Unified Tracker Work Items

> Planned claims. Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Tracking issue: #4854. Rollout decision: [RDR-079](../../rdrs/RDR-079-unified-tracker-work-items-linear-github-migration.md).

- [ ] **UNIFIED-WORK-ITEMS-001** — The system SHALL represent GitHub and
  external tracker tickets through a provider-neutral work-item contract with
  stable provider/resource identity, normalized fields, typed provider
  extensions, retained raw payloads, assignment provenance, and explicit
  relationships to separate pull-request review artifacts.

- [ ] **UNIFIED-WORK-ITEMS-002** — When an account configures Linear, the
  system SHALL support one workspace connection with observable health,
  configurable synchronization defaulting to 15 minutes, pagination and
  rate-limit outcomes, and clearly reported unsupported operations.

- [ ] **UNIFIED-WORK-ITEMS-003** — During Linear synchronization, the system
  SHALL idempotently retain all supported ticket metadata, comments, projects,
  teams, users, relations, dependencies, cycles, attachments, archive/delete
  state, and raw provider payloads, keyed by provider identity; imported
  comments SHALL NOT be reposted.

- [ ] **UNIFIED-WORK-ITEMS-004** — The browser and assignment services SHALL
  show unassigned work first and support filters, individual and bulk
  assignment, current-and-future/future-only/no-auto-assignment mapping modes,
  issue-level customization or replacement, assignment provenance, affected
  issue review flags, preview/confirmation, and mapping- or issue-level
  execution-project defaults.

- [ ] **UNIFIED-WORK-ITEMS-005** — When a user starts a workflow from a
  unified ticket, the system SHALL preserve existing project permissions and
  issue workflow behavior. GitHub-sourced content SHALL remain admitted only
  through the existing GitHub-user allowlist and `issue.trusted?` gate;
  explicit account/project team, user, and provider-identity mappings SHALL be
  an additional admission path for non-GitHub providers and SHALL NOT replace
  or widen that GitHub path. The system SHALL post comments as the configured
  API-key user when permitted and allow agent-run lifecycle writes to be
  configured independently.

- [ ] **UNIFIED-WORK-ITEMS-006** — When lifecycle mappings are configured
  between Linear and Paid, the system SHALL synchronize supported changes in
  both directions with loop prevention, surface simultaneous conflicting
  changes for human review, and never treat an unsupported provider operation
  as successful.

- [ ] **UNIFIED-WORK-ITEMS-007** — The GitHub migration SHALL run offline and
  idempotently, preserve GitHub identity, metadata, comments, Paid state,
  assignments, agent-run history, relationships, provenance, and the existing
  trusted-GitHub-user configuration; it SHALL reconcile issues created during
  the maintenance window and keep existing GitHub issue workflows operational
  through the unified model.

- [ ] **UNIFIED-WORK-ITEMS-008** — Pull requests SHALL remain separate review
  artifacts, with discoverable relationships for Paid-created PRs where
  possible and explicit user linking otherwise; ticket migration SHALL NOT
  replace pull-request review, approval, branch, commit, or merge semantics.

- [ ] **UNIFIED-WORK-ITEMS-009** — Implementation issue #4855 SHALL add the
  default-off `:unified_work_items` guard to `FeatureFlags::DEFINITIONS` and
  wire its runtime decision. A project-scoped unified
  entry point SHALL evaluate
  `FeatureFlags.enabled?(:unified_work_items, project:)`. An account-scoped
  unified entry point SHALL establish `Current.account` and evaluate
  `FeatureFlags.enabled?(:unified_work_items)` against that account's
  `tenant_settings.features` override; it SHALL NOT render or mutate unified
  state without that account context. This includes synchronization, workflow
  admissions, browser and project-page browsing/read surfaces, assignment,
  lifecycle operations, and account Linear/trust settings. While disabled,
  those surfaces SHALL continue existing GitHub issue behavior and SHALL NOT
  expose unified-ticket behavior. Disabling the flag SHALL preserve imported
  records, audit data, and explicit overrides, and the guard SHALL remain
  until the RDR-079 closeout audit verifies synchronization, migration, trust,
  conflict, relationship, rollback, and regression behavior.
