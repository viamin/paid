# EARS Specs: LID-Aware Agent Runs

> Testable claims for LID-aware prompt injection, planning runs, and coherence
> reporting. Status markers: `[x]` implemented · `[ ]` active gap · `[D]`
> deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r LID-RUNS-001`).

- [x] **LID-RUNS-001** — When a project declares `lid_mode`, prompt building
  SHALL append a LID-aware workflow section instructing the agent to read the
  design tree, work tests-first, add `@spec` annotations, and run the
  coherence checker before finishing.
  *Code:* `app/services/lid/inject_into_prompt.rb`.
  *Test:* `spec/services/lid/inject_into_prompt_spec.rb`.

- [x] **LID-RUNS-002** — When a user queues `start_lid` for a project without
  existing LID configuration, the system SHALL create a queued `lid_planning`
  agent run and persist the optional `plan_doc_source` so planning can weight
  authored design docs over code inference.
  *Code:* `app/controllers/projects_controller.rb`, `app/models/agent_run.rb`.
  *Test:* `spec/requests/projects_spec.rb`,
  `spec/services/prompts/build_for_lid_planning_spec.rb`.

- [x] **LID-RUNS-003** — When a LID-aware run captures a failed coherence
  report, the system SHALL persist the report on the agent run and surface the
  soft-block summary in the PR body instead of discarding it.
  *Code:* `app/services/lid/coherence_check.rb`,
  `app/temporal/activities/create_pull_request_activity.rb`.
  *Test:* `spec/services/lid/coherence_check_spec.rb`,
  `spec/temporal/activities/create_pull_request_activity_spec.rb`.

- [ ] **LID-RUNS-004** — When a Planning PR receives review feedback on
  inferred decisions, the system SHALL trigger a dedicated correction loop that
  rewrites the LID artifacts rather than relying on a generic review flow.

- [ ] **LID-RUNS-005** — When `lid_planning` uses named plan docs, the system
  SHALL enforce a stable output contract for how authored plan-doc sections map
  into HLD, LLD, and EARS artifacts.

- [x] **LID-RUNS-006** — External-agent entry points SHALL receive the same
  LID-aware prompt discipline and coherence reporting that native Paid agent
  runs already receive.
  *Code:* `app/services/interop/external_agent_lid_contract.rb`,
  `app/controllers/api/projects/external_agent_contracts_controller.rb`,
  `app/mcp/tools/get_project.rb`.
  *Tests:* `spec/requests/project_interoperability_spec.rb`,
  `spec/mcp/tools/get_project_spec.rb`.
