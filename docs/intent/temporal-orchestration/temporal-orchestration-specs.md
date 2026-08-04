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

- [D] **TEMPORAL-ORCHESTRATION-004** — When deployment requirements justify a
  hosted Temporal topology, the orchestration layer SHALL update this segment to
  describe the shipped operational model and its verification evidence.
