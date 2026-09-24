# EARS Specs: Temporal Orchestration

> Testable claims for the implemented Temporal orchestration layer. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r TEMPORAL-ORCHESTRATION-001`).

## Client and Queue Topology

- [x] **TEMPORAL-ORCHESTRATION-001** — The orchestration layer SHALL connect to
  Temporal through the official Ruby SDK and SHALL expose separate poll and
  agent task queues so polling workflows are isolated from agent-execution
  workloads.
  *Tests:* `spec/jobs/knowledge_evolution_job_spec.rb`, `spec/jobs/poll_workflow_health_check_job_spec.rb`.
  *Code:* `Paid.temporal_client`, `Paid.poll_task_queue`, `Paid.agent_task_queue`.

## Worker Resource Sizing

- [x] **TEMPORAL-ORCHESTRATION-002** — The orchestration layer SHALL derive the
  minimum database connection pool for Temporal workers from the selected worker
  mode, activity-slot counts, and heartbeat-thread overhead.
  *Tests:* `spec/lib/paid/temporal_worker_config_spec.rb`.
  *Code:* `Paid::TemporalWorkerConfig`.

## Durable Workflow Boundary

- [x] **TEMPORAL-ORCHESTRATION-003** — Durable multi-step automation SHALL run
  as Temporal workflows and activities under `app/temporal`, while lightweight
  recurring maintenance work remains in GoodJob.
  *Tests:* `spec/temporal/workflows/agent_execution_workflow_spec.rb`, `spec/config/good_job_configuration_spec.rb`.
  *Code:* `app/temporal/workflows/agent_execution_workflow.rb`, `config/initializers/good_job.rb`.

- [x] **TEMPORAL-ORCHESTRATION-005** — When the queue admits an agent
  execution workflow, the system SHALL mark the agent run `running` so
  provisioning/setup/preflight work appears as active execution rather than
  queued backlog.
  *Tests:* `spec/jobs/process_run_queue_job_spec.rb`,
  `spec/temporal/activities/run_agent_activity_spec.rb`.
  *Code:* `ProcessRunQueueJob`, `Activities::RunAgentActivity`,
  `AgentRun#start!`.

- [x] **TEMPORAL-ORCHESTRATION-006** — When a paused `create_feature` run has
  a persisted clarification-round identity, stale recovery SHALL leave it
  paused regardless of its age or the current issue `paid_state`. Paused
  executions without that run-owned clarification identity SHALL retain their
  existing bounded stale-recovery behavior.
  *Tests:* `spec/jobs/stale_run_detector_job_spec.rb`.
  *Code:* `AgentRun.awaiting_human_clarification`, `StaleRunDetectorJob`.

- [x] **TEMPORAL-ORCHESTRATION-008** — When stale recovery terminalizes a
  `create_feature` run with a persisted clarification-round identity and its
  issue retains both the needs-input label and stored questions, the system
  SHALL restore the issue to `needs_input` rather than leave the answer gate
  orphaned behind `failed`.
  *Tests:* `spec/jobs/stale_run_detector_job_spec.rb`.
  *Code:* `StaleRunDetectorJob`.

- [x] **TEMPORAL-ORCHESTRATION-007** — When a `create_feature` clarification
  comment is retried after GitHub accepted it but before local needs-input
  persistence completed, the system SHALL reconcile the persisted round
  identity against issue comments and SHALL not post a duplicate. Answering a
  round SHALL clear its identity so a later sparse brief can post a new round.
  *Tests:* `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/services/clarifying_questions/clear_needs_input_spec.rb`.
  *Code:* `Activities::CreateAgentRunActivity`,
  `ClarifyingQuestions::ClearNeedsInput`.

- [x] **TEMPORAL-ORCHESTRATION-008** — When an issue has a pending
  clarification round (`needs_input` state, needs-input label, or stored
  questions), Paid SHALL reject a `create_pr` run before it can change the
  issue state. A queued `create_feature` run resumed after answers clear that
  pending data MAY transition the issue to `in_progress`.
  *Tests:* `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/services/clarifying_questions/clear_needs_input_spec.rb`.
  *Code:* `Activities::CreateAgentRunActivity`,
  `ClarifyingQuestions::ClearNeedsInput`.

- [D] **TEMPORAL-ORCHESTRATION-004** — When deployment requirements justify a
  hosted Temporal topology, the orchestration layer SHALL update this segment to
  describe the shipped operational model and its verification evidence.
