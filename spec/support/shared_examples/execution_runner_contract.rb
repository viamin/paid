# frozen_string_literal: true

# Shared examples verifying that a concrete ExecutionRunners::Base
# implementation satisfies the runner contract defined in RDR-054.
#
# Consumed by issue #3346 (concrete runner implementation). Stubbed here so
# the contract is captured alongside the interface definition.
#
# Expected `let` bindings:
#
#   runner        — an instance of the concrete runner class
#   run_spec      — a fully populated ExecutionRunners::RunSpec the runner can provision
#   backend       — the backend/runner descriptor passed to .compatible?
#   valid_handle  — a RunnerHandle the runner accepts for start/running?/cancel/cleanup
#
# Class-level checks go through +runner.class+ rather than +described_class+ so
# a host group can also bind a runner that is not the group's described class
# (e.g. the RDR-055 reference implementation in
# spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb).
#
# The runner's underlying execution platform should be stubbed so no real
# containers/workloads are launched.
RSpec.shared_examples "an ExecutionRunner implementation" do
  describe "lifecycle" do
    it "provisions a RunSpec and returns a RunnerHandle" do
      result = runner.provision(spec: run_spec)

      expect(result).to be_a(ExecutionRunners::RunnerHandle)
    end

    it "starts a workload and returns an ExecutionResult" do
      result = runner.start(handle: valid_handle, command: "echo ok", timeout: 60,
                            startup_timeout: 30, idle_timeout: 30,
                            abort_patterns: nil, preparation: nil, heartbeat_path: nil)

      expect(result).to be_a(ExecutionRunners::ExecutionResult)
    end

    it "streams stdout/stderr chunks through the block" do
      chunks = []
      runner.start(handle: valid_handle, command: "echo ok", timeout: 60,
                   startup_timeout: 30, idle_timeout: 30,
                   abort_patterns: nil, preparation: nil, heartbeat_path: nil) do |stream_type, chunk|
        chunks << [ stream_type, chunk ]
      end

      expect(chunks).to be_an(Array)
    end

    it "reports whether the workload is running" do
      expect(runner.running?(handle: valid_handle)).to be_in([ true, false ])
    end

    it "cancels an in-flight workload without raising" do
      expect { runner.cancel(handle: valid_handle) }.not_to raise_error
    end

    it "cleans up all resources without raising" do
      expect { runner.cleanup(handle: valid_handle, force: true) }.not_to raise_error
    end
  end

  describe "class-level checks" do
    it "returns a compatibility result from .compatible?" do
      result = runner.class.compatible?(spec: run_spec, backend: backend)

      expect(result).to respond_to(:compatible)
      expect(result).to respond_to(:error_message)
    end

    it "returns a boolean from .ping" do
      expect(runner.class.ping).to be_in([ true, false ])
    end
  end
end

# Conformance assertions for RDR-055: a runner that satisfies the contract must
# be able to run a create-PR workload — provision, execute, capture output,
# report the outcome, recover from the persisted handle, and tear down — against
# a backend that does NOT expose host paths. These examples fail if a runner
# implementation needs shared host storage to satisfy the contract.
#
# @spec CONTAINER-RUNTIME-007
# @spec CONTAINER-RUNTIME-008
# @spec CONTAINER-RUNTIME-011
#
# Expected +let+ bindings mirror "an ExecutionRunner implementation" above, with
# two additional requirements the "conformance harness" group asserts rather
# than assumes (a mis-wired harness would otherwise pass without proving
# anything):
#
#   backend  — MUST report +supports_host_paths?+ as false
#   run_spec — MUST carry a workspace strategy that needs no host path
#
# Whether such a backend accepts a spec at all is the platform's decision, not
# the contract's, so +.compatible?+ is asserted per runner instead of here.
#
# The runner's underlying execution platform should be stubbed so no real
# containers/workloads are launched.
RSpec.shared_examples "a no-shared-filesystem runner" do
  describe "conformance harness" do
    it "targets a backend that does not expose host paths" do
      expect(backend.supports_host_paths?).to be(false)
    end

    it "provisions from a spec whose workspace needs no host path" do
      expect(run_spec.workspace.bind_mount?).to be(false)
    end
  end

  describe "provision" do
    it "returns a handle whose workspace reference is runner-owned, not a host path" do
      handle = runner.provision(spec: run_spec)

      expect(handle).to be_a(ExecutionRunners::RunnerHandle)
      expect(handle.workspace_ref).to be_present
      expect(handle.workspace_ref).not_to start_with("/")
    end
  end

  # A runner without a shared filesystem cannot rediscover anything from a host
  # disk, so every lifecycle call must work from the persisted handle alone.
  describe "lifecycle from the persisted handle" do
    let(:recovered_handle) { ExecutionRunners::RunnerHandle.from_json(valid_handle.to_json) }

    it "round-trips the handle through JSON without losing the workspace reference" do
      expect(recovered_handle).to eq(valid_handle)
    end

    it "reports the workload output and outcome on the result rather than a host file" do
      result = runner.start(handle: recovered_handle, command: "echo ok", timeout: 60,
                            startup_timeout: 30, idle_timeout: 30,
                            abort_patterns: nil, preparation: nil, heartbeat_path: nil)

      expect(result).to be_a(ExecutionRunners::ExecutionResult)
      expect(result).to be_success
      expect(result.exit_code).to eq(0)
      expect(result.stdout).to be_present
      expect(result.oom_killed).to be(false)
    end

    it "answers liveness from the recovered handle" do
      expect(runner.running?(handle: recovered_handle)).to be_in([ true, false ])
    end

    it "cancels an in-flight workload from the recovered handle" do
      expect { runner.cancel(handle: recovered_handle) }.not_to raise_error
    end

    it "tears down idempotently from the recovered handle, with no host worktree path" do
      runner.cleanup(handle: recovered_handle, force: true)

      expect { runner.cleanup(handle: recovered_handle, force: true) }.not_to raise_error
    end
  end
end
