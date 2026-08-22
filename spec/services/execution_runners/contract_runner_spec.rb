# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-028
RSpec.describe ExecutionRunners::ContractRunner do
  subject(:runner) { runner_class.new }

  let(:runner_class) { described_class.supporting(supported_modes) }
  let(:supported_modes) { described_class::DEFAULT_SUPPORTED_MODES }
  let(:agent_run) { create(:agent_run, container_host: "local") }
  let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:networking_policy) { ExecutionRunners::NetworkingPolicy.approved_services }
  let(:run_spec) do
    ExecutionRunners::RunSpec.new(
      agent_run: agent_run, project: agent_run.project, image: "paid/agent:latest", command: "claude code",
      resources: nil, environment: {},
      networking_policy: networking_policy,
      ingress_policy: ExecutionRunners::IngressPolicy.default_deny,
      workspace: ExecutionRunners::WorkspaceStrategy.named_volume, services: [], secrets_config: nil
    )
  end

  describe ".supporting" do
    it "returns a narrowed ContractRunner subclass" do
      narrowed = described_class.supporting([ :model_direct ])

      expect(narrowed).to be < described_class
      expect(narrowed.supported_modes).to eq([ :model_direct ])
      expect(narrowed.new.supported_modes).to eq([ :model_direct ])
    end

    it "raises ArgumentError for unknown modes" do
      expect { described_class.supporting([ :model_direct, :bogus ]) }
        .to raise_error(ArgumentError, /bogus/)
    end
  end

  describe ".supports_policy?" do
    it "rejects a nil policy when the runner supports no policies" do
      expect(described_class.supporting([]).supports_policy?(nil)).to be(false)
    end

    it "accepts a policy whose mode is in the supported set" do
      policy = ExecutionRunners::NetworkingPolicy.approved_services

      expect(described_class.supporting([ :approved_services ]).supports_policy?(policy)).to be(true)
    end

    it "rejects a policy whose mode is outside the supported set" do
      policy = ExecutionRunners::NetworkingPolicy.approved_services

      expect(described_class.supporting([ :model_direct ]).supports_policy?(policy)).to be(false)
    end

    it "accepts a backward-compatible alias when its canonical mode is supported" do
      policy = ExecutionRunners::NetworkingPolicy.proxy_restricted

      expect(described_class.supporting([ :approved_services ]).supports_policy?(policy)).to be(true)
    end
  end

  describe ".compatible?" do
    let(:supported_modes) { [ :model_direct ] }

    it "rejects a spec whose networking policy is outside the supported set" do
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.approved_services
      ))

      result = runner_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("approved_services")
    end

    it "accepts a spec whose networking policy is in the supported set" do
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.model_direct
      ))

      result = runner_class.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true)
      expect(result.error_message).to be_nil
    end

    # @spec EGRESS-POLICY-007
    it "accepts :no_outbound without a gateway adapter because it only uses firewall enforcement" do
      narrowed = described_class.supporting([ :no_outbound ])
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
      ))

      result = narrowed.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true)
      expect(result.error_message).to be_nil
    end

    # @spec EGRESS-POLICY-007
    it "accepts :proxy_only without a gateway adapter because it only uses firewall enforcement" do
      narrowed = described_class.supporting([ :proxy_only ])
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_only
      ))

      result = narrowed.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true)
      expect(result.error_message).to be_nil
    end

    it "rejects a nil backend" do
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.model_direct
      ))

      result = runner_class.compatible?(spec: spec, backend: nil)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("Backend is not supported")
    end

    it "rejects an unsupported spec through the standard Base signature, matching #provision" do
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.approved_services
      ))

      expect(runner_class.compatible?(spec: spec, backend: backend).compatible).to be(false)
      expect { runner.provision(spec: spec) }
        .to raise_error(ExecutionRunners::ProvisionError, /approved_services/)
    end

    # @spec EGRESS-POLICY-007
    it "rejects a restricted spec when no gateway adapter is registered" do
      narrowed = described_class.supporting([ :approved_services ])
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.approved_services
      ))

      result = narrowed.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("cannot enforce the egress policy snapshot")
    end

    # @spec EGRESS-POLICY-007
    it "rejects a restricted spec when the registered adapter is not capable on this backend" do
      narrowed = described_class.supporting([ :approved_services ])
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Kubernetes,
        capable?: false
      )
      allow(narrowed).to receive(:gateway_adapter).and_return(adapter)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.approved_services
      ))

      result = narrowed.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("cannot enforce the egress policy snapshot")
      expect(adapter).to have_received(:capable?).with(hash_including(backend: backend))
    end

    # @spec EGRESS-POLICY-007
    it "accepts a restricted spec when a capable adapter is registered" do
      narrowed = described_class.supporting([ :approved_services ])
      adapter = instance_double(
        AgentRuns::EgressPolicy::GatewayAdapters::Docker,
        capable?: true
      )
      allow(narrowed).to receive(:gateway_adapter).and_return(adapter)
      spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
        networking_policy: ExecutionRunners::NetworkingPolicy.approved_services
      ))

      result = narrowed.compatible?(spec: spec, backend: backend)

      expect(result.compatible).to be(true), result.error_message
    end
  end

  describe "#provision" do
    context "when the policy is in the supported set" do
      let(:supported_modes) { [ :approved_services ] }

      before do
        adapter = instance_double(AgentRuns::EgressPolicy::GatewayAdapters::Docker, capable?: true)
        allow(runner_class).to receive(:gateway_adapter).and_return(adapter)
      end

      it "returns a RunnerHandle" do
        handle = runner.provision(spec: run_spec)

        expect(handle).to be_a(ExecutionRunners::RunnerHandle)
        expect(handle.runner_type).to eq(:contract)
      end

      it "records the call" do
        expect { runner.provision(spec: run_spec) }
          .to change { runner.provision_calls.size }.from(0).to(1)
      end
    end

    context "when the policy is outside the supported set" do
      let(:supported_modes) { [ :model_direct ] }

      it "raises ProvisionError with a descriptive message" do
        expect { runner.provision(spec: run_spec) }
          .to raise_error(ExecutionRunners::ProvisionError, /approved_services/)
      end

      it "records the call before raising" do
        expect { runner.provision(spec: run_spec) rescue nil }
          .to change { runner.provision_calls.size }.from(0).to(1)
      end
    end

    # @spec EGRESS-POLICY-007
    context "when the policy is restricted and no gateway adapter can enforce it" do
      let(:supported_modes) { [ :approved_services ] }

      it "raises ProvisionError instead of returning a handle, mirroring .compatible?" do
        expect(runner_class.compatible?(spec: run_spec, backend: backend).compatible).to be(false)
        expect { runner.provision(spec: run_spec) }
          .to raise_error(ExecutionRunners::ProvisionError, /cannot enforce the egress policy snapshot/)
      end

      it "records the call before raising" do
        expect { runner.provision(spec: run_spec) rescue nil }
          .to change { runner.provision_calls.size }.from(0).to(1)
      end
    end

    # @spec EGRESS-POLICY-007
    context "when the policy does not route through the egress gateway" do
      let(:supported_modes) { [ :no_outbound ] }

      it "returns a handle for :no_outbound without requiring a gateway adapter" do
        spec = ExecutionRunners::RunSpec.new(**run_spec.to_h.merge(
          networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
        ))

        handle = runner.provision(spec: spec)

        expect(handle).to be_a(ExecutionRunners::RunnerHandle)
      end
    end
  end

  describe "#start" do
    let(:supported_modes) { [ :approved_services ] }
    let(:handle) { ExecutionRunners::RunnerHandle.new(runner_type: :contract, identifier: "x", host: "contract", workspace_ref: "x", metadata: {}) }

    it "returns the configured execute_result" do
      result_value = ExecutionRunners::ExecutionResult.success(stdout: "hi", exit_code: 0)
      runner = runner_class.new(execute_result: result_value)

      result = runner.start(handle: handle, command: "echo hi", timeout: 60, startup_timeout: 30,
                            idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil)

      expect(result).to eq(result_value)
    end

    it "defaults to a successful result when no execute_result is configured" do
      result = runner.start(handle: handle, command: "echo hi", timeout: 60, startup_timeout: 30,
                            idle_timeout: 30, abort_patterns: nil, preparation: nil, heartbeat_path: nil)

      expect(result).to be_success
    end
  end

  describe "#reconnect" do
    let(:handle) { ExecutionRunners::RunnerHandle.new(runner_type: :contract, identifier: "x", host: "contract", workspace_ref: "x", metadata: {}) }
    let(:supported_modes) { [ :model_direct ] }

    it "returns the runner itself and records the call" do
      expect(runner.reconnect(handle: handle)).to be(runner)
      expect(runner.reconnect_calls).to eq([ handle ])
    end
  end

  describe "#running?" do
    let(:handle) { ExecutionRunners::RunnerHandle.new(runner_type: :contract, identifier: "x", host: "contract", workspace_ref: "x", metadata: {}) }
    let(:supported_modes) { [ :model_direct ] }

    it "returns the configured running_result" do
      runner = runner_class.new(running_result: false)

      expect(runner.running?(handle: handle)).to be(false)
    end
  end

  describe "#status" do
    let(:handle) { ExecutionRunners::RunnerHandle.new(runner_type: :contract, identifier: "x", host: "contract", workspace_ref: "x", metadata: {}) }
    let(:supported_modes) { [ :model_direct ] }

    it "returns the configured status_result" do
      status = ExecutionRunners::ExecutionStatus.new(state: :exited, exit_code: 0, oom_killed: false, memory_limit: nil)
      runner = runner_class.new(status_result: status)

      expect(runner.status(handle: handle)).to eq(status)
    end
  end

  describe "#cancel and #cleanup" do
    let(:handle) { ExecutionRunners::RunnerHandle.new(runner_type: :contract, identifier: "x", host: "contract", workspace_ref: "x", metadata: {}) }
    let(:supported_modes) { [ :model_direct ] }

    it "records cancel calls without raising" do
      expect { runner.cancel(handle: handle) }.not_to raise_error
      expect(runner.cancel_calls).to eq([ handle ])
    end

    it "records cleanup calls without raising" do
      expect { runner.cleanup(handle: handle, force: true) }.not_to raise_error
      expect(runner.cleanup_calls).to eq([ { handle: handle, force: true } ])
    end
  end

  describe ".ping" do
    it "returns true" do
      expect(described_class.ping).to be(true)
    end
  end

  describe "shared runner contract" do
    let(:runner_class) { described_class }
    let(:networking_policy) { ExecutionRunners::NetworkingPolicy.model_direct }
    let(:backend) { instance_double(Containers::Backends::Base, identifier: "local") }
    let(:valid_handle) do
      ExecutionRunners::RunnerHandle.new(runner_type: :contract, identifier: "x", host: "contract",
                                         workspace_ref: "x", metadata: {})
    end

    it_behaves_like "an ExecutionRunner implementation"
  end
end
