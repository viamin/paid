---
parent: PAID
prefix: CONTAINER-RUNTIME
---

# Runner Conformance Benchmark Methodology

This document defines the production-readiness dimensions and benchmark output
that complement the shared runner contract work tracked by `#3347`. If `#3347`
absorbs this scope, this document is the acceptance target for what that shared
contract must exercise.

## Scope Split With `#3347`

- `#3347` owns the shared runner contract and executable conformance suite.
- `#3358` defines what that suite must prove for production readiness and what
  benchmark data it must emit for provider comparison.
- The work should land in one suite, not parallel suites. Add missing coverage
  to `#3347` rather than creating a second contract.

## Canonical Fixture Workload

The fixture repository lives at `spec/fixtures/execution_runners/conformance_repo/`.
It is intentionally small and deterministic:

- Entry point: `bin/conformance-task`
- Expected stdout token: `CONFORMANCE_OK`
- Expected artifact: `artifacts/conformance-result.json`
- Expected behavior: write a fixed JSON artifact and print a fixed success token
- LLM dependency: none

Use this fixture when comparing providers so the workload itself does not add
model or prompt variance to the benchmark.

The shared no-shared-filesystem example emits benchmark-shape JSON from a
Docker-stubbed baseline — `Containers::Provision` is doubled — by submitting
the real fixture workload command (clone this repository fixture, run
`bin/conformance-task`, print the artifact it wrote) through the runner's own
`#start`, and asserting the fixture token and artifact come back over the
runner's own stdout stream. Evidence is read only from that stream: host
filesystem state is never inspected, because a runner executing inside its own
environment never populates it, and executing the workload on the host instead
would assert nothing about the runner boundary. Report generation itself is
runner-owned production code
(`ExecutionRunners::ConformanceSuite::Benchmark`), not test-only bookkeeping,
so a regression there fails the suite. The stubbed baseline proves report
compatibility only: comparison-grade numbers must come from an unstubbed run
whose execution platform truly clones and executes this repository fixture.

## Required Lifecycle Dimensions

The shared contract tracked by `#3347` should map its checks to these exact
thirteen dimensions:

| Key | What the suite exercises | Primary Paid surface |
| --- | --- | --- |
| `provision_execution` | primary execution environment provision | `ProvisionContainerActivity` |
| `clone_fixture_repository` | in-environment git clone | `CloneRepoActivity` |
| `inject_configuration` | env vars, workspace setup, normal config | `ProvisionContainerActivity` |
| `provide_secrets_securely` | proxy-mode and direct-mode secret delivery | `ProvisionContainerActivity`, `RunAgentActivity` |
| `run_workload` | core runner execution path | `RunAgentActivity` |
| `provision_service_dependencies` | services, MCP servers, browser sidecar | `ProvisionServicesActivity`, `ProvisionMcpServersActivity`, `ProvisionBrowserContainerActivity` |
| `retrieve_and_stream_logs` | stdout/stderr streaming and metrics collection | `StreamingEventProcessor`, `Containers::CollectMetrics` |
| `report_success_or_failure` | exit code and output capture | `RunAgentActivity` |
| `handle_non_zero_exits` | failure classification and failure recording | `MarkAgentRunFailedActivity` |
| `enforce_timeout` | timeout enforcement | `RunAgentActivity` |
| `cancel_running_workload` | cancellation and heartbeat-aware stop | `AgentRuns::Cancel`, `RunAgentActivity` |
| `clean_up_resources` | environment, workspace, services, sidecars | `CleanupContainerActivity`, `CleanupServicesActivity`, `CleanupWorktreeActivity`, `CleanupMcpServersActivity` |
| `demonstrate_retry_and_idempotency` | retry-safe recovery across crash windows | `Activities::IdempotencyKey`, `#3352` failure-window work |

## Benchmark JSON Format

Results from different providers should be stored as one JSON object per suite
run. The schema implemented in `ExecutionRunners::ConformanceSuite::BenchmarkReport`
is `runner_conformance_benchmark.v1`.

Top-level fields:

- `schema_version`
- `generated_at`
- `fixture`
- `runner`
- `benchmark`
- `resource_usage`
- `cost`
- `dimensions`
- `result`

Example shape:

```json
{
  "schema_version": "runner_conformance_benchmark.v1",
  "generated_at": "2026-08-28T12:00:05Z",
  "fixture": {
    "name": "runner-conformance-fixture",
    "relative_repo_path": "spec/fixtures/execution_runners/conformance_repo",
    "entrypoint": "bin/conformance-task",
    "expected_stdout": "CONFORMANCE_OK",
    "expected_artifact_path": "artifacts/conformance-result.json",
    "fixture_version": 1,
    "requires_llm": false
  },
  "runner": {
    "runner_type": "local_docker_runner",
    "runner_backend": "local"
  },
  "benchmark": {
    "provisioning_latency_ms": 1000,
    "cold_start_latency_ms": 2000,
    "execution_duration_ms": 3000,
    "cleanup_latency_ms": 1000
  },
  "resource_usage": {
    "peak_cpu_percent": 55.5,
    "peak_memory_bytes": 134217728,
    "peak_disk_bytes": null,
    "requested_disk_gb": null,
    "container_metric_samples": 4
  },
  "cost": {
    "estimated_infra_cost_cents": 17,
    "billed_duration_seconds": 45
  },
  "dimensions": [
    {
      "key": "run_workload",
      "label": "Run workload",
      "status": "pass",
      "activities": ["RunAgentActivity"],
      "description": "Execute the fixture workload through the normal runner contract."
    }
  ],
  "result": {
    "success": true,
    "exit_code": 0,
    "oom_killed": false,
    "stdout_bytes": 15,
    "stderr_bytes": 0
  }
}
```

## Running The Suite

For the Docker baseline in CI or locally, run the shared no-shared-filesystem
conformance path plus the report-shape specs:

```bash
source .paid-test-env.sh
bundle exec rspec \
  spec/services/execution_runners/conformance_suite_spec.rb \
  spec/services/execution_runners/no_shared_filesystem_conformance_spec.rb \
  spec/services/execution_runners/local_docker_runner_spec.rb
```

When running against a future provider:

1. Implement the runner against `ExecutionRunners::Base`.
2. Prove the shared contract and no-shared-filesystem suite pass.
3. Capture the emitted `runner_conformance_benchmark.v1` JSON from the run that
   actually executed the comparison workload.
4. Store repeated runs for the same fixture and provider configuration.
5. Compare providers only within the same fixture revision and resource
   profile — check the `fixture.fixture_version` field on each stored report
   rather than relying on when the runs happened.

## Interpreting Results

- Treat pass/fail on the thirteen dimensions as the readiness gate.
- Treat dimensions that remain `not_exercised` as uncovered until a suite run
  proves them.
- Treat benchmark values as comparison data only after the suite passes.
- Compare cold-start and provisioning separately: they answer different
  provider questions.
- Use repeated runs, not a single sample, before drawing conclusions from
  latency or cost differences.
- Keep fixture revision, runner type, backend, requested resources, and
  environment stable across comparisons.
