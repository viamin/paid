# Orchestration Scaling Experiment Plan

Issue [#1812](https://github.com/viamin/paid/issues/1812) defines the controlled experiment design for measuring orchestration scaling behavior with fair cohort comparisons.

## Core Independent Variables

- `agent_count`: Primary scaling arm for the first rollout because Paid already records planned and launched agent counts and can safely cap batches through execution plans.
- `max_iterations`: Follow-on arm for testing refinement depth without changing decomposition shape.
- `parallelism`: Follow-on arm for testing concurrency limits independently from total task volume.
- `task_count` and `dependency_edge_count`: Required stratification variables. They are not tuned directly, but they are used to keep comparisons inside comparable workflow cohorts.

Each `ScalingExperiment` stores these variables in `independent_variables`. The experiment `dimension` marks the primary variable under test for that run, while the remaining entries describe context that must stay comparable.

## Outcome Metrics

- `success_rate`: Primary outcome metric. Optimize upward.
- `duration_seconds`: Efficiency metric. Optimize downward.
- `total_cost_cents`: Spend metric. Optimize downward.
- `agent_launch_success_rate`: Reliability metric for child-run execution. Optimize upward.
- `blocked_task_rate`: Guardrail metric for capacity or dependency starvation. Optimize downward.

These are stored in `outcome_metrics` with `primary` and `objective` metadata so summaries and later analysis can distinguish optimization targets from guardrails. The model validation also rejects unsupported or duplicate metric keys.

## Controls And Guardrails

Fair comparisons require the following control conditions:

- Compare only workflows from the same project and orchestration workflow class.
- Compare only within the same task-count bucket.
- Preserve dependency order and existing project-capacity checks.
- Exclude non-parallel runs from recorded experiment outcomes when the orchestration never actually exercised the scaling treatment.

These rules are stored in `control_definition` so the plan travels with the experiment record instead of living only in prose. Each assignment also copies the normalized control arm label and comparison method into `execution_plan["control"]` so downstream analysis can compare a treatment cohort to its proper control bucket without reconstructing the plan.

## Cohorts

Cohorts are assigned continuously at workflow start with a balanced-underfilled strategy:

- Assignment unit: `workflow_id`
- Cadence: continuous rollout while the experiment is `running`
- Labels: `%{dimension}-%{value}__%{task_bucket}`
- Default task buckets:
  - `tasks-2-3`
  - `tasks-4-6`
  - `tasks-7-plus`

The schedule and label template live in `cohort_settings`, and each assignment copies its resolved task bucket, cohort label, control cohort label, and fairness guardrails into `execution_plan`. This keeps runtime assignment, result recording, and later analysis aligned on the same normalized experiment-plan metadata.
