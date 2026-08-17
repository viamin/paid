# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-007
# @spec CONTAINER-RUNTIME-008
# @spec CONTAINER-RUNTIME-009
# @spec CONTAINER-RUNTIME-010
# @spec CONTAINER-RUNTIME-011
# @spec CONTAINER-RUNTIME-017
# @spec CONTAINER-RUNTIME-018
# @spec CONTAINER-RUNTIME-019
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

    let(:agent_run) do
      instance_double(
        AgentRun,
        id: 123,
        branch_name: "agent-run-branch",
        base_commit_sha: "deadbeef",
        source_pull_request_number: 7,
        goal: "create_pr",
        execution_origin: "paid_native",
        prompt_version_id: nil,
        custom_prompt: nil,
        issue_id: nil
      )
    end
    let(:project) do
      instance_double(Project, full_name: "acme/widgets", github_url: "https://github.com/acme/widgets")
    end
    let(:spec_args) do
      {
        agent_run: agent_run,
        project: project,
        image: "paid/agent:latest",
        command: "claude code",
        resources: ExecutionRunners::ComputeRequirements.new(cpu_quota: 1, memory_bytes: 2, pids_limit: 3),
        environment: { "FOO" => "bar" },
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted,
        workspace: ExecutionRunners::WorkspaceStrategy.named_volume,
        services: [ ExecutionRunners::ServiceDeclaration.new(name: "postgres", image: "pg", port: 5432, env: {}, type: :database) ],
        secrets_config: { "auth" => "proxy" }
      }
    end

    it "carries the full execution description" do
      expect(spec.image).to eq("paid/agent:latest")
      expect(spec.workspace).to be_a(ExecutionRunners::WorkspaceStrategy)
      expect(spec.workspace.named_volume?).to be(true)
    end

    it "never references Docker-specific concepts" do
      expect(described_class.members).not_to include(:container_id, :network_name, :bind_mount)
    end

    it "embeds the resource, networking, and service declarations" do
      expect(spec.resources).to be_a(ExecutionRunners::ComputeRequirements)
      expect(spec.networking_policy).to be_a(ExecutionRunners::NetworkingPolicy)
      expect(spec.services.first).to be_a(ExecutionRunners::ServiceDeclaration)
    end

    it "embeds a WorkspaceStrategy as the workspace contract" do
      expect(spec.workspace).to be_a(ExecutionRunners::WorkspaceStrategy)
    end

    it "builds a redacted input manifest for the runner boundary" do
      manifest = spec.input_manifest

      expect(manifest).to be_a(ExecutionRunners::ExecutionInputManifest)
      expect(manifest.repository.dig("ref", "branch_name")).to eq("agent-run-branch")
      expect(manifest.execution.dig("workspace", "mode")).to eq("named_volume")
    end
  end

  describe ExecutionRunners::WritableDir do
    it "builds a tmpfs-style writable directory spec" do
      dir = described_class.build("/tmp", size_bytes: 1024, mode: 0o1777, exec: true)

      expect(dir.path).to eq("/tmp")
      expect(dir.size_bytes).to eq(1024)
      expect(dir.exec).to be(true)
    end

    it "translates to Docker tmpfs mount options" do
      dir = described_class.build("/tmp", size_bytes: 1024, mode: 0o1777, exec: true)

      expect(dir.docker_tmpfs_options).to eq("exec,size=1024,mode=1777")
    end

    it "omits the exec flag when not requested" do
      dir = described_class.build("/data", size_bytes: 512, mode: 0o755)

      expect(dir.docker_tmpfs_options).to eq("size=512,mode=0755")
    end
  end

  describe ExecutionRunners::HeartbeatConfig do
    it "carries the heartbeat mount point" do
      config = described_class.new(mount_point: "/paid-heartbeat")

      expect(config.mount_point).to eq("/paid-heartbeat")
    end
  end

  describe ExecutionRunners::WorkspaceStrategy do
    it "builds a named_volume strategy with default mount point and writable dirs" do
      strategy = described_class.named_volume

      expect(strategy.named_volume?).to be(true)
      expect(strategy.bind_mount?).to be(false)
      expect(strategy.mode).to eq(:named_volume)
      expect(strategy.mount_point).to eq("/workspace")
      expect(strategy.reference).to be_nil
      expect(strategy.writable_dirs).to all(be_a(ExecutionRunners::WritableDir))
      expect(strategy.heartbeat).to be_a(ExecutionRunners::HeartbeatConfig)
    end

    it "builds a bind_mount strategy carrying the host-path reference" do
      strategy = described_class.bind_mount(reference: "/var/paid/worktrees/1")

      expect(strategy.bind_mount?).to be(true)
      expect(strategy.reference).to eq("/var/paid/worktrees/1")
    end

    it "builds an ephemeral strategy with no persistent reference" do
      strategy = described_class.ephemeral

      expect(strategy.mode).to eq(:ephemeral)
      expect(strategy.reference).to be_nil
    end

    it "declares the default writable directories (/tmp and ~/.cache) via the strategy" do
      paths = described_class.default_writable_dirs.map(&:path)

      expect(paths).to contain_exactly("/tmp", "/home/agent/.cache")
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

    describe ".from_record" do
      it "reconstructs a handle from a record with a persisted runner_handle" do
        record = instance_double(AgentRun, runner_handle: handle.to_storage)

        restored = described_class.from_record(record)

        expect(restored).to eq(handle)
        expect(restored.runner_type).to eq(:local_docker)
      end

      it "returns nil when the record has no stored handle" do
        record = instance_double(AgentRun, runner_handle: nil)

        expect(described_class.from_record(record)).to be_nil
      end

      it "returns nil when the stored handle is blank" do
        record = instance_double(AgentRun, runner_handle: {})

        expect(described_class.from_record(record)).to be_nil
      end
    end

    describe "#to_storage" do
      it "returns a JSON-native hash that round-trips through from_json" do
        stored = handle.to_storage

        expect(stored).to eq(
          "runner_type" => "local_docker",
          "identifier" => "abc123",
          "host" => "local",
          "workspace_ref" => "paid-workspace-1",
          "metadata" => { "pool_entry_id" => 42 }
        )
        expect(described_class.from_json(stored)).to eq(handle)
      end
    end
  end

  describe ExecutionRunners::NetworkingPolicy do
    it "treats proxy_restricted mode as restricted and firewall-required" do
      policy = described_class.proxy_restricted(allow_destinations: [ { host: "10.0.0.1", port: 5432 } ])

      expect(policy).to be_restricted
      expect(policy).to be_firewall
      expect(policy.allow_destinations).to eq([ { host: "10.0.0.1", port: 5432 } ])
      expect(policy.canonical_mode).to eq(:approved_services)
    end

    it "treats subscription_auth mode as unrestricted" do
      policy = described_class.subscription_auth

      expect(policy).not_to be_restricted
      expect(policy).not_to be_firewall
      expect(policy.allow_destinations).to eq([])
      expect(policy.canonical_mode).to eq(:model_direct)
    end

    it "treats direct_outbound mode as unrestricted" do
      policy = described_class.direct_outbound

      expect(policy).not_to be_restricted
      expect(policy).not_to be_firewall
      expect(policy.canonical_mode).to eq(:model_direct)
    end

    describe "new RDR-062 intents" do
      it "treats :no_outbound as restricted and firewall-required with no egress" do
        policy = described_class.no_outbound

        expect(policy).to be_restricted
        expect(policy).to be_firewall
        expect(policy).to be_no_outbound
        expect(policy.allow_destinations).to eq([])
      end

      it "treats :proxy_only as restricted and firewall-required" do
        policy = described_class.proxy_only

        expect(policy).to be_restricted
        expect(policy).to be_firewall
        expect(policy.allow_destinations).to eq([])
      end

      it "treats :git_plus_proxy as restricted and firewall-required" do
        policy = described_class.git_plus_proxy

        expect(policy).to be_restricted
        expect(policy).to be_firewall
      end

      it "treats :approved_services as restricted and firewall-required" do
        policy = described_class.approved_services

        expect(policy).to be_restricted
        expect(policy).to be_firewall
        expect(policy.canonical_mode).to eq(:approved_services)
      end

      it "treats the :proxy_restricted alias as approved_services" do
        policy = described_class.proxy_restricted

        expect(policy).to be_approved_services
      end

      it "treats :model_direct as unrestricted and firewall-free" do
        policy = described_class.model_direct

        expect(policy).not_to be_restricted
        expect(policy).not_to be_firewall
        expect(policy).to be_model_direct
        expect(policy).not_to be_explicit_internet
      end

      it "treats :explicit_internet as unrestricted and firewall-free" do
        policy = described_class.explicit_internet

        expect(policy).not_to be_restricted
        expect(policy).not_to be_firewall
        expect(policy).to be_explicit_internet
        expect(policy).not_to be_model_direct
      end

      it "preserves the legacy :proxy_restricted mode value while normalizing canonical_mode" do
        policy = described_class.proxy_restricted

        expect(policy.mode).to eq(:proxy_restricted)
        expect(policy.canonical_mode).to eq(:approved_services)
        expect(policy).to be_restricted
      end

      it "normalizes :subscription_auth to the :model_direct canonical mode" do
        expect(described_class.subscription_auth.canonical_mode).to eq(:model_direct)
      end

      it "normalizes :direct_outbound to the :model_direct canonical mode" do
        expect(described_class.direct_outbound.canonical_mode).to eq(:model_direct)
      end

      it "returns the mode unchanged for each canonical intent" do
        %i[no_outbound proxy_only git_plus_proxy approved_services model_direct explicit_internet].each do |mode|
          policy = described_class.public_send(mode)

          expect(policy.canonical_mode).to eq(mode), "expected canonical_mode for #{mode}"
        end
      end

      it "rejects unknown networking policy modes at construction time" do
        expect {
          described_class.new(mode: :unknown_mode, firewall: true, allow_destinations: [])
        }.to raise_error(ArgumentError, /Unknown networking policy mode/)
      end

      it "rejects firewall settings that conflict with the mode" do
        expect {
          described_class.new(mode: :model_direct, firewall: true, allow_destinations: [])
        }.to raise_error(ArgumentError, /requires firewall=false/)
      end

      it "rejects allow destinations without host and port keys" do
        expect {
          described_class.proxy_only(allow_destinations: [ { host: "10.0.0.1" } ])
        }.to raise_error(ArgumentError, /missing keys: port/)
      end

      it "normalizes allow destinations with string keys" do
        policy = described_class.proxy_only(allow_destinations: [ { "host" => "10.0.0.1", "port" => 5432 } ])

        expect(policy.allow_destinations).to eq([ { host: "10.0.0.1", port: 5432 } ])
      end

      it "normalizes string ports to integers" do
        policy = described_class.proxy_only(allow_destinations: [ { "host" => "10.0.0.1", "port" => "5432" } ])

        expect(policy.allow_destinations).to eq([ { host: "10.0.0.1", port: 5432 } ])
      end

      it "rejects allow destinations with an invalid host value" do
        expect {
          described_class.proxy_only(allow_destinations: [ { host: "bad host", port: 5432 } ])
        }.to raise_error(ArgumentError, /host is invalid/)
      end

      it "rejects allow destinations with an invalid port value" do
        expect {
          described_class.proxy_only(allow_destinations: [ { host: "10.0.0.1", port: 70_000 } ])
        }.to raise_error(ArgumentError, /port is invalid/)
      end
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

    describe "#output_manifest" do
      let(:project) { create(:project, owner: "acme", repo: "widgets") }
      let(:agent_run) do
        create(
          :agent_run,
          project: project,
          branch_name: "feature/remote-contract",
          result_commit_sha: "abc123",
          pull_request_number: 42,
          pull_request_url: "https://example.test/pr/42",
          review_url: "https://example.test/review/42",
          verification_result: {
            "status" => "passed",
            "artifacts" => [
              { "kind" => "trace", "url" => "https://artifacts.test/trace.zip", "note" => "Playwright trace" }
            ]
          }
        )
      end

      it "builds an output manifest that separates code, binary, and structured outputs" do
        manifest = described_class.success(stdout: "ok", exit_code: 0).output_manifest(agent_run:)

        expect(manifest).to be_a(ExecutionRunners::ExecutionOutputManifest)
        expect(manifest.artifacts["code_outputs"].first["result_commit_sha"]).to eq("abc123")
        expect(manifest.artifacts["binary_artifacts"].first["lane"]).to eq("object_storage")
        expect(manifest.artifacts["structured_results"].first["kind"]).to eq("verification_result")
        expect(manifest.git_output["pull_request_number"]).to eq(42)
      end
    end
  end

  describe ExecutionRunners::ExecutionInputManifest do
    let(:project) { create(:project, owner: "acme", repo: "widgets") }
    let(:agent_run) do
      create(
        :agent_run,
        project: project,
        branch_name: "feature/remote-contract",
        base_commit_sha: "deadbeef",
        source_pull_request_number: 7,
        custom_prompt: "Build the thing",
        prompt_version: create(:prompt_version),
        issue: create(:issue, project:)
      )
    end
    let(:services) do
      [
        ExecutionRunners::ServiceDeclaration.new(
          name: "postgres",
          image: "postgres:16",
          port: 5432,
          env: { "POSTGRES_PASSWORD" => "super-secret" },
          type: :database
        )
      ]
    end
    let(:run_spec) do
      ExecutionRunners::RunSpec.new(
        agent_run: agent_run,
        project: project,
        image: "paid/agent:latest",
        command: "claude code",
        resources: ExecutionRunners::ComputeRequirements.new(cpu_quota: 100_000, memory_bytes: 1024, pids_limit: 50),
        environment: { "DATABASE_URL" => "postgres://secret@db", "API_TOKEN" => "shh" },
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted,
        workspace: ExecutionRunners::WorkspaceStrategy.named_volume,
        services: services,
        secrets_config: { "github_token" => "top-secret" }
      )
    end

    it "serializes and round-trips through JSON" do
      manifest = described_class.from_run_spec(run_spec)
      restored = described_class.from_json(manifest.to_json)

      expect(restored).to eq(manifest)
    end

    it "keeps secret values and host paths out of the manifest by construction" do
      manifest_json = described_class.from_run_spec(run_spec).to_json

      expect(manifest_json).not_to include("postgres://secret@db")
      expect(manifest_json).not_to include("super-secret")
      expect(manifest_json).not_to include("top-secret")
      expect(manifest_json).not_to include("/var/paid/worktrees")
      expect(manifest_json).to include("DATABASE_URL")
      expect(manifest_json).to include("POSTGRES_PASSWORD")
    end
  end

  describe ExecutionRunners::ExecutionOutputManifest do
    let(:project) { create(:project, owner: "acme", repo: "widgets") }
    let(:agent_run) do
      create(
        :agent_run,
        project: project,
        branch_name: "feature/remote-contract",
        result_commit_sha: "abc123",
        pull_request_number: 42,
        pull_request_url: "https://example.test/pr/42",
        verification_result: {
          "status" => "passed",
          "summary" => "Verified",
          "artifacts" => [
            { "kind" => "trace", "url" => "https://artifacts.test/trace.zip", "note" => "Playwright trace" }
          ]
        }
      )
    end

    it "serializes and round-trips through JSON" do
      manifest = described_class.from_result(
        execution_result: ExecutionRunners::ExecutionResult.success(stdout: "ok", exit_code: 0),
        agent_run: agent_run
      )

      expect(described_class.from_json(manifest.to_json)).to eq(manifest)
    end

    it "records log, verification, git, and object-storage references" do
      manifest = described_class.from_result(
        execution_result: ExecutionRunners::ExecutionResult.success(stdout: "ok", exit_code: 0),
        agent_run: agent_run
      )

      expect(manifest.log_refs.first["kind"]).to eq("agent_run_logs")
      expect(manifest.lanes["object_storage"].first.dig("locator", "url")).to eq("https://artifacts.test/trace.zip")
      expect(manifest.lanes["git"].first["kind"]).to eq("git_output")
      expect(manifest.verification["status"]).to eq("passed")
    end
  end

  describe ExecutionRunners::ExecutionStatus do
    it "carries state, exit code, OOM flag, and memory limit" do
      status = described_class.new(state: :exited, exit_code: 0, oom_killed: false, memory_limit: 1024)

      expect(status.state).to eq(:exited)
      expect(status.exit_code).to eq(0)
      expect(status.oom_killed).to be(false)
      expect(status.memory_limit).to eq(1024)
    end

    it "exposes state predicates" do
      expect(described_class.new(state: :running, exit_code: nil, oom_killed: false, memory_limit: nil)).to be_running
      expect(described_class.new(state: :exited, exit_code: 1, oom_killed: false, memory_limit: nil)).to be_exited
      expect(described_class.new(state: :oom_killed, exit_code: 137, oom_killed: true, memory_limit: 1024)).to be_oom_killed
      expect(described_class.new(state: :not_found, exit_code: nil, oom_killed: false, memory_limit: nil)).to be_not_found
    end

    it "builds a not_found status for an uninspectable environment" do
      status = described_class.not_found

      expect(status.state).to eq(:not_found)
      expect(status.exit_code).to be_nil
      expect(status.oom_killed).to be(false)
      expect(status.memory_limit).to be_nil
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
