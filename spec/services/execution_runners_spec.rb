# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-007
# @spec CONTAINER-RUNTIME-008
# @spec CONTAINER-RUNTIME-009
# @spec CONTAINER-RUNTIME-010
RSpec.describe ExecutionRunners do
  describe ".resolve" do
    it "returns a LocalDockerRunner for the current Docker-only backends" do
      backend = instance_double(Containers::Backends::Base, identifier: "local")

      runner = described_class.resolve(backend: backend)

      expect(runner).to be_a(ExecutionRunners::LocalDockerRunner)
    end
  end

  describe ExecutionRunners::ComputeRequirements do
    it "is an immutable Data object with cpu, memory, and pids fields" do
      requirements = described_class.new(cpu_quota: 200_000, memory_bytes: 4 * 1024 ** 3, pids_limit: 500)

      expect(requirements.cpu_quota).to eq(200_000)
      expect(requirements.memory_bytes).to eq(4_294_967_296)
      expect(requirements.pids_limit).to eq(500)
    end
  end

  describe ExecutionRunners::RunSpec do
    subject(:spec) { described_class.new(**spec_args) }

    let(:spec_args) do
      {
        agent_run: instance_double(AgentRun),
        project: instance_double(Project),
        image: "paid/agent:latest",
        command: "claude code",
        resources: ExecutionRunners::ComputeRequirements.new(cpu_quota: 1, memory_bytes: 2, pids_limit: 3),
        environment: { "FOO" => "bar" },
        networking_policy: ExecutionRunners::NetworkingPolicy.new(mode: :proxy, firewall: true),
        workspace_strategy: :named_volume,
        services: [ ExecutionRunners::ServiceDeclaration.new(name: "postgres", image: "pg", port: 5432, env: {}, type: :database) ],
        secrets_config: { "auth" => "proxy" },
        preview_tunnel: nil
      }
    end

    it "carries the full execution description" do
      expect(spec.image).to eq("paid/agent:latest")
      expect(spec.workspace_strategy).to eq(:named_volume)
    end

    it "never references Docker-specific concepts" do
      expect(described_class.members).not_to include(:container_id, :network_name, :bind_mount)
    end

    it "embeds the resource, networking, and service declarations" do
      expect(spec.resources).to be_a(ExecutionRunners::ComputeRequirements)
      expect(spec.networking_policy).to be_a(ExecutionRunners::NetworkingPolicy)
      expect(spec.services.first).to be_a(ExecutionRunners::ServiceDeclaration)
    end
  end

  describe ExecutionRunners::RunnerHandle do
    let(:handle) do
      described_class.new(
        runner_type: :local_docker,
        identifier: "abc123",
        host: "local",
        workspace_ref: "paid-workspace-1",
        metadata: { "pool_entry_id" => 42 }
      )
    end

    it "exposes opaque, provider-neutral fields" do
      expect(handle.runner_type).to eq(:local_docker)
      expect(handle.identifier).to eq("abc123")
      expect(handle.host).to eq("local")
      expect(handle.workspace_ref).to eq("paid-workspace-1")
      expect(handle.metadata).to eq({ "pool_entry_id" => 42 })
    end

    it "is JSON-serializable" do
      expect(JSON.parse(handle.to_json)).to eq(
        "runner_type" => "local_docker",
        "identifier" => "abc123",
        "host" => "local",
        "workspace_ref" => "paid-workspace-1",
        "metadata" => { "pool_entry_id" => 42 }
      )
    end

    it "round-trips through to_json / from_json losslessly" do
      restored = described_class.from_json(handle.to_json)

      expect(restored).to eq(handle)
      expect(restored.runner_type).to eq(:local_docker)
    end

    it "reconstructs from a string-keyed hash" do
      restored = described_class.from_json("runner_type" => "fly_machine", "identifier" => "m1",
                                           "host" => "fly", "workspace_ref" => "vol")

      expect(restored.runner_type).to eq(:fly_machine)
      expect(restored.metadata).to eq({})
    end
  end

  describe ExecutionRunners::NetworkingPolicy do
    it "treats proxy mode as restricted" do
      policy = described_class.new(mode: :proxy, firewall: true)

      expect(policy).to be_restricted
      expect(policy).to be_firewall
    end

    it "treats subscription_auth mode as unrestricted" do
      policy = described_class.new(mode: :subscription_auth, firewall: false)

      expect(policy).not_to be_restricted
      expect(policy).not_to be_firewall
    end

    it "treats direct_outbound mode as unrestricted" do
      policy = described_class.new(mode: :direct_outbound, firewall: false)

      expect(policy).not_to be_restricted
    end
  end

  describe ExecutionRunners::ServiceDeclaration do
    it "carries name, image, port, env, and type" do
      service = described_class.new(name: "redis", image: "redis:7", port: 6379, env: {}, type: :cache)

      expect(service.name).to eq("redis")
      expect(service.type).to eq(:cache)
    end
  end

  describe ExecutionRunners::ExecutionResult do
    describe ".success" do
      it "builds a successful result with a zero exit code" do
        result = described_class.success(stdout: "ok", exit_code: 0)

        expect(result).to be_success
        expect(result).not_to be_failure
        expect(result.exit_code).to eq(0)
        expect(result.oom_killed).to be(false)
      end
    end

    describe ".failure" do
      it "builds a failed result carrying OOM diagnostics" do
        result = described_class.failure(exit_code: 137, stdout: "", stderr: "killed",
                                         oom_killed: true, memory_limit_bytes: 1024, environment_running: false)

        expect(result).to be_failure
        expect(result.exit_code).to eq(137)
        expect(result.oom_killed).to be(true)
        expect(result.memory_limit_bytes).to eq(1024)
        expect(result.environment_running).to be(false)
      end
    end
  end

  describe ExecutionRunners::CompatibilityResult do
    it "carries compatible and error_message fields" do
      result = described_class.new(compatible: false, error_message: "no matching host path")

      expect(result.compatible).to be(false)
      expect(result.error_message).to eq("no matching host path")
    end
  end

  describe "error hierarchy" do
    it "nests timeout and abort errors under the base error" do
      expect(ExecutionRunners::StartupTimeoutError).to be < ExecutionRunners::TimeoutError
      expect(ExecutionRunners::IdleTimeoutError).to be < ExecutionRunners::TimeoutError
      expect(ExecutionRunners::TimeoutError).to be < ExecutionRunners::Error
      expect(ExecutionRunners::ProvisionError).to be < ExecutionRunners::Error
      expect(ExecutionRunners::ExecutionError).to be < ExecutionRunners::Error
      expect(ExecutionRunners::OutputAbortError).to be < ExecutionRunners::Error
    end

    it "carries exit code and output on ExecutionError" do
      error = ExecutionRunners::ExecutionError.new("boom", exit_code: 1, stdout: "o", stderr: "e")

      expect(error.exit_code).to eq(1)
      expect(error.stdout).to eq("o")
      expect(error.stderr).to eq("e")
    end

    it "carries diagnostics on TimeoutError" do
      error = ExecutionRunners::TimeoutError.new(diagnostics: { "elapsed" => 60 })

      expect(error.diagnostics).to eq({ "elapsed" => 60 })
    end

    it "carries matched output, source, and detail on OutputAbortError" do
      error = ExecutionRunners::OutputAbortError.new(matched_output: "limit reached", source: "streaming_event", detail: "turn.failed")

      expect(error.matched_output).to eq("limit reached")
      expect(error.source).to eq(:streaming_event)
      expect(error.detail).to eq("turn.failed")
    end
  end
end
