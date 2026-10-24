---
parent: project-readiness
prefix: PROJECT-READINESS
---

# EARS Specs: Project readiness

- [x] **PROJECT-READINESS-001** — When a caller supplies a project and an
  available repository checkout, the system SHALL return a readiness result
  with an evaluated-at timestamp and zero or more gaps, where every gap has
  `kind`, `description`, and structural `evidence`, without writing state,
  acquiring a repository, or requesting AI judgment.
  *Code:* `Projects::Readiness`, `Projects::Readiness::Evaluate`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-002** — When a project's `tdd_mode` is `strict` or
  `non_strict`, the system SHALL report a `missing_ci` gap unless the checkout
  contains `.github/workflows/`, `.circleci/config.yml`, or `.gitlab-ci.yml`;
  SHALL report a `missing_test_directory` gap unless the applicable detector's
  test directory exists; and SHALL report a `missing_test_command` gap unless
  the applicable detector identifies a runnable command.
  *Code:* `Projects::Readiness::Rules::Tdd`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-003** — When `tdd_mode` is `off`, the system SHALL
  add no TDD-specific readiness gaps, while allowing independent future rules
  to add their own gaps.
  *Code:* `Projects::Readiness::Rules::Tdd`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-004** — When a detector is added for an ecosystem,
  the system SHALL select it before the language-command fallback when it is
  applicable. For Godot/GDScript, the detector SHALL use `test`/`tests` as
  test-directory evidence and `addons/gdUnit4` as test-command evidence; the
  Forager-iOS fixture containing only `AGENTS.md`, `README.md`, and `docs/`
  SHALL therefore report all three strict-TDD gaps.
  *Code:* `Projects::Readiness::Detector`,
  `Projects::Readiness::Detectors`,
  `Projects::Readiness::Detectors::Godot`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-013** — When a Godot checkout has either the
  installed `addons/gdUnit4/bin/GdUnitCmdTool.gd` command or executable
  repository-owned `bin/install-test-tools` and `bin/test` entry points, the
  system SHALL identify its command as configured. It SHALL distinguish an
  installed command from a command whose dependency setup is required, and
  SHALL report a missing command when neither supported form exists. The
  evaluator SHALL not execute setup or test scripts, download dependencies, or
  treat an addon directory alone, arbitrary filename, CI YAML text, or a prior
  successful check as command evidence; setup/test execution outcomes remain
  isolated runtime evidence.
  *Code:* `Projects::Readiness::Detectors::Godot`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-005** — When a project's enabled development or
  verification capability has one or more persisted readiness gaps, the system
  SHALL surface exactly one project-backed `project_setup_pending` Inbox entry
  to authorized operators, including every stored gap's description and
  evidence; it SHALL not require `auto_pick_enabled`, and a satisfied snapshot
  SHALL not appear. The Inbox badge and availability filters SHALL use the
  queue's eligibility, and the setup detail SHALL attribute the gap to its
  actual blocking capability.
  *Code:* `Inbox::Queue`, `Inbox::Count`, `Inbox::Availability`.
  *Test:* `spec/models/project_spec.rb`, `spec/services/inbox/queue_spec.rb`,
  `spec/services/inbox/count_spec.rb`, `spec/services/inbox/availability_spec.rb`.

- [x] **PROJECT-READINESS-006** — When a project is created with TDD or
  interactive verification enabled, or when a readiness evaluation records a gap
  set different from the project's prior snapshot, the system SHALL persist the
  result and invalidate the Inbox cache. It SHALL queue evaluation after
  creation with an enabled readiness capability and re-evaluation after a
  TDD-mode or verification setting change, after a project-service-container
  association change, after a service rename on an associated container, and
  after a completed run with a result commit, but SHALL not evaluate during
  Inbox polling.
  *Code:* `Projects::Readiness::Record`, `EvaluateProjectReadinessJob`,
  `Project`, `ProjectServiceContainer`, `ServiceContainer`, `AgentRun`.
  *Test:* `spec/services/projects/readiness/record_spec.rb`,
  `spec/models/project_spec.rb`, `spec/models/project_service_container_spec.rb`,
  `spec/models/service_container_spec.rb`,
  `spec/requests/projects/service_containers_spec.rb`,
  `spec/models/agent_run_spec.rb`.

- [x] **PROJECT-READINESS-007** — When an authorized operator explicitly
  triggers bootstrap from a current `project_setup_pending` Inbox entry, the
  system SHALL queue one manual `bootstrap_readiness` run carrying the current
  readiness gaps and normal token accounting. It SHALL not create another
  unfinished bootstrap run for that project, SHALL not automatically retry a
  terminal bootstrap attempt, and SHALL leave a failed attempt's readiness
  entry visible for a new explicit trigger, including its failure reason and
  a link to the run details.
  It SHALL re-evaluate only after GitHub reports that the bootstrap PR merged,
  so the next snapshot is target-branch evidence.
  *Code:* `Projects::Readiness::Bootstrap`, `Projects::AgentRunsController`,
  `Tools::TriggerReadinessBootstrap`, `AgentRun`, `Inbox::Queue`,
  `dashboard/_inbox_detail_project_setup_pending`,
  `Activities::MarkAgentRunFailedActivity`, `RetryFailedManualRunJob`,
  `Issues::UpsertFromGithub`.
  *Test:* `spec/requests/agent_runs_spec.rb`,
  `spec/mcp/tools/trigger_readiness_bootstrap_spec.rb`,
  `spec/requests/inbox_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/jobs/retry_failed_manual_run_job_spec.rb`,
  `spec/services/issues/upsert_from_github_spec.rb`.

- [x] **PROJECT-READINESS-008** — When `bootstrap_readiness` creates or
  reuses a pull request, the system SHALL allow only CI configuration,
  scaffold/project manifests, conventional test-directory layout, and tool
  configuration files. When current, checkout-backed missing-test-command
  evidence selects a detector's declared setup contract, it SHALL additionally
  allow only that detector's exact repository-owned test/setup entry points;
  for Godot/gdUnit4, those are the paired `bin/install-test-tools` and
  `bin/test` paths. It SHALL reject arbitrary `bin/` paths, application files,
  and non-canonical or traversal paths. Every selected entry point SHALL be
  present as a regular file at the run's result commit. It SHALL resolve a
  selected path missing from a truncated recursive Git tree through exact
  non-recursive tree traversal, and SHALL not treat an incomplete listing as
  proof that the entry point was deleted. Deleted entry points and entry points
  replaced by symlinks or directories SHALL be rejected as guard violations,
  not surfaced as raw GitHub API failures. It SHALL abort
  changes outside that harness class with the offending file names and an
  actionable reason in the system log. Entry-script contents remain
  behavior-bearing code: they receive the ordinary isolated execution and
  pull-request review and are not accepted merely because of their filename.
  It SHALL preserve every `Tdd::WriteGuard` phase semantic unchanged.
  *Code:* `Projects::Readiness::BootstrapWriteGuard`,
  `Activities::CreatePullRequestActivity`, `GithubClient#file_modes`.
  *Test:* `spec/services/projects/readiness/bootstrap_write_guard_spec.rb`,
  `spec/temporal/activities/create_pull_request_activity_spec.rb`,
  `spec/services/github_client_spec.rb`.

- [x] **PROJECT-READINESS-009** — When a strict Godot/GDScript project moves
  from missing harness prerequisites through an explicitly started
  `bootstrap_readiness` run and GitHub-confirmed bootstrap merge, the system
  SHALL replace its pending readiness snapshot with target-branch evidence and
  remove its `project_setup_pending` Inbox entry. The bootstrap diff SHALL
  remain within its harness boundary; the following `test_writing` draft MAY
  change only tests and SHALL be able to report the intentionally red gdUnit4
  command result.
  *Code:* `Projects::Readiness::Record`, `Inbox::Queue`,
  `Projects::AgentRunsController`, `Issues::UpsertFromGithub`,
  `Projects::Readiness::BootstrapWriteGuard`, `Tdd::WriteGuard`.
  *Test:* `spec/requests/godot_gdunit4_readiness_lifecycle_spec.rb`,
  `bin/validate-godot-gdunit4-readiness`.

- [x] **PROJECT-READINESS-010** — When an operator uses the bootstrap,
  project-settings, or failed-run-details action from a `project_setup_pending`
  Inbox detail, the action SHALL navigate the top-level page rather than the
  `inbox-detail` Turbo Frame.
  *Code:* `dashboard/_inbox_detail_project_setup_pending`.
  *Test:* `spec/requests/inbox_spec.rb`.

- [x] **PROJECT-READINESS-011** — When interactive verification is enabled,
  the system SHALL report checkout-backed setup gaps for invalid verification
  configuration, an unavailable applicable start command, and configured
  services absent from the project. It SHALL add no verification gap when the
  capability is disabled. Browser connectivity and transient service health
  SHALL remain run-scoped observations, never durable repository gaps.
  *Code:* `Projects::Readiness::Rules::Verification`,
  `AgentRuns::VerificationResultRecorder`.
  *Test:* `spec/models/project_spec.rb`, `spec/services/projects/readiness_spec.rb`,
  `spec/services/agent_runs/verification_result_recorder_spec.rb`.

- [x] **PROJECT-READINESS-012** — When verification setup fails at runtime,
  the system SHALL retain its reason, agent run, checkout revision, and
  observed time and show the newest such observation — ordered by that recorded
  observation time rather than the run's creation time — alongside the related
  actionable setup gap. A merged authorized bootstrap PR SHALL clear
  configuration-derived gaps only after target-branch re-evaluation; it SHALL
  not trigger automatic bootstrap or retry.
  *Code:* `AgentRuns::VerificationResultRecorder`,
  `Inbox::LatestVerificationSetupObservation`, `Inbox::Queue`,
  `dashboard/_inbox_detail_project_setup_pending`.
  *Test:* `spec/services/agent_runs/verification_result_recorder_spec.rb`,
  `spec/services/inbox/latest_verification_setup_observation_spec.rb`,
  `spec/services/inbox/queue_spec.rb`, `spec/services/projects/readiness/record_spec.rb`.
