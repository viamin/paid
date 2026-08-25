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

    it "cancels an in-flight workload without raising" do
      expect { runner.cancel(handle: valid_handle) }.not_to raise_error
    end

    it "cleans up all resources without raising" do
      expect { runner.cleanup(handle: valid_handle, force: true) }.not_to raise_error
    end
  end

  # @spec CONTAINER-RUNTIME-025
  # @spec CONTAINER-RUNTIME-026
  describe "provisioning ledger and ownership tags (RDR-060)" do
    before do
      skip "runner does not identify a resource kind" unless runner.respond_to?(:resource_kind) && runner.resource_kind.present?
    end

    it "records a provisioning-intent ledger row before provisioning" do
      expect { runner.provision(spec: run_spec) }.to change(ProvisioningIntent, :count).by_at_least(1)
    end

    it "links the provisioned resource and runner handle back to the ledger row" do
      handle = runner.provision(spec: run_spec)

      intent = ProvisioningIntent.order(:id).last
      expect(intent.provider_resource_id).to eq(handle.identifier)
      expect(intent.runner_handle).to be_present
      expect(intent.status).to eq("linked")
    end

    it "applies the stable Paid ownership tags to the ledger row" do
      runner.provision(spec: run_spec)

      intent = ProvisioningIntent.order(:id).last
      expected_tag_names = ExecutionRunners::REQUIRED_OWNERSHIP_TAG_NAMES.map { |name| "paid.#{name}" }

      expect(intent.ownership_tags).to include(*expected_tag_names)
    end

    it "declares whether it can tag and list resources" do
      expect(runner.supports_tagging?).to be_in([ true, false ])
      expect(runner.supports_listing?).to be_in([ true, false ])
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

# Shared contract for concrete execution runners. The expectations stay at the
# provider-neutral boundary; runner-specific stubbing lives in the including
# spec so a future non-Docker runner can satisfy the same suite with its own
# setup.
#
# Expected `let` bindings:
#
#   runner                 — concrete runner instance
#   run_spec               — restricted-mode RunSpec
#   unrestricted_run_spec  — unrestricted-mode RunSpec
#   backend                — backend/runner descriptor for .compatible?
#   valid_handle           — persisted handle for lifecycle calls
#   missing_handle         — handle whose underlying workload is gone
#   agent_run              — AgentRun associated with the specs
#
# Optional `let` bindings:
#
#   services_network — network identifier used for service provisioning
RSpec.shared_examples "an execution runner contract" do
  let(:services_network) { "paid_agent" }
  let(:restricted_firewall_expectation) { nil }
  let(:expects_unrestricted_firewall_rules) { false }
  let(:contract_abort_patterns) { [ "quota exceeded" ] }
  let(:aborting_contract_command) { "emit quota warning" }
  let(:expected_abort_output) { contract_abort_patterns.first }
  let(:missing_handle) do
    valid_handle.with(identifier: "#{valid_handle.identifier}-missing")
  end

  def start_contract_run(handle:, command: "echo ok", **overrides, &block)
    runner.start(
      handle: handle,
      command: command,
      timeout: 60,
      startup_timeout: 30,
      idle_timeout: 30,
      abort_patterns: nil,
      preparation: nil,
      heartbeat_path: nil,
      **overrides,
      &block
    )
  end

  describe "#provision" do
    it "returns a RunnerHandle with an identifier" do
      handle = runner.provision(spec: run_spec)

      expect(handle).to be_a(ExecutionRunners::RunnerHandle)
      expect(handle.identifier).to be_present
      expect(handle.host).to be_present
    end
  end

  describe "#start" do
    it "streams stdout via the block" do
      chunks = []

      start_contract_run(handle: valid_handle) do |stream_type, chunk|
        chunks << [ stream_type, chunk ]
      end

      expect(chunks).to include([ :stdout, a_string_including("ok") ])
    end

    it "returns an ExecutionResult with an exit code" do
      result = start_contract_run(handle: valid_handle)

      expect(result).to be_a(ExecutionRunners::ExecutionResult)
      expect(result.exit_code).to eq(0)
    end

    it "classifies startup timeout" do
      expect do
        start_contract_run(handle: valid_handle, command: "startup timeout")
      end.to raise_error(ExecutionRunners::StartupTimeoutError)
    end

    it "classifies idle timeout" do
      expect do
        start_contract_run(handle: valid_handle, command: "idle timeout")
      end.to raise_error(ExecutionRunners::IdleTimeoutError)
    end

    it "classifies wall-clock timeout" do
      expect do
        start_contract_run(handle: valid_handle, command: "wall timeout")
      end.to raise_error(ExecutionRunners::TimeoutError)
    end

    it "detects OOM kills" do
      result = start_contract_run(handle: valid_handle, command: "oom failure")

      expect(result).to be_failure
      expect(result.oom_killed).to be(true)
      expect(result.exit_code).to eq(137)
    end

    it "detects abort patterns" do
      expect do
        start_contract_run(
          handle: valid_handle,
          command: aborting_contract_command,
          abort_patterns: contract_abort_patterns
        )
      end.to raise_error(ExecutionRunners::OutputAbortError) { |error| expect(error.matched_output).to eq(expected_abort_output) }
    end
  end

  describe "#running?" do
    it "returns true when the workload is active" do
      expect(runner.running?(handle: valid_handle)).to be(true)
    end

    it "returns false after completion or when the workload is missing" do
      expect(runner.running?(handle: missing_handle)).to be(false)
    end
  end

  describe "#cancel" do
    it "stops the workload without raising" do
      expect { runner.cancel(handle: valid_handle) }.not_to raise_error
    end
  end

  describe "#cleanup" do
    it "removes resources for the handle" do
      expect { runner.cleanup(handle: valid_handle, force: true) }.not_to raise_error
    end

    it "is safe to call multiple times" do
      expect { runner.cleanup(handle: missing_handle, force: false) }.not_to raise_error
      expect { runner.cleanup(handle: missing_handle, force: false) }.not_to raise_error
    end
  end

  describe "#reconnect" do
    it "recovers from a persisted handle" do
      expect(runner.reconnect(handle: valid_handle)).to be_present
    end

    it "handles dead or missing workloads through the lifecycle methods" do
      expect(runner.running?(handle: missing_handle)).to be(false)
      expect { runner.cleanup(handle: missing_handle, force: true) }.not_to raise_error
    end
  end

  describe "networking" do
    it "applies restricted-mode behavior" do
      handle = runner.provision(spec: run_spec)

      expect(handle).to be_a(ExecutionRunners::RunnerHandle)
      next unless restricted_firewall_expectation

      expect(NetworkPolicy).to have_received(:apply_firewall_rules).with(
        restricted_firewall_expectation.fetch(:container),
        github_ips: restricted_firewall_expectation.fetch(:github_ips),
        proxy_host: restricted_firewall_expectation.fetch(:proxy_host),
        service_destinations: restricted_firewall_expectation.fetch(:service_destinations),
        backend: restricted_firewall_expectation.fetch(:backend)
      )
    end

    it "allows direct outbound behavior when unrestricted" do
      handle = runner.provision(spec: unrestricted_run_spec)

      expect(handle).to be_a(ExecutionRunners::RunnerHandle)
      if expects_unrestricted_firewall_rules
        expect(NetworkPolicy).to have_received(:apply_firewall_rules)
      else
        expect(NetworkPolicy).not_to have_received(:apply_firewall_rules)
      end
    end
  end

  describe "workspace" do
    it "provisions a workspace reference on the handle" do
      handle = runner.provision(spec: run_spec)

      expect(handle.workspace_ref).to be_present
    end

    it "cleans up the workspace as part of cleanup" do
      expect { runner.cleanup(handle: valid_handle, force: true) }.not_to raise_error
    end
  end

  describe "services" do
    it "provisions declared services" do
      env = runner.provision_services(agent_run: agent_run, network: services_network)

      expect(env).to be_a(Hash)
    end

    it "provides service environment variables" do
      env = runner.provision_services(agent_run: agent_run, network: services_network)

      expect(env.keys).to all(be_a(String))
    end

    it "cleans up services" do
      expect { runner.cleanup_services(agent_run: agent_run, stale_requeue_count: 0) }.not_to raise_error
    end
  end
end
