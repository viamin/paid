# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-007
# @spec CONTAINER-RUNTIME-008
# @spec CONTAINER-RUNTIME-009
# @spec CONTAINER-RUNTIME-010
# @spec CONTAINER-RUNTIME-011
# @spec CONTAINER-RUNTIME-017
# @spec CONTAINER-RUNTIME-018
# @spec CONTAINER-RUNTIME-020
# @spec EXEC-INGRESS-001
# @spec EXEC-INGRESS-002
RSpec.describe ExecutionRunners do
  describe ".resolve" do
    it "returns a LocalDockerRunner for the current Docker-only backends" do
      backend = instance_double(Containers::Backends::Base, identifier: "local")

      runner = described_class.resolve(backend: backend)

      expect(runner).to be_a(ExecutionRunners::LocalDockerRunner)
    end
  end

  describe ExecutionRunners::ComputeRequirements do
    # @spec CONTAINER-RUNTIME-027
    it "is an immutable Data object with cpu, memory, disk, and pids fields" do
      requirements = described_class.new(
        cpu_quota: 200_000,
        memory_bytes: 4 * 1024 ** 3,
        disk_bytes: 2 * 1024 ** 3,
        pids_limit: 500
      )

      expect(requirements.cpu_quota).to eq(200_000)
      expect(requirements.memory_bytes).to eq(4_294_967_296)
      expect(requirements.disk_bytes).to eq(2_147_483_648)
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
        issue_id: nil,
        execution_ingress_policy: ExecutionRunners::IngressPolicy.default_deny
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
        resources: ExecutionRunners::ComputeRequirements.new(cpu_quota: 1, memory_bytes: 2, disk_bytes: 3, pids_limit: 4),
        environment: { "FOO" => "bar" },
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted,
        ingress_policy: ExecutionRunners::IngressPolicy.default_deny,
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
      expect(spec.ingress_policy).to be_a(ExecutionRunners::IngressPolicy)
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
      expect(manifest.execution.dig("ingress", "public_inbound")).to be(false)
    end

    # @spec CONTAINER-RUNTIME-027
    it "reuses the requested-resource envelope when building from an agent run" do
      project = create(:project)
      run = create(:agent_run, project: project, external_metadata: {
        "requested_resources" => {
          "cpu_quota" => 123_000,
          "memory_bytes" => 5.gigabytes,
          "disk_bytes" => 2.gigabytes
        }
      })

      built = described_class.from_agent_run(run, memory_bytes: 0)

      expect(built.resources.cpu_quota).to eq(123_000)
      expect(built.resources.memory_bytes).to eq(5.gigabytes)
      expect(built.resources.disk_bytes).to eq(2.gigabytes)
    end
  end

  describe ExecutionRunners::IngressCapability do
    it "normalizes a scoped authenticated preview grant" do
      capability = described_class.build(
        kind: "preview",
        scope: "paid_mediated_tunnel",
        expires_at: 2.days.from_now.iso8601,
        authentication: { required: true, type: "authenticated_proxy" },
        granted_at: 1.day.ago.iso8601,
        granted_by: "user:42"
      )

      expect(capability).to be_preview
      expect(capability).to be_supported_kind
      expect(capability).to be_authenticated
      expect(capability).to be_valid_grant
      expect(capability.to_h["granted_by"]).to eq("user:42")
    end
  end

  describe ExecutionRunners::IngressPolicy do
    it "defaults to no public inbound endpoint" do
      policy = described_class.default_deny

      expect(policy.public_inbound).to be(false)
      expect(policy.capabilities).to eq([])
      expect(policy.violation_message).to be_nil
    end

    it "treats absent metadata as the default-deny posture" do
      policy = described_class.from_metadata({})

      expect(policy.public_inbound).to be(false)
      expect(policy).to be_explicit
      expect(policy.violation_message).to be_nil
    end

    it "treats nil metadata as the default-deny posture" do
      policy = described_class.from_metadata(nil)

      expect(policy.public_inbound).to be(false)
      expect(policy).to be_explicit
    end

    it "rejects a preview exception whose grant has expired" do
      policy = described_class.from_metadata(
        "public_inbound" => false,
        "capabilities" => [
          {
            "kind" => "preview",
            "scope" => "paid_mediated_tunnel",
            "expires_at" => 1.hour.ago.iso8601,
            "authentication" => { "required" => true, "type" => "authenticated_proxy" },
            "granted_at" => 2.hours.ago.iso8601,
            "granted_by" => "user:42"
          }
        ]
      )

      expect(policy.supported_for_runtime?).to be(false)
      expect(policy.violation_message)
        .to eq("Ingress exception grants must be authenticated, time-bounded, and explicitly recorded.")
    end

    it "accepts an authenticated, time-bounded preview exception" do
      policy = described_class.default_deny(
        capabilities: [
          ExecutionRunners::IngressCapability.build(
            kind: "preview",
            scope: "paid_mediated_tunnel",
            expires_at: 2.days.from_now.iso8601,
            authentication: { required: true, type: "authenticated_proxy" },
            granted_at: 1.day.ago.iso8601,
            granted_by: "user:42"
          )
        ]
      )

      expect(policy.supported_for_runtime?).to be(true)
      expect(policy.violation_message).to be_nil
    end

    it "rejects metadata that requests public inbound exposure" do
      policy = described_class.from_metadata("public_inbound" => true)

      expect(policy.supported_for_runtime?).to be(false)
      expect(policy.violation_message)
        .to eq("Execution ingress policy must explicitly deny public inbound exposure.")
    end

    it "rejects unsupported inbound exposure kinds" do
      policy = described_class.default_deny(
        capabilities: [
          ExecutionRunners::IngressCapability.build(
            kind: "debug",
            scope: "public_listener",
            expires_at: 2.days.from_now.iso8601,
            authentication: { required: true, type: "signed_token" },
            granted_at: 1.day.ago.iso8601,
            granted_by: "user:42"
          )
        ]
      )

      expect(policy.supported_for_runtime?).to be(false)
      expect(policy.violation_message).to eq("Unsupported inbound exposure requested: debug.")
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

    it "defaults the egress_profile to :locked for every factory method" do
      expect(described_class.proxy_restricted.egress_profile).to eq(:locked)
      expect(described_class.subscription_auth.egress_profile).to eq(:locked)
      expect(described_class.direct_outbound.egress_profile).to eq(:locked)
    end

    it "exposes :locked, :research, and :open egress profiles through the factory methods" do
      expect(described_class.proxy_restricted(egress_profile: :research)).to be_research
      expect(described_class.subscription_auth(egress_profile: :open)).to be_open
      expect(described_class.direct_outbound(egress_profile: :locked)).to be_locked
    end

    it "treats :locked as the production-default profile" do
      policy = described_class.proxy_restricted

      expect(policy).to be_locked
      expect(policy).not_to be_research
      expect(policy).not_to be_open
    end

    it "propagates :research for runs that need brokered web evidence" do
      policy = described_class.proxy_restricted(
        allow_destinations: [ { host: "research-gateway", port: 8443 } ],
        egress_profile: :research
      )

      expect(policy).to be_research
      expect(policy.allow_destinations).to eq([ { host: "research-gateway", port: 8443 } ])
      expect(policy).to be_firewall
    end

    it "propagates :open for operator-only break-glass runs" do
      policy = described_class.direct_outbound(egress_profile: :open)

      expect(policy).to be_open
      expect(policy).not_to be_firewall
    end

    it "never references Docker-specific concepts on the policy surface" do
      members = described_class.members

      expect(members).to contain_exactly(:mode, :firewall, :allow_destinations, :egress_profile)
    end

    it "rejects an egress_profile outside the closed :locked/:research/:open enum" do
      expect { described_class.proxy_restricted(egress_profile: :reserach) }
        .to raise_error(ArgumentError, /Invalid egress_profile/)
      expect { described_class.subscription_auth(egress_profile: "research") }
        .to raise_error(ArgumentError, /Invalid egress_profile/)
      expect { described_class.direct_outbound(egress_profile: nil) }
        .to raise_error(ArgumentError, /Invalid egress_profile/)
    end

    it "rejects invalid egress_profile values for direct .new and #with construction paths" do
      expect {
        described_class.new(mode: :proxy_restricted, firewall: true, allow_destinations: [], egress_profile: :reserach)
      }.to raise_error(ArgumentError, /Invalid egress_profile/)

      policy = described_class.proxy_restricted

      expect {
        policy.with(egress_profile: "research")
      }.to raise_error(ArgumentError, /Invalid egress_profile/)
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
      # Verification-result artifacts are agent-authored input. The
      # consumption contract only honors URLs from this lane — a spoofed
      # `storage_key` under another tenant's prefix would otherwise be
      # re-signed into a working presigned URL by any durable consumer.
      let(:report_artifact) do
        {
          "kind" => "generated_report",
          "content_type" => "application/pdf",
          "storage_key" => "reports/acme/widgets/pr-42/abc123/summary.pdf",
          "url" => "https://artifacts.test/summary.pdf",
          "context" => {
            "account_id" => 9_999,
            "project_id" => 9_999,
            "agent_run_id" => 999_999
          },
          "metadata" => {
            "note" => "Summary report"
          }
        }
      end
      let(:expected_binary_artifact) do
        {
          "lane" => "object_storage",
          "kind" => "generated_report",
          "content_type" => "application/pdf",
          "locator" => { "url" => "https://artifacts.test/summary.pdf" },
          "context" => {
            "account_id" => project.account_id,
            "project_id" => project.id,
            "agent_run_id" => agent_run.id
          },
          "metadata" => {
            "note" => "Summary report"
          }
        }
      end
      let(:persisted_manifest_artifact) do
        {
          "lane" => "object_storage",
          "kind" => "screenshot",
          "content_type" => "image/png",
          "locator" => { "key" => "screenshots/acme/widgets/pr-42/abc123/home.png" },
          "context" => {
            "account_id" => project.account_id,
            "project_id" => project.id,
            "agent_run_id" => agent_run.id
          },
          "metadata" => { "route_name" => "home" }
        }
      end
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
            "artifacts" => [ report_artifact ]
          }
        )
      end

      it "builds an output manifest that separates code, binary, and structured outputs" do
        manifest = described_class.success(stdout: "ok", exit_code: 0).output_manifest(agent_run:)

        expect(manifest).to be_a(ExecutionRunners::ExecutionOutputManifest)
        expect(manifest.artifacts["code_outputs"].first["result_commit_sha"]).to eq("abc123")
        expect(manifest.artifacts["binary_artifacts"].first).to include(expected_binary_artifact)
        expect(manifest.artifacts["structured_results"].first["kind"]).to eq("verification_result")
        expect(manifest.git_output["pull_request_number"]).to eq(42)
      end

      # @spec CONTAINER-RUNTIME-018
      it "forwards persisted artifact-manifest keys without inventing presigned URLs" do
        agent_run.update!(external_metadata: { "artifact_manifest" => [ persisted_manifest_artifact ] })

        manifest = described_class.success(stdout: "ok", exit_code: 0).output_manifest(agent_run:)

        expect(manifest.artifacts["binary_artifacts"]).to include(
          hash_including(
            "kind" => "screenshot",
            "locator" => { "key" => "screenshots/acme/widgets/pr-42/abc123/home.png" }
          )
        )
      end

      # @spec CONTAINER-RUNTIME-018
      # Verification artifacts are agent-authored input. A spoofed `storage_key`
      # under another tenant's prefix must not survive into the durable manifest,
      # because durable consumers re-sign keys into presigned URLs.
      it "drops verification-artifact storage keys and locator keys" do
        spoofed_key = "screenshots/other-org/other-repo/pr-1/abc/home.png"
        artifact = {
          "kind" => "spoofed_artifact",
          "url" => "https://artifacts.test/spoofed.png",
          "storage_key" => spoofed_key,
          "locator" => { "key" => spoofed_key, "url" => "https://artifacts.test/spoofed.png" }
        }
        agent_run.update!(verification_result: { "status" => "passed", "artifacts" => [ artifact ] })

        manifest = described_class.success(stdout: "ok", exit_code: 0).output_manifest(agent_run:)
        entry = manifest.artifacts["binary_artifacts"].first

        expect(entry["locator"]).to eq({ "url" => "https://artifacts.test/spoofed.png" })
        expect(entry["locator"]).not_to have_key("key")
        expect(entry.to_s).not_to include(spoofed_key)
      end

      # @spec CONTAINER-RUNTIME-018
      # `external_metadata` is not exclusively runner-written: interop callers
      # can persist arbitrary `artifact_manifest` entries
      # (`Api::Projects::ExternalAgentRunsController` →
      # `AgentRuns::IngestExternal` stores `external_metadata` verbatim). A key
      # planted under another tenant's prefix must therefore degrade to
      # URL-only even on the trusted lane, because durable consumers re-sign
      # keys into presigned URLs.
      it "drops trusted-lane locator keys outside the project's storage namespace" do
        planted_key = "screenshots/other-org/other-repo/pr-1/abc/home.png"
        artifact = {
          "kind" => "screenshot",
          "storage_key" => planted_key,
          "url" => "https://artifacts.test/planted.png",
          "locator" => { "key" => planted_key, "url" => "https://artifacts.test/planted.png" }
        }
        agent_run.update!(external_metadata: { "artifact_manifest" => [ artifact ] })

        manifest = described_class.success(stdout: "ok", exit_code: 0).output_manifest(agent_run:)
        entry = manifest.artifacts["binary_artifacts"].first

        expect(entry["locator"]).to eq({ "url" => "https://artifacts.test/planted.png" })
        expect(entry.to_s).not_to include(planted_key)
      end

      # @spec CONTAINER-RUNTIME-018
      # The system always knows the run's real account/project/run identity;
      # the artifact must never be allowed to misattribute itself to a
      # different tenant.
      it "makes the run's identity authoritative over artifact-supplied context" do
        manifest = described_class.success(stdout: "ok", exit_code: 0).output_manifest(agent_run:)
        entry = manifest.artifacts["binary_artifacts"].first

        expect(entry["context"]).to eq(
          "account_id" => project.account_id,
          "project_id" => project.id,
          "agent_run_id" => agent_run.id
        )
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
    let(:expected_git_lane) do
      [
        {
          "lane" => "git",
          "kind" => "repository_checkout",
          "locator" => {
            "repo_full_name" => "acme/widgets",
            "branch_name" => "feature/remote-contract",
            "base_commit_sha" => "deadbeef",
            "source_pull_request_number" => 7
          }
        }
      ]
    end
    let(:expected_control_plane_refs) do
      [
        {
          "lane" => "control_plane_api",
          "kind" => "prompt_version",
          "locator" => { "prompt_version_id" => agent_run.prompt_version_id }
        },
        {
          "lane" => "control_plane_api",
          "kind" => "custom_prompt",
          "locator" => {
            "agent_run_id" => agent_run.id,
            "sha256" => Digest::SHA256.hexdigest("Build the thing")
          }
        },
        {
          "lane" => "control_plane_api",
          "kind" => "issue",
          "locator" => { "issue_id" => agent_run.issue_id }
        }
      ]
    end
    let(:expected_credential_refs) do
      [
        {
          "lane" => "credentials",
          "kind" => "environment_variable",
          "locator" => { "name" => "DATABASE_URL" },
          "source" => "run_spec.environment"
        },
        {
          "lane" => "credentials",
          "kind" => "environment_variable",
          "locator" => { "name" => "API_TOKEN" },
          "source" => "run_spec.environment"
        },
        {
          "lane" => "credentials",
          "kind" => "service_environment_variable",
          "locator" => { "name" => "POSTGRES_PASSWORD", "service" => "postgres" },
          "source" => "service_declaration.env"
        },
        {
          "lane" => "credentials",
          "kind" => "secrets_config_entry",
          "locator" => { "name" => "github_token" },
          "source" => "run_spec.secrets_config"
        }
      ]
    end
    let(:expected_service_manifest) do
      [
        {
          "name" => "postgres",
          "image" => "postgres:16",
          "port" => 5432,
          "type" => "database",
          "env_keys" => [ "POSTGRES_PASSWORD" ]
        }
      ]
    end
    let(:run_spec) do
      ExecutionRunners::RunSpec.new(
        agent_run: agent_run,
        project: project,
        image: "paid/agent:latest",
        command: "claude code",
        resources: ExecutionRunners::ComputeRequirements.new(cpu_quota: 100_000, memory_bytes: 1024, disk_bytes: 2048, pids_limit: 50),
        environment: { "DATABASE_URL" => "postgres://secret@db", "API_TOKEN" => "shh" },
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted,
        ingress_policy: ExecutionRunners::IngressPolicy.default_deny,
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

    it "records all four transfer lanes with provider-neutral references" do
      manifest = described_class.from_run_spec(run_spec)

      expect(manifest.lanes.keys).to contain_exactly("git", "control_plane_api", "object_storage", "credentials")
      expect(manifest.lanes["git"]).to eq(expected_git_lane)
      expect(manifest.lanes["control_plane_api"]).to match_array(expected_control_plane_refs)
      expect(manifest.lanes["object_storage"]).to eq([])
      expect(manifest.lanes["credentials"]).to match_array(expected_credential_refs)
    end

    it "describes normal execution without requiring shared host storage" do
      manifest = described_class.from_run_spec(run_spec)

      expect(manifest.execution["workspace"]).to eq(
        "mode" => "named_volume",
        "mount_point" => "/workspace"
      )
      expect(manifest.execution["workspace"]).not_to have_key("reference")
      expect(manifest.repository).to include(
        "provider" => "github",
        "repo_full_name" => "acme/widgets",
        "repository_url" => "https://github.com/acme/widgets"
      )
      expect(manifest.services).to eq(expected_service_manifest)
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

    it "carries the locked egress profile on the manifest by default" do
      manifest = described_class.from_run_spec(run_spec)

      expect(manifest.execution["networking"]).to include(
        "mode" => "proxy_restricted",
        "firewall" => true,
        "egress_profile" => "locked"
      )
    end

    it "propagates a research egress profile through the manifest" do
      research_spec = run_spec.with(
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted(egress_profile: :research)
      )
      manifest = described_class.from_run_spec(research_spec)

      expect(manifest.execution["networking"]).to include(
        "egress_profile" => "research"
      )
    end

    it "propagates an open / break-glass egress profile through the manifest" do
      open_spec = run_spec.with(
        networking_policy: ExecutionRunners::NetworkingPolicy.direct_outbound(egress_profile: :open)
      )
      manifest = described_class.from_run_spec(open_spec)

      expect(manifest.execution["networking"]).to include(
        "mode" => "direct_outbound",
        "firewall" => false,
        "egress_profile" => "open"
      )
    end

    it "never serializes Docker network names or iptables into the manifest" do
      manifest = described_class.from_run_spec(run_spec)
      manifest_json = manifest.to_json

      expect(manifest_json).not_to include("paid_agent")
      expect(manifest_json).not_to include("paid_internal")
      expect(manifest_json).not_to include("iptables")
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
    let(:expected_binary_artifacts) do
      [
        {
          "lane" => "object_storage",
          "kind" => "trace",
          "locator" => { "url" => "https://artifacts.test/trace.zip" },
          "context" => {
            "account_id" => project.account_id,
            "project_id" => project.id,
            "agent_run_id" => agent_run.id
          },
          "metadata" => { "note" => "Playwright trace" }
        }
      ]
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

    it "represents durable binary artifacts as object-storage manifest entries" do
      manifest = described_class.from_result(
        execution_result: ExecutionRunners::ExecutionResult.success(stdout: "ok", exit_code: 0),
        agent_run: agent_run
      )

      expect(manifest.artifacts["binary_artifacts"]).to eq(expected_binary_artifacts)
      expect(manifest.artifacts["code_outputs"]).to contain_exactly(manifest.git_output)
      expect(manifest.artifacts["structured_results"]).to contain_exactly(
        {
          "kind" => "verification_result",
          "value" => manifest.verification
        }
      )
      expect(manifest.lanes["credentials"]).to eq([])
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
