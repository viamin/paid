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

    it "returns an ExecutionStatus from #status" do
      status = runner.status(handle: valid_handle)

      expect(status).to be_a(ExecutionRunners::ExecutionStatus)
      expect(status.state).to be_in(%i[running exited oom_killed not_found error])
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
      result = described_class.compatible?(spec: run_spec, backend: backend)

      expect(result).to respond_to(:compatible)
      expect(result).to respond_to(:error_message)
    end

    it "returns a boolean from .ping" do
      expect(described_class.ping).to be_in([ true, false ])
    end
  end
end
