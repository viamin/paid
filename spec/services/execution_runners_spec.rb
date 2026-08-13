# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-007
# @spec CONTAINER-RUNTIME-008
# @spec CONTAINER-RUNTIME-009
# @spec CONTAINER-RUNTIME-010
# @spec CONTAINER-RUNTIME-011
# @spec CONTAINER-RUNTIME-017
# @spec CONTAINER-RUNTIME-018
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
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted,
        workspace: ExecutionRunners::WorkspaceStrategy.named_volume,
        services: [ ExecutionRunners::ServiceDeclaration.new(name: "postgres", image: "pg", port: 5432, env: {}, type: :database) ],
        authority_grant: nil,
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

    describe ".from_agent_run" do
      it "carries the authority grant through as a first-class field" do
        agent_run = instance_double(AgentRun,
          project: instance_double(Project),
          service_environment: {},
          worktree_path: nil)
        grant = ExecutionRunners::AuthorityGrant.proxy

        spec = described_class.from_agent_run(agent_run, networking_policy: nil, authority_grant: grant)

        expect(spec.authority_grant).to eq(grant)
        expect(spec.authority_grant).to be_proxy
      end

      it "defaults the authority grant to nil when none is provided" do
        agent_run = instance_double(AgentRun,
          project: instance_double(Project),
          service_environment: {},
          worktree_path: nil)

        spec = described_class.from_agent_run(agent_run)

        expect(spec.authority_grant).to be_nil
      end
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
    end

    it "treats subscription_auth mode as unrestricted" do
      policy = described_class.subscription_auth

      expect(policy).not_to be_restricted
      expect(policy).not_to be_firewall
      expect(policy.allow_destinations).to eq([])
    end

    it "treats direct_outbound mode as unrestricted" do
      policy = described_class.direct_outbound

      expect(policy).not_to be_restricted
      expect(policy).not_to be_firewall
    end
  end

  describe ExecutionRunners::CredentialGrant do
    it "builds a grant with a credential class and metadata" do
      grant = described_class.build(:mcp_credentials, metadata: { "server_count" => 3 })

      expect(grant.credential_class).to eq(:mcp_credentials)
      expect(grant.metadata).to eq({ "server_count" => 3 })
    end

    it "defaults metadata to an empty hash when omitted" do
      grant = described_class.build(:github_authority)

      expect(grant.metadata).to eq({})
    end

    it "defaults metadata to an empty hash when nil is passed" do
      grant = described_class.build(:github_authority, metadata: nil)

      expect(grant.metadata).to eq({})
    end

    it "exposes credential-class predicates" do
      grant = described_class.build(:paid_proxy_token)

      expect(grant).to be_paid_proxy_token
      expect(grant).not_to be_github_authority
    end

    it "defines all documented credential classes" do
      classes = described_class::CREDENTIAL_CLASSES.keys

      expect(classes).to contain_exactly(
        :paid_proxy_token, :github_authority,
        :model_provider_proxy, :model_provider_direct,
        :subscription_auth, :mcp_credentials,
        :object_storage_upload, :service_credentials
      )
    end
  end

  describe ExecutionRunners::AuthorityGrant do
    describe ".proxy" do
      it "builds a proxy-mode grant with the RDR-006 default credential classes" do
        grant = described_class.proxy

        expect(grant).to be_proxy
        expect(grant).not_to be_subscription_auth
        expect(grant).not_to be_direct_outbound
        expect(grant.granted_classes).to contain_exactly(
          :paid_proxy_token, :github_authority, :model_provider_proxy
        )
      end

      it "includes additional grants passed by the caller" do
        mcp = ExecutionRunners::CredentialGrant.build(:mcp_credentials)
        grant = described_class.proxy(grants: [ mcp ])

        expect(grant).to be_proxy
        expect(grant.granted_classes).to include(:mcp_credentials)
      end
    end

    describe ".subscription_auth" do
      it "builds a subscription-auth grant distinguishable from proxy and direct-outbound modes" do
        grant = described_class.subscription_auth

        expect(grant).to be_subscription_auth
        expect(grant).not_to be_proxy
        expect(grant).not_to be_direct_outbound
        expect(grant.granted_classes).to include(:subscription_auth)
        expect(grant.granted_classes).not_to include(:model_provider_proxy)
      end
    end

    describe ".direct_outbound" do
      it "builds a direct-outbound grant distinguishable from proxy and subscription-auth modes" do
        grant = described_class.direct_outbound

        expect(grant).to be_direct_outbound
        expect(grant).not_to be_proxy
        expect(grant).not_to be_subscription_auth
        expect(grant.granted_classes).to include(:model_provider_direct)
        expect(grant.granted_classes).not_to include(:model_provider_proxy)
      end
    end

    describe "MCP grant construction" do
      it "adds MCP credentials to a proxy-mode grant" do
        grant = described_class.proxy(grants: [
          ExecutionRunners::CredentialGrant.build(:mcp_credentials, metadata: { "server_count" => 2 })
        ])

        expect(grant).to be_granted(:mcp_credentials)
        expect(grant.grant_for(:mcp_credentials).metadata).to eq({ "server_count" => 2 })
      end

      it "adds MCP credentials to a subscription-auth grant" do
        grant = described_class.subscription_auth(grants: [
          ExecutionRunners::CredentialGrant.build(:mcp_credentials)
        ])

        expect(grant).to be_granted(:mcp_credentials)
      end

      it "adds MCP credentials to a direct-outbound grant" do
        grant = described_class.direct_outbound(grants: [
          ExecutionRunners::CredentialGrant.build(:mcp_credentials)
        ])

        expect(grant).to be_granted(:mcp_credentials)
      end
    end

    describe "artifact-upload grant construction" do
      it "adds object-storage upload authority to a proxy-mode grant" do
        grant = described_class.proxy(grants: [
          ExecutionRunners::CredentialGrant.build(:object_storage_upload, metadata: { "bucket" => "paid-screenshots" })
        ])

        expect(grant).to be_granted(:object_storage_upload)
        expect(grant.grant_for(:object_storage_upload).metadata).to eq({ "bucket" => "paid-screenshots" })
      end
    end

    describe "#to_summary" do
      it "returns a secret-free summary with only the mode and credential classes" do
        grant = described_class.proxy(grants: [
          ExecutionRunners::CredentialGrant.build(:mcp_credentials, metadata: { "secret_token" => "super-secret-value" })
        ])

        summary = grant.to_summary

        expect(summary).to eq({
          "mode" => "proxy",
          "credential_classes" => %w[paid_proxy_token github_authority model_provider_proxy mcp_credentials]
        })
      end

      it "returns a secret-free summary for a subscription-auth grant" do
        grant = described_class.subscription_auth

        expect(grant.to_summary).to eq({
          "mode" => "subscription_auth",
          "credential_classes" => %w[paid_proxy_token github_authority subscription_auth]
        })
      end

      it "returns a secret-free summary for a direct-outbound grant" do
        grant = described_class.direct_outbound

        expect(grant.to_summary).to eq({
          "mode" => "direct_outbound",
          "credential_classes" => %w[github_authority model_provider_direct]
        })
      end

      it "never exposes secret values from grant metadata" do
        grant = described_class.proxy(grants: [
          ExecutionRunners::CredentialGrant.build(:object_storage_upload, metadata: { "access_key" => "AKIAIOSFODNN7EXAMPLE" })
        ])

        serialized = JSON.generate(grant.to_summary)

        expect(serialized).not_to include("AKIAIOSFODNN7EXAMPLE")
      end
    end

    describe "#granted?" do
      it "returns true for granted credential classes and false otherwise" do
        grant = described_class.proxy

        expect(grant).to be_granted(:paid_proxy_token)
        expect(grant).to be_granted(:github_authority)
        expect(grant).not_to be_granted(:subscription_auth)
        expect(grant).not_to be_granted(:object_storage_upload)
      end
    end

    describe "#grant_for" do
      it "returns the CredentialGrant for a granted class" do
        mcp = ExecutionRunners::CredentialGrant.build(:mcp_credentials)
        grant = described_class.proxy(grants: [ mcp ])

        expect(grant.grant_for(:mcp_credentials)).to eq(mcp)
      end

      it "returns nil for a credential class that is not granted" do
        grant = described_class.proxy

        expect(grant.grant_for(:service_credentials)).to be_nil
      end
    end

    describe "RunSpec integration" do
      it "carries the authority grant as a first-class field" do
        authority = described_class.proxy
        spec = ExecutionRunners::RunSpec.new(
          agent_run: nil, project: nil, image: "img", command: "cmd", resources: nil,
          environment: {}, networking_policy: nil,
          workspace: ExecutionRunners::WorkspaceStrategy.ephemeral,
          services: [], authority_grant: authority, secrets_config: nil
        )

        expect(spec.authority_grant).to eq(authority)
        expect(spec.authority_grant).to be_proxy
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
