# RDR-055: No-Shared-Filesystem Runner Conformance Coverage

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-08-13
- **Status**: Implemented
- **Type**: Architecture + Testability
- **Priority**: P1
- **Related Issues**: [#3401](https://github.com/viamin/paid/issues/3401) (no-shared-filesystem runner conformance coverage), [#3428](https://github.com/viamin/paid/issues/3428) (PR shipping the conformance suite)
- **Related RDRs**: [RDR-019](RDR-019-remote-container-execution.md) (Remote Container Execution), [RDR-048](RDR-048-multi-host-docker-backend-support.md) (Multi-Host Docker Backend Support), [RDR-054](RDR-054-prompt-assembly-service.md) (Prompt Assembly Service — runs over `ExecutionRunners::Base`)
- **Related Tests**: Conformance suite driven by an in-memory reference runner, plus the local Docker runner's no-shared-FS conformance block; see `Implementation Status` for evidence.

## Implementation Status

RDR-055 is implemented as of 2026-08-13 via PR [#3428](https://github.com/viamin/paid/issues/3428). The conformance suite proves the `ExecutionRunners::Base` contract and its value objects can carry a create-PR workload on a backend whose `supports_host_paths?` is false, and holds today's Docker runner to the same bar.

| Criterion | Status | Evidence |
|-----------|--------|----------|
| `ExecutionRunners::Base` interface satisfiable on a backend whose `supports_host_paths?` is false (no `container_id`/network name/bind mount/exec in method names or parameters) | Implemented | `app/services/execution_runners/base.rb:5-141`; `spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb:28-96` (conformance harness running the contract through an in-memory reference runner) |
| `ExecutionRunners::RunnerHandle` is JSON-round-trippable and `workspace_ref` carries the runner-owned storage reference (never a host bind-mount path); the persisted handle alone is enough to observe, cancel, and tear down the environment on a backend whose `supports_host_paths?` is false | Implemented | `spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb:68-83` (handle round-trip, status, idempotent cleanup from the DB-stored handle) |
| `ExecutionRunners` value objects (`RunSpec`, `RunnerHandle`, `ExecutionResult`, `NetworkingPolicy`, `ServiceDeclaration`, `ComputeRequirements`) carry a full create-PR run on a backend whose `supports_host_paths?` is false, with output and outcome reported on `ExecutionResult` rather than through a host file | Implemented | `spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb:53-66` (workspace strategy is runner-owned, `ExecutionResult` carries stdout); shared examples in `spec/support/shared_examples/execution_runner_contract.rb:100-156` exercise the lifecycle from the JSON-recovered handle alone |
| `LocalDockerRunner` satisfies the no-shared-FS conformance contract when pointed at a backend whose `supports_host_paths?` is false, and forwards a legacy bind-mount worktree path to `Containers::Provision.compatibility_for` so the backend's rejection reaches scheduling instead of failing at provision time | Implemented | `spec/services/execution_runners/local_docker_runner_spec.rb:559-576` (forwards the legacy bind-mount path to `Containers::Provision.compatibility_for` and surfaces the rejection); `spec/services/execution_runners/local_docker_runner_spec.rb:637-662` (consumes the "a no-shared-filesystem runner" shared examples with `backend.supports_host_paths? == false`) |
| `WorkspaceStrategy` can be provisioned and cleaned up by a runner without shared host storage; a `:bind_mount` strategy is refused on such a backend rather than reaching for a host reference | Implemented | `spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb:85-95` (`provision` raises `ProvisionError` with `/shared host storage/` for a `:bind_mount` strategy); `spec/support/runners/conformance_reference_runner.rb:67-93` (the reference runner encodes the refusal as its compatibility/provision contract) |
| Shared `"a no-shared-filesystem runner"` examples encode the conformance contract so any future runner implementation can be held to the same bar | Implemented | `spec/support/shared_examples/execution_runner_contract.rb:77-156`; the conformance spec and `LocalDockerRunner` both consume them |

No acceptance gaps remain in the locked RDR-055 scope; the implementation is complete.

## Problem Statement

The `ExecutionRunners::Base` contract introduced in [RDR-054](RDR-054-prompt-assembly-service.md) is intended to be the provider-neutral seam between Paid's control plane and any execution backend — local Docker today, remote Docker, Swarm, Fly machines, Kubernetes jobs, or Cloud Run jobs tomorrow. The contract's promise is provider-neutrality: every method name and parameter must be expressible without Docker concepts, and every byte of state needed to observe, cancel, and tear down the environment must live in the persisted `RunnerHandle`.

That promise is easy to drift away from. The current `LocalDockerRunner` adapter happens to satisfy it because it was written directly against the new contract, but a future contributor adding a parameter, a metadata field, or a helper path could quietly reintroduce a host-filesystem dependency that only a same-host runner could satisfy. By the time a remote runner is built and the contract is checked end-to-end, the divergence would already be baked in across value objects, the `LocalDockerRunner`, and the schedule path that decides which backend a run lands on.

A second risk is the schedule path itself. `LocalDockerRunner.compatible?(spec:, backend:)` is called for every candidate backend during scheduling, and a workspace strategy that needs shared host storage should be rejected *before* a backend is selected, not when the runner tries to bind-mount a path that does not exist on the chosen host. Today the runner forwards a bind-mount `worktree_path` to `Containers::Provision.compatibility_for` so the platform's `supports_host_paths?` check is the gate; that gate is correct, but it was previously asserted only by the indirect effect of the rest of the suite, not by a focused example that nails the contract.

Paid needs a conformance suite that turns the no-shared-filesystem runner contract into falsifiable invariants, runnable against the contract itself (not just against the local Docker runner's current implementation), so any future regression in the contract is caught by a test driven through a reference runner that cannot satisfy the contract from a host filesystem even if it wanted to.

## Context

### Current Runner Contract

`ExecutionRunners::Base` (`app/services/execution_runners/base.rb:5`) defines the provider-neutral lifecycle:

- `provision(spec:) -> RunnerHandle`
- `start(handle:, command:, timeout:, startup_timeout:, idle_timeout:, abort_patterns:, preparation:, heartbeat_path:) -> ExecutionResult` (streams `:stdout`/`:stderr` chunks to a block)
- `running?(handle:) -> Boolean`
- `reconnect(handle:) -> runner` (for Temporal worker-restart recovery)
- `status(handle:) -> ExecutionStatus`
- `cancel(handle:) -> void`
- `cleanup(handle:, force: false) -> void`
- `.compatible?(spec:, backend:) -> CompatibilityResult`
- `.ping -> Boolean`

Watchdog logic (startup, idle, wall-clock, heartbeat, abort-pattern detection) is owned by the runner, not by callers. Value objects consolidate the parameters and results: `RunSpec`, `RunnerHandle`, `ExecutionResult`, `ExecutionStatus`, `NetworkingPolicy`, `ServiceDeclaration`, `ComputeRequirements`. `RunnerHandle` is `Data.define`-based, JSON-serializable, and persists in `agent_runs.runner_handle` for recovery after Temporal worker restart or failover.

### Current Backend Capability Model

`Containers::Backends::Base#supports_host_paths?` is the predicate that distinguishes local Docker (true) from remote Docker, Swarm, and any future non-local platform (false). Local Docker can hand a host bind mount (`/var/paid/worktrees/<id>`) to the agent container; remote Docker and Swarm cannot. The runner contract must remain satisfiable on the `false` side because remote Docker and Swarm are already running in production.

### Why This Drift Is Hard to Catch Without a Reference Runner

The `LocalDockerRunner` is implemented as a thin adapter over `Containers::Provision`. The reference runner in `spec/support/runners/conformance_reference_runner.rb` is a deliberate inversion: a minimal `ExecutionRunners::Base` subclass that has no platform to call into. Every byte of state lives in the in-memory `ConformanceReferenceEnvironment` keyed by `handle.identifier`. There is no host filesystem to fall back to, so a regression that grows a host-storage requirement fails loudly here — the runner cannot satisfy its own contract, full stop.

The Docker runner is held to the same bar via the `"a no-shared-filesystem runner"` shared examples in `spec/support/shared_examples/execution_runner_contract.rb:100-156`. The shared examples assert that `backend.supports_host_paths?` is false and `run_spec.workspace.bind_mount?` is false as preconditions, then drive the lifecycle (`provision` → `start` → `running?` → `cancel` → `cleanup`) from a JSON-recovered handle. A mis-wired harness that quietly satisfies the contract from a host disk cannot make it through these examples — there is no host disk.

## Research Findings

### Investigation Process

1. Mapped the current `ExecutionRunners::Base` contract and its value objects (`RunSpec`, `RunnerHandle`, `ExecutionResult`, `ExecutionStatus`, `NetworkingPolicy`).
2. Identified `backend.supports_host_paths?` as the load-bearing capability predicate that distinguishes local from remote backends.
3. Reviewed the `LocalDockerRunner.compatible?(spec:, backend:)` path to confirm it forwards the legacy bind-mount `worktree_path` to `Containers::Provision.compatibility_for` so the backend's rejection reaches scheduling.
4. Surveyed existing conformance-style specs (e.g., `spec/services/execution_runners/local_docker_runner_spec.rb`, `spec/services/execution_runners_spec.rb`) for the patterns a reference-runner-driven suite should reuse.

### Key Discoveries

- **`RunnerHandle` is already a complete recovery reference.** `to_json` / `from_json` round-trip losslessly (including the `runner_type` symbol), `from_record(agent_run)` reads it back from the `agent_runs.runner_handle` jsonb column, and the persisted handle alone is enough to drive `status`, `cancel`, and `cleanup`. The only thing it cannot survive on a no-shared-FS backend is a `workspace_ref` that is itself a host path — that is the regression the conformance suite must guard against.
- **`Containers::Provision.compatibility_for` is the schedule-time gate, not the provision-time gate.** `LocalDockerRunner.compatible?` calls it with the bind-mount `worktree_path`, and the platform returns the incompatibility for scheduling to record rather than provision failing at bind time. The conformance spec asserts this delegation with a focused example in `spec/services/execution_runners/local_docker_runner_spec.rb:559-576`.
- **A reference runner, not a mocked `Containers::Provision`, is the right harness.** Mocking `Containers::Provision` inside a spec that is meant to validate the runner contract still leaves the contract under-tested: the mock is a same-host mock and can satisfy accidental host-disk dependencies. A reference runner whose only state lives in a process-local hash fails loudly the moment any contract element grows a host-storage requirement.
- **The shared examples need to assert their own preconditions.** The previous version of the suite vacuously passed against any backend because the assertions were tolerant of bind-mount `WorkspaceStrategy` and a backend that exposed host paths. Asserting `backend.supports_host_paths? == false` and `run_spec.workspace.bind_mount? == false` in the harness's own `describe` block makes a mis-wired harness fail loudly instead of passing silently.

## Recommendation

Add a no-shared-filesystem runner conformance suite driven by an in-memory reference runner, and hold today's `LocalDockerRunner` to the same bar via shared examples. Make the suite a conformance harness for the contract itself, not just a smoke test for the current implementation:

1. **Reference runner in `spec/support/runners/conformance_reference_runner.rb`** — a minimal `ExecutionRunners::Base` subclass whose `provision` records an in-memory `ConformanceReferenceEnvironment`, whose `start` runs the workload to completion and emits the result on `ExecutionResult` (not a host file), whose `status` returns `:running` while the environment is live and `:not_found` once released, whose `cancel` and `cleanup` are idempotent and need nothing but the handle, and whose `.compatible?` rejects `:bind_mount` workspaces and backends that expose host paths.

2. **Conformance spec `spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb`** — drives the contract through the reference runner for a create-PR run with no worktree (`agent_run.worktree_path == nil`), asserts the spec asks for runner-owned storage (`workspace.mode == :named_volume`, `reference == nil`), that the handle's `workspace_ref` is runner-owned and never a host path, that the handle round-trips through `agent_run.runner_handle` and is enough to `status`, `cancel`, and `cleanup` the environment, and that a `:bind_mount` workspace raises `ProvisionError /shared host storage/` at `provision` rather than reaching for a host reference.

3. **Shared examples `"a no-shared-filesystem runner"` in `spec/support/shared_examples/execution_runner_contract.rb:100-156`** — encode the conformance contract so any future runner implementation can consume them. Assert the harness's two preconditions (`backend.supports_host_paths? == false` and `run_spec.workspace.bind_mount? == false`), then exercise the lifecycle from a JSON-recovered handle: handle round-trip, `ExecutionResult` carries stdout/exit code/OOM flag, `running?`, idempotent `cancel` and `cleanup`.

4. **`LocalDockerRunner` no-shared-FS conformance block in `spec/services/execution_runners/local_docker_runner_spec.rb:637-662`** — `it_behaves_like "a no-shared-filesystem runner"` with `backend.supports_host_paths? == false`, so a regression in the local runner's no-shared-FS behavior fails there too. The block stubs `Containers::Provision` and `backend.stop_container` so no real containers are launched; the same `backend` is used both for the runner's resolution through `Containers.backend_for` and for the shared-example assertions.

5. **Schedule-time bind-mount rejection in `spec/services/execution_runners/local_docker_runner_spec.rb:559-576`** — a focused example that constructs a `bind_mount` `WorkspaceStrategy`, stubs `Containers::Provision.compatibility_for` to return a `compatible: false` result carrying the bind-mount path, and asserts `LocalDockerRunner.compatible?` surfaces that rejection rather than silently letting the run reach provision time.

6. **EARS spec updates in `docs/intent/container-runtime/container-runtime-specs.md:59-141`** — extend CONTAINER-RUNTIME-007/008/009/010/011 to cite the no-shared-FS conformance requirement and the new conformance spec, so the test files and the intent are linked through `@spec CONTAINER-RUNTIME-NNN` annotations.

## Alternatives Considered

- **Add `supports_host_paths?` checks inline in the runner's `provision` and let the existing local-Docker spec catch regressions.** Rejected because the runner contract is supposed to be provider-neutral; encoding backend capability checks inside `provision` would re-couple the contract to a Docker concept. The conformance suite puts the check on `compatible?` (where scheduling lives) and on the value object shape, not on `provision`.
- **Mock `Containers::Provision` inside the conformance spec instead of using a reference runner.** Rejected because a same-host mock can satisfy accidental host-disk dependencies, defeating the purpose of a no-shared-FS conformance suite. The reference runner has no host disk to fall back to; the contract is the only surface it can use.
- **Drive the conformance suite through `instance_double(ExecutionRunners::Base)`.** Rejected because an `instance_double` mocks the contract, it does not satisfy it. The contract must be concretely implemented by the runner under test; a reference runner that subclasses `ExecutionRunners::Base` proves the contract is satisfiable, not just describable.
- **Split the no-shared-FS assertions into per-method examples.** Rejected because the conformance invariant is the *whole lifecycle*: provision → start → recovery → cancel → cleanup, all from the persisted handle alone. Splitting per-method would let a regression that grows a host-storage requirement on one path pass by exercising another.

## Trade-offs

- **Positive:** The conformance suite is a falsifiable harness for the contract itself. A future contributor who adds a parameter, metadata field, or helper path that grows a host-storage requirement fails the suite through the reference runner and through `LocalDockerRunner`'s no-shared-FS block, not through an indirect downstream symptom.
- **Positive:** The shared examples are reusable for any future remote runner (Fly machine, Kubernetes job, Cloud Run job). Adopting the runner contract becomes a mechanical step: implement `Base`, consume `"a no-shared-filesystem runner"`, and the conformance suite runs against the new implementation automatically.
- **Positive:** The schedule-time bind-mount assertion makes the gate visible at the spec layer; a regression that re-introduces bind-mount execution without the platform's compatibility gate fails the example rather than the production run.
- **Negative:** The reference runner adds a small spec-support surface area. The harness is intentionally minimal (no platform, no real timers, no real containers) and its purpose is documented inline, so the maintenance cost is bounded.
- **Negative:** The conformance spec asserts `backend.supports_host_paths? == false` and `run_spec.workspace.bind_mount? == false` as preconditions. A host that wants to test the runner on a local-Docker backend must consume the separate `"an ExecutionRunner implementation"` shared examples (which already existed in RDR-054); the two shared examples are intentionally non-overlapping.

## Implementation Plan

1. Create `spec/support/runners/conformance_reference_runner.rb` with `ConformanceReferenceEnvironment` (a state-machine-shaped value object) and `ConformanceReferenceRunner` (a minimal `ExecutionRunners::Base` subclass). The runner raises `ProvisionError` on `:bind_mount` workspaces; `.compatible?` rejects both bind-mount workspaces and backends that expose host paths.
2. Create `spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb` to drive the contract through the reference runner for a create-PR run with no worktree. Cover: handle shape, JSON round-trip, lifecycle from the JSON-recovered handle, and bind-mount rejection at provision time.
3. Extend `spec/support/shared_examples/execution_runner_contract.rb` with the `"a no-shared-filesystem runner"` shared examples. Assert the harness's preconditions (`backend.supports_host_paths? == false`, `run_spec.workspace.bind_mount? == false`), then drive the lifecycle from a JSON-recovered handle. Tag the shared examples with `@spec CONTAINER-RUNTIME-007 / 008 / 011`.
4. Add the `it_behaves_like "a no-shared-filesystem runner"` block to `spec/services/execution_runners/local_docker_runner_spec.rb`, overriding `backend` to report `supports_host_paths? == false` so the runner resolves through `Containers.backend_for` to the same backend the conformance examples assert on. Tag the spec with `@spec CONTAINER-RUNTIME-007 / 008 / 011`.
5. Add the focused `LocalDockerRunner.compatible?` example that forwards a legacy bind-mount `worktree_path` to `Containers::Provision.compatibility_for` and surfaces the rejection at schedule time. Tag with `@spec CONTAINER-RUNTIME-010`.
6. Update `docs/intent/container-runtime/container-runtime-specs.md` to cite the new conformance spec under CONTAINER-RUNTIME-007/008/009/010/011 and add `@spec` annotations to the conformance spec, shared examples, and Docker runner spec so the tests trace back to the EARS claims.
7. Run `bin/lint -a` and `bundle exec rspec spec/services/execution_runners/` to confirm the suite is green.

## Validation

- `bundle exec rspec spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb` — the conformance suite passes against the reference runner.
- `bundle exec rspec spec/services/execution_runners/local_docker_runner_spec.rb` — `LocalDockerRunner` satisfies the shared examples on a `supports_host_paths? == false` backend.
- `bundle exec rspec spec/services/execution_runners_spec.rb` — value objects round-trip through `RunnerHandle` JSON serialization, and `from_record` reads the handle back from `agent_runs.runner_handle`.
- `bundle exec rspec spec/support/shared_examples/execution_runner_contract.rb` — both shared-example groups (`"an ExecutionRunner implementation"` and `"a no-shared-filesystem runner"`) exercise their respective preconditions and lifecycle assertions.
- `bin/lint -a` — RuboCop, ESLint, markdownlint, ShellCheck, and Herb pass on the touched files.

A regression that grows a host-storage requirement on the runner contract fails the reference runner's harness (because there is no host disk to use) and the Docker runner's no-shared-FS block (because the host paths are not exposed), surfacing the drift at PR review rather than at the next remote-runner implementation.
