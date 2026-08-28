# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe Containers::Provision do
  # Extracts and decodes the base64 payload from a write_container_file command
  def decoded_base64_content(cmd)
    match = cmd.match(/echo (\S+) \| base64 -d >/)
    return "" unless match

    # Shellwords.escape adds backslashes before = signs; remove them
    Base64.strict_decode64(match[1].delete("\\"))
  rescue ArgumentError
    ""
  end

  def build_preparation(path: "/workspace/tmp/prepared.txt", content: "prepared")
    preparation_write = Struct.new(:path, :content, :mode).new(path, content, nil)
    preparation_class = Struct.new(:file_writes) do
      def empty?
        false
      end
    end
    preparation_class.new([ preparation_write ])
  end

  def build_preview_tunnel_service(agent_run:, worktree_path:, app_port: 4000)
    described_class.new(
      agent_run: agent_run,
      worktree_path: worktree_path,
      preview_tunnel: {
        session_token: "preview-token",
        tunnel_port: 8201,
        app_port: app_port
      }
    )
  end

  def expect_preview_tunnel_container_config(config)
    expect(config["Env"]).to include(
      "PAID_PREVIEW_TUNNEL_CONFIG_PATH=/home/agent/.paid-preview/rathole-client.toml",
      "PAID_PREVIEW_TUNNEL_SERVICE_NAME=preview-preview-token",
      "PAID_PREVIEW_TUNNEL_PORT=8201"
    )
    expect(config["Labels"]).to include(
      "paid.preview_tunnel" => "true",
      "paid.preview_session_token" => "preview-token",
      "paid.preview_service_name" => "preview-preview-token",
      "paid.preview_tunnel_port" => "8201"
    )
  end

  def stub_exec_with_dead_container_cleanup(mock_container)
    allow(mock_container).to receive(:exec) do |cmd, **_opts, &block|
      script = cmd.is_a?(Array) ? cmd.last.to_s : cmd.to_s
      if script.include?("printf '%s' \"$PAID_PREPARATION_B64\" | base64 -d > \"$PAID_PREPARATION_TARGET\"")
        [ [], [], 0 ]
      elsif script.include?("cat \"$PAID_PREPARATION_STATE_DIR/state\"")
        raise Docker::Error::DockerError, '{"message":"Container abc123container is not running"}'
      else
        block.call(:stdout, "command output\n") if block
        [ [ "command output\n" ], [], 0 ]
      end
    end
  end

  def stub_exec_with_cleanup_failure(mock_container)
    allow(mock_container).to receive(:exec) do |cmd, **opts, &block|
      if cmd == [ "sh", "-c", "echo 'hello'" ]
        block.call(:stdout, "command output\n") if block
        next [ [ "command output\n" ], [], 0 ]
      end

      raise "Unexpected exec command: #{cmd.inspect} opts=#{opts.inspect}" unless cmd.is_a?(Array) && cmd.first(2) == [ "sh", "-lc" ]

      script = cmd.last

      if script.include?("printf '%s' \"$PAID_PREPARATION_B64\" | base64 -d > \"$PAID_PREPARATION_TARGET\"")
        [ [ "prepared\n" ], [], 0 ]
      elsif script.include?("cat \"$PAID_PREPARATION_STATE_DIR/state\"")
        [ [], [ "missing runtime preparation backup\n" ], 1 ]
      else
        raise "Unexpected shell exec command: #{cmd.inspect} opts=#{opts.inspect}"
      end
    end
  end

  def stub_provision_steps(provision)
    allow(provision).to receive(:log_system)
    allow(provision).to receive(:prepare_workspace!)
    allow(provision).to receive(:ensure_network!)
    allow(provision).to receive(:fix_all_ownership!)
    allow(provision).to receive(:seed_opencode_database!)
    allow(provision).to receive(:seed_kilo_database!)
    allow(provision).to receive(:seed_codex_credentials!)
    allow(provision).to receive(:seed_gemini_credentials!)
    allow(provision).to receive(:seed_copilot_credentials!)
    allow(provision).to receive(:seed_claude_credentials!)
    allow(provision).to receive(:apply_network_restrictions!)
  end

  def runtime_image_selection_metadata(digest: "#{'1' * 64}")
    {
      "requested_image" => "paid-agent:latest",
      "resolved_image" => "ghcr.io/acme/paid-agent@sha256:#{digest}",
      "digest" => "sha256:#{digest}",
      "architecture" => "amd64",
      "registry" => "ghcr.io",
      "repository" => "acme/paid-agent",
      "provenance_reference" => "base-amd64-2026-08-17",
      "immutable" => true
    }
  end

  def build_remote_backend_without_host_paths(container, &create_container)
    backend = instance_double(
      Containers::Backends::Base,
      identifier: "worker-1",
      remote?: false,
      supports_host_paths?: false,
      start_container: true,
      container_host_for: "worker-1"
    )
    allow(backend).to receive(:create_container, &create_container || ->(*) { container })
    backend
  end

  def stub_remote_backend_proxy_support(mock_network:, mock_volume:, mock_container:)
    remote_backend = build_remote_backend(mock_volume:, mock_container:)
    allow(remote_backend).to receive(:get_volume).and_raise(Docker::Error::NotFoundError)
    allow(remote_backend).to receive(:get_network).with("paid_agent").and_return(mock_network)
    allow(NetworkPolicy).to receive(:ensure_network!).with(network: "paid_agent", backend: remote_backend).and_return(mock_network)
    allow(NetworkPolicy).to receive(:apply_firewall_rules)
    remote_backend
  end

  def build_remote_backend(mock_volume:, mock_container:)
    instance_double(
      Containers::Backends::RemoteDocker,
      identifier: "worker-1",
      remote?: true,
      supports_host_paths?: false,
      container_host_for: "worker-1",
      create_volume: mock_volume,
      create_container: mock_container,
      start_container: true,
      exec_in_container: [ [], [], 0 ],
      delete_container: true,
      delete_volume: true
    )
  end

  def expect_remote_proxy_env(env, base_url)
    expect(env).to include(
      "PAID_PROXY_URL=#{base_url}",
      "OPENAI_BASE_URL=#{base_url}/api/proxy/openai",
      "GOOGLE_GEMINI_BASE_URL=#{base_url}/api/proxy/google"
    )
  end

  def create_cleanup_ledger_entry(agent_run, provider_resource_id:)
    create(:execution_resource_ledger_entry,
      :active,
      :with_agent_run,
      entry_account: agent_run.project.account,
      project: agent_run.project,
      agent_run: agent_run,
      provider_resource_id: provider_resource_id)
  end

  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:worktree_path) { Dir.mktmpdir("worktree") }
  let(:service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "abc123container",
      start: true,
      stop: true,
      delete: true,
      refresh!: true,
      info: { "State" => { "Running" => true, "ExitCode" => 0 } },
      exec: nil
    )
  end

  let(:mock_network) { instance_double(Docker::Network) }

  let(:mock_volume) { instance_double(Docker::Volume, remove: true) }

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
    allow(Docker::Volume).to receive(:create).and_return(mock_volume)
    allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)
    allow(NetworkPolicy).to receive_messages(ensure_network!: mock_network, apply_firewall_rules: nil)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("HOME", "/home/vscode").and_return("/tmp/paid-spec-no-local-auth")
  end

  after do
    FileUtils.rm_rf(worktree_path) if worktree_path && Dir.exist?(worktree_path)
  end

  describe ".compatibility_for with execution ingress validation" do
    # @spec EXEC-INGRESS-001
    it "rejects unsupported inbound exposure before backend compatibility work" do
      run = create(:agent_run, external_metadata: {
        AgentRun::EXECUTION_INGRESS_METADATA_KEY => {
          "public_inbound" => false,
          "capabilities" => [
            {
              "kind" => "callback",
              "scope" => "public_listener",
              "expires_at" => 2.days.from_now.iso8601,
              "authentication" => { "required" => true, "type" => "signed_token" },
              "granted_at" => 1.day.ago.iso8601,
              "granted_by" => "user:42"
            }
          ]
        }
      })
      backend = instance_double(Containers::Backends::Base)

      expect(described_class).not_to receive(:new)

      result = described_class.compatibility_for(agent_run: run, backend:)

      expect(result.compatible).to be(false)
      expect(result.error_message).to eq("Unsupported inbound exposure requested: callback.")
    end

    # @spec EXEC-INGRESS-001
    it "treats an ordinary run with no ingress metadata as default-deny compatible" do
      run = create(:agent_run, external_metadata: {})
      backend = instance_double(Containers::Backends::Base, supports_host_paths?: true)
      service = instance_double(described_class)

      allow(described_class).to receive(:new).with(
        agent_run: run, worktree_path: nil, backend: backend
      ).and_return(service)
      allow(service).to receive(:compatibility_validate_backend_mount_support!).with(record_telemetry: false)

      result = described_class.compatibility_for(agent_run: run, backend:)

      expect(result.compatible).to be(true)
      expect(result.error_message).to be_nil
    end

    # @spec CONTAINER-RUNTIME-042
    # @spec CONTAINER-RUNTIME-043
    it "rejects a verification run before provisioning when the resolved runner lacks browser_sidecar" do
      run = create(:agent_run, external_metadata: {})
      run.project.update!(screenshot_settings: run.project.effective_screenshot_settings.merge("verification_enabled" => true))
      backend = instance_double(Containers::Backends::Base, supports_host_paths?: true, identifier: "cloud-1")
      service = instance_double(described_class)
      runner_class = Class.new do
        def self.capability_compatibility_for(...)
          ExecutionRunners::CompatibilityResult.new(
            compatible: false,
            error_message: "Runner lacks required capabilities: browser sidecar."
          )
        end
      end

      allow(described_class).to receive(:new).with(
        agent_run: run, worktree_path: nil, backend: backend
      ).and_return(service)
      allow(service).to receive(:compatibility_validate_backend_mount_support!).with(record_telemetry: false)
      allow(ExecutionRunners).to receive(:resolve).with(backend: backend).and_return(runner_class.new)

      result = described_class.compatibility_for(agent_run: run, backend:)

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("browser sidecar")
    end

    # @spec CONTAINER-RUNTIME-043
    it "returns an incompatible result when deriving default capability requirements hits a retired image reference" do
      run = create(:agent_run, external_metadata: {})
      backend = instance_double(Containers::Backends::Base, supports_host_paths?: true)
      service = instance_double(described_class)
      error = Containers::RuntimeImageCatalog::UnknownReferenceError.new("unknown image reference")

      allow(described_class).to receive(:new).with(
        agent_run: run, worktree_path: nil, backend: backend
      ).and_return(service)
      allow(service).to receive(:compatibility_validate_backend_mount_support!).with(record_telemetry: false)
      allow(ExecutionRunners::CapabilityRequirements).to receive(:from_agent_run).with(
        run,
        worktree_path: nil
      ).and_raise(error)

      result = described_class.compatibility_for(agent_run: run, backend:)

      expect(result.compatible).to be(false)
      expect(result.error_message).to eq("unknown image reference")
    end
  end

  describe "constants" do
    it "defines default memory limit of 4GB" do
      expect(described_class::DEFAULTS[:memory_bytes]).to eq(4 * 1024 * 1024 * 1024)
    end

    it "defines default CPU quota for 2 CPUs" do
      expect(described_class::DEFAULTS[:cpu_quota]).to eq(200_000)
    end

    it "defines default PID limit of 500" do
      expect(described_class::DEFAULTS[:pids_limit]).to eq(500)
    end

    it "defines default timeout of 1 hour" do
      expect(described_class::DEFAULTS[:timeout_seconds]).to eq(3600)
    end

    it "defines default Codex tmpfs size of 256MB" do
      expect(described_class::DEFAULTS[:tmpfs_codex_size]).to eq(256 * 1024 * 1024)
    end

    it "defines default image name" do
      expect(described_class::DEFAULTS[:image]).to eq("paid-agent:latest")
    end

    it "does not include :network in defaults" do
      expect(described_class::DEFAULTS).not_to have_key(:network)
    end

    it "exports the Codex notify line used for seeded config" do
      expect(described_class.codex_notify_line).to eq(described_class::CODEX_NOTIFY_LINE)
    end
  end

  describe ".networking_policy_for" do
    # @spec CONTAINER-RUNTIME-020
    it "derives the proxy-restricted policy for a run with no subscription auth or direct-outbound runner" do
      policy = described_class.networking_policy_for(agent_run: agent_run, project: project)

      expect(policy.mode).to eq(:proxy_restricted)
      expect(policy).to be_restricted
      expect(policy.canonical_mode).to eq(:approved_services)
    end

    it "defaults the egress_profile to :locked when none is supplied" do
      policy = described_class.networking_policy_for(agent_run: agent_run, project: project)

      expect(policy.egress_profile).to eq(:locked)
    end

    it "threads a non-default egress_profile through without changing the mode" do
      policy = described_class.networking_policy_for(
        agent_run: agent_run, project: project, egress_profile: :research
      )

      expect(policy.egress_profile).to eq(:research)
      expect(policy.mode).to eq(:proxy_restricted)
    end

    it "rejects an egress_profile outside the closed :locked/:research/:open enum" do
      expect {
        described_class.networking_policy_for(agent_run: agent_run, project: project, egress_profile: :reserach)
      }.to raise_error(ArgumentError, /Invalid egress_profile/)
    end
  end

  # RDR-058: runners that cannot satisfy isolation requirements are rejected
  # by capability validation (a typed CompatibilityResult), not a generic
  # agent failure. @spec EXECUTION-ISOLATION-004
  describe ".compatibility_for with workspace compatibility" do
    let(:local_backend) { instance_double(Containers::Backends::LocalDocker, supports_host_paths?: true) }

    it "returns a compatible result without raising for a host-path-capable backend" do
      result = described_class.compatibility_for(agent_run: agent_run, backend: local_backend, worktree_path: worktree_path)

      expect(result).to be_a(Containers::Provision::CompatibilityResult)
      expect(result.compatible).to be(true)
      expect(result.error_message).to be_nil
    end

    it "returns an incompatible result, not a raised error, when the backend cannot host-bind-mount the worktree" do
      remote_backend = instance_double(
        Containers::Backends::RemoteDocker,
        identifier: "worker-1",
        remote?: true,
        supports_host_paths?: false
      )

      result = nil
      expect {
        result = described_class.compatibility_for(agent_run: agent_run, backend: remote_backend, worktree_path: worktree_path)
      }.not_to raise_error

      expect(result.compatible).to be(false)
      expect(result.error_message).to include("requires_host_bind_mount")
    end
  end

  describe "#auth_source_log_payload (RDR-041 #2959)" do
    let(:service) { described_class.new(agent_run: agent_run, project: project) }

    it "returns an empty hash when no auth_source is supplied" do
      expect(service.send(:auth_source_log_payload, nil)).to eq({})
      expect(service.send(:auth_source_log_payload, "")).to eq({})
    end

    it "stringifies the auth_source into the log payload" do
      expect(service.send(:auth_source_log_payload, RunnerAuthAttempt::AUTH_SOURCE_MANAGED))
        .to eq(auth_source: "managed")
      expect(service.send(:auth_source_log_payload, RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED))
        .to eq(auth_source: "host_forwarded")
      expect(service.send(:auth_source_log_payload, RunnerAuthAttempt::AUTH_SOURCE_API_KEY_PROXY))
        .to eq(auth_source: "api_key_proxy")
    end
  end

  # @spec EGRESS-POLICY-007
  describe "#egress_no_proxy_hosts" do
    let(:egress_service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path, egress_gateway_url: "egress-gateway:3128") }

    it "always bypasses the gateway/proxy hosts and the Docker-internal wildcard" do
      expect(egress_service.send(:egress_no_proxy_hosts)).to include(
        "localhost", "127.0.0.1", "paid-proxy", "egress-gateway", "*.internal"
      )
    end

    it "exempts this run's service-container runtime aliases so local service traffic bypasses the gateway" do
      selenium = create(:service_container, :running, :selenium, account: project.account)
      agent_run.update!(service_container_ids: [ selenium.id ])

      expect(egress_service.send(:egress_no_proxy_hosts)).to include(Containers::ServiceRuntimeNaming.runtime_name(selenium))
    end

    it "does not query service containers when the run has none provisioned" do
      expect(ServiceContainer).not_to receive(:where)

      egress_service.send(:egress_no_proxy_hosts)
    end
  end

  # @spec EGRESS-POLICY-007
  describe "#apply_egress_proxy_environment?" do
    it "applies gateway proxy vars for gateway-enforced restricted policies" do
      service = described_class.new(
        agent_run: agent_run,
        worktree_path: worktree_path,
        egress_gateway_url: "egress-gateway:3128",
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_restricted
      )

      expect(service.send(:apply_egress_proxy_environment?)).to be(true)
    end

    it "skips gateway proxy vars for :no_outbound" do
      service = described_class.new(
        agent_run: agent_run,
        worktree_path: worktree_path,
        egress_gateway_url: "egress-gateway:3128",
        networking_policy: ExecutionRunners::NetworkingPolicy.no_outbound
      )

      expect(service.send(:apply_egress_proxy_environment?)).to be(false)
    end

    it "skips gateway proxy vars for :proxy_only" do
      service = described_class.new(
        agent_run: agent_run,
        worktree_path: worktree_path,
        egress_gateway_url: "egress-gateway:3128",
        networking_policy: ExecutionRunners::NetworkingPolicy.proxy_only
      )

      expect(service.send(:apply_egress_proxy_environment?)).to be(false)
    end
  end

  describe "#initialize" do
    it "stores agent_run and worktree_path" do
      expect(service.agent_run).to eq(agent_run)
      expect(service.worktree_path).to eq(worktree_path)
    end

    it "merges default options with provided options" do
      custom_service = described_class.new(
        agent_run: agent_run,
        worktree_path: worktree_path,
        memory_bytes: 1024 * 1024 * 1024
      )

      expect(custom_service.options[:memory_bytes]).to eq(1024 * 1024 * 1024)
      expect(custom_service.options[:cpu_quota]).to eq(200_000)
    end

    it "defaults to the base image for a project with no detected runtime" do
      expect(service.options[:image]).to eq(Containers::ImageResolver::BASE_IMAGE)
    end

    it "resolves a project-specific combo image from the language profile" do
      project.update!(primary_language: "Go")

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:image]).to eq("paid-agent:go")
    end

    it "resolves a polyglot combo image from the language profile" do
      project.update!(repo_profile: { "languages" => %w[Elixir JavaScript Ruby] })

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:image]).to eq("paid-agent:elixir-node-ruby")
    end

    it "fails loudly when the project's runtime is unsupported" do
      project.update!(repo_profile: { "test_languages" => %w[Kotlin Ruby] })

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect {
        svc.options[:image]
      }.to raise_error(Containers::ImageResolver::UnsupportedRuntimeError, /kotlin/)
    end

    it "lets an explicit image override override the resolved project image" do
      project.update!(primary_language: "Go")

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path, image: "custom:latest")

      expect(svc.options[:image]).to eq("custom:latest")
    end

    it "records immutable runtime image metadata for production selections" do
      provision_project = build_stubbed(:project)
      provision_run = build_stubbed(:agent_run, project: provision_project)
      selection_metadata = runtime_image_selection_metadata

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      allow(Containers::RuntimeImageSelector).to receive(:select).and_return(
        instance_double(
          Containers::RuntimeImageSelector::Result,
          image: "ghcr.io/acme/paid-agent@sha256:#{'1' * 64}",
          metadata: selection_metadata
        )
      )
      expect(provision_run).to receive(:record_runtime_image_selection!).with(hash_including(selection_metadata))

      svc = described_class.new(agent_run: provision_run, worktree_path: worktree_path)
      allow(svc).to receive(:resolve_user_setting_overrides).and_return({})

      expect(svc.options[:image]).to eq("ghcr.io/acme/paid-agent@sha256:#{'1' * 64}")
    end

    it "reuses the warm-time selection persisted on a claimed pool entry instead of re-resolving" do
      # @spec IMMUTABLE-IMAGE-002
      # Materialize records while the environment is still test so their
      # Turbo broadcasts use the test cable adapter.
      agent_run
      warm_metadata = runtime_image_selection_metadata(digest: "a" * 64)
      pool_entry = create(
        :container_pool_entry,
        :claimed,
        project: project,
        agent_run: agent_run,
        runtime_image_metadata: warm_metadata
      )
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      # The catalog default may have moved (or have nothing configured) between
      # warm and claim; the claimed container runs the warm-time digest.
      allow(Containers::RuntimeImageSelector).to receive(:select)
        .and_raise(Containers::RuntimeImageCatalog::UnknownProfileError, "catalog must not be consulted")

      svc = described_class.new(agent_run: agent_run, project: project, pool_entry: pool_entry)

      expect(svc.options[:image]).to eq("ghcr.io/acme/paid-agent@sha256:#{'a' * 64}")
      expect(agent_run.reload.runtime_image_selection).to eq(warm_metadata)
      expect(Containers::RuntimeImageSelector).not_to have_received(:select)
    end

    it "reuses the recorded runtime image selection on a non-pool reconnect instead of re-resolving" do
      # @spec IMMUTABLE-IMAGE-002
      # A Temporal retry/worker failover reconnects to an already-provisioned
      # container through Containers::Provision.reconnect (no pool_entry).
      # Re-resolving #options against the catalog would overwrite the
      # recorded provenance with a digest the running container does not use.
      agent_run.record_runtime_image_selection!(runtime_image_selection_metadata(digest: "b" * 64))
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      # The catalog default may have moved since the original provision.
      allow(Containers::RuntimeImageSelector).to receive(:select)
        .and_raise(Containers::RuntimeImageCatalog::UnknownProfileError, "catalog must not be consulted")

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:image]).to eq("ghcr.io/acme/paid-agent@sha256:#{'b' * 64}")
      expect(agent_run.reload.runtime_image_selection).to include("digest" => "sha256:#{'b' * 64}")
      expect(Containers::RuntimeImageSelector).not_to have_received(:select)
    end

    it "applies container_memory_bytes from user settings" do
      create(:user_setting, user: project.created_by, container_memory_bytes: 2 * 1024 * 1024 * 1024)

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(2 * 1024 * 1024 * 1024)
    end

    it "applies the auto memory limit from a learned profile when auto mode is on" do
      settings = create(:user_setting,
        user: project.created_by,
        container_memory_limit_mode: UserSetting::CONTAINER_MEMORY_LIMIT_MODE_AUTO,
        container_memory_bytes: 6 * 1024 * 1024 * 1024,
        container_memory_auto_floor_bytes: 512.megabytes,
        container_memory_auto_ceiling_bytes: 16.gigabytes
      )
      create(:agent_run_resource_profile,
        project: project,
        account: project.account,
        profile_level: "specific",
        runner_key: agent_run.resource_profile_runner_key,
        goal: agent_run.goal,
        sample_count: 5,
        recommended_memory_limit_bytes: 3 * 1024 * 1024 * 1024
      )

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(3 * 1024 * 1024 * 1024)
      expect(settings.reload.container_memory_limit_mode).to eq(UserSetting::CONTAINER_MEMORY_LIMIT_MODE_AUTO)
    end

    it "falls back to container_memory_bytes when auto mode has no profile" do
      create(:user_setting,
        user: project.created_by,
        container_memory_limit_mode: UserSetting::CONTAINER_MEMORY_LIMIT_MODE_AUTO,
        container_memory_bytes: 2 * 1024 * 1024 * 1024
      )

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(2 * 1024 * 1024 * 1024)
    end

    it "does not clamp the manual fallback to the auto ceiling when no profile exists" do
      # A user who raised container_memory_bytes above the default 16 GB auto
      # ceiling and then flips to auto mode should not silently get a smaller
      # container on the next provision before any profile has been learned.
      # The floor/ceiling band constrains learned recommendations only.
      create(:user_setting,
        user: project.created_by,
        container_memory_limit_mode: UserSetting::CONTAINER_MEMORY_LIMIT_MODE_AUTO,
        container_memory_bytes: 20 * 1024 * 1024 * 1024,
        container_memory_auto_floor_bytes: 512.megabytes,
        container_memory_auto_ceiling_bytes: 16.gigabytes
      )

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(20 * 1024 * 1024 * 1024)
    end

    it "clamps the auto memory limit between the user-configured floor and ceiling" do
      create(:user_setting,
        user: project.created_by,
        container_memory_limit_mode: UserSetting::CONTAINER_MEMORY_LIMIT_MODE_AUTO,
        container_memory_bytes: 6 * 1024 * 1024 * 1024,
        container_memory_auto_floor_bytes: 1.gigabyte,
        container_memory_auto_ceiling_bytes: 2.gigabytes
      )
      create(:agent_run_resource_profile,
        project: project,
        account: project.account,
        profile_level: "specific",
        runner_key: agent_run.resource_profile_runner_key,
        goal: agent_run.goal,
        sample_count: 5,
        recommended_memory_limit_bytes: 5 * 1024 * 1024 * 1024
      )

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(2.gigabytes)
    end

    it "prefers caller-supplied memory_bytes over user settings" do
      create(:user_setting, user: project.created_by, container_memory_bytes: 2 * 1024 * 1024 * 1024)

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path, memory_bytes: 1024 * 1024 * 1024)

      expect(svc.options[:memory_bytes]).to eq(1024 * 1024 * 1024)
    end

    it "uses default values when no custom settings are configured" do
      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(4 * 1024 * 1024 * 1024)
    end

    it "allows credential maintenance initialization without agent_run or project" do
      svc = described_class.new(credential_maintenance: true)

      expect(svc.project).to be_nil
      expect(svc.agent_run).to be_nil
      expect(svc.options[:memory_bytes]).to eq(4 * 1024 * 1024 * 1024)
    end
  end

  describe ".reconnect" do
    let(:container_id) { "claimed-pool-container" }

    before do
      allow(Docker::Container).to receive(:get).with(container_id).and_return(mock_container)
    end

    it "recovers claimed pool context when pool metadata is not supplied" do
      entry = create(
        :container_pool_entry,
        :claimed,
        agent_run: agent_run,
        container_id: container_id,
        workspace_volume: "paid-pool-workspace-recovered"
      )

      reconnected = described_class.reconnect(agent_run: agent_run, container_id: container_id)

      expect(reconnected.pool_entry).to eq(entry)
      expect(reconnected.workspace_volume).to eq(entry.workspace_volume)
    end

    it "cleans up the recovered pool workspace volume" do
      entry = create(:container_pool_entry, :claimed, agent_run: agent_run, container_id: container_id)
      pool_volume = instance_double(Docker::Volume, remove: true)
      allow(Docker::Volume).to receive(:get).with(entry.workspace_volume).and_return(pool_volume)

      reconnected = described_class.reconnect(agent_run: agent_run, container_id: container_id)
      reconnected.cleanup(force: true)

      expect(Docker::Volume).to have_received(:get).with(entry.workspace_volume)
      expect(Docker::Volume).not_to have_received(:get).with("paid-workspace-#{agent_run.id}")
    end

    it "uses the resolved backend for later lifecycle calls after reconnect" do
      agent_run.update!(container_host: "remote")
      remote_volume = instance_double(Docker::Volume, remove: true)
      remote_backend = instance_double(
        Containers::Backends::Base,
        get_container: mock_container,
        stop_container: true,
        delete_container: true,
        get_volume: remote_volume,
        delete_volume: true
      )
      allow(Containers).to receive(:backend_for).with("remote").and_return(remote_backend)

      reconnected = described_class.reconnect(agent_run: agent_run, container_id: container_id, pool_entry: nil)
      reconnected.cleanup(force: true)

      expect(Containers).to have_received(:backend_for).with("remote")
      expect(remote_backend).to have_received(:get_container).with(container_id)
      expect(remote_backend).to have_received(:stop_container).with(mock_container, timeout: 0)
      expect(remote_backend).to have_received(:delete_container).with(mock_container, force: true, v: true)
      expect(remote_backend).to have_received(:get_volume).with("paid-workspace-#{agent_run.id}", host: "remote")
      expect(remote_backend).to have_received(:delete_volume).with(remote_volume)
    end
  end

  describe ".ensure_network!" do
    it "delegates to NetworkPolicy.ensure_network! so the network is created when missing" do
      backend = instance_double(Containers::Backends::Base)
      network = instance_double(Docker::Network)

      expect(NetworkPolicy).to receive(:ensure_network!)
        .with(network: NetworkPolicy::NETWORK_NAME, backend: backend)
        .and_return(network)

      expect(described_class.ensure_network!(network: NetworkPolicy::NETWORK_NAME, backend: backend))
        .to eq(network)
    end
  end

  describe "#provision" do
    context "when successful" do
      it "creates and starts a container" do
        expect(Docker::Container).to receive(:create).and_return(mock_container)
        expect(mock_container).to receive(:start)

        result = service.provision

        expect(result).to be_success
        expect(result[:container_id]).to eq("abc123container")
      end

      it "mounts a tmpfs heartbeat directory when the backend lacks host path support" do
        config = nil
        backend = build_remote_backend_without_host_paths(mock_container) do |given_config|
          config = given_config
          mock_container
        end
        provision = described_class.new(agent_run: agent_run, worktree_path: nil, backend: backend)

        stub_provision_steps(provision)
        allow(provision).to receive(:prepare_heartbeat_dir!)

        result = provision.provision

        expect(result).to be_success
        expect(provision).not_to have_received(:prepare_heartbeat_dir!)
        expect(config.dig("HostConfig", "Tmpfs")).to include(
          described_class::HEARTBEAT_MOUNT_POINT => "size=1048576,mode=0777"
        )
        expect(config.dig("HostConfig", "Binds").grep(/#{Regexp.escape(described_class::HEARTBEAT_MOUNT_POINT)}/)).to be_empty
        expect(backend).to have_received(:start_container).with(mock_container)
      end

      it "logs the provision start and success" do
        expect(agent_run).to receive(:log!).with("system", "container.provision.start",
          metadata: hash_including(image: "paid-agent:latest", backend: "local")).ordered
        expect(agent_run).to receive(:log!).with("system", "container.heartbeat_dir_prepared",
          metadata: hash_including(:path)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.network.ready",
          metadata: hash_including(network: NetworkPolicy::NETWORK_NAME)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.ownership_batch_fixed",
          metadata: hash_including(dirs_count: 13)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.codex_config_seeded",
          metadata: hash_including(auth_source: "api_key_proxy")).ordered
        expect(agent_run).to receive(:log!).with("system", "container.firewall.applied",
          metadata: hash_including(container_id: "abc123container")).ordered
        expect(agent_run).to receive(:log!).with("system", "container.provision.success",
          metadata: hash_including(container_id: "abc123container")).ordered

        service.provision
      end

      # @spec EXECUTION-AUDIT-004
      # @spec EXECUTION-AUDIT-005
      it "records image and provision audit events without duplicating grant events" do
        service.provision

        event_names = ExecutionAuditEvent.for_agent_run(agent_run)
          .recent
          .limit(3)
          .pluck(:event_name)

        expect(event_names).to contain_exactly(
          "execution.image_resolved",
          "execution.resource_provision_requested",
          "execution.resource_provisioned"
        )
      end

      it "skips OpenCode database seeding when the run does not resolve to opencode" do
        service.provision

        expect(mock_container).not_to have_received(:exec).with(
          [ "sh", "-c", include("/opt/opencode-seed") ],
          user: "root"
        )
      end

      it "batches all ownership fixes into a single exec call" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-c", satisfy { |script|
            script.include?("chown -R agent:agent") &&
              script.include?("/home/agent/.cache") &&
              script.include?("/home/agent/.gemini") &&
              script.include?("/home/agent/.cursor-agent") &&
              script.include?("/home/agent/.config/omp") &&
              script.include?("chown agent:agent /home/agent/.codex")
          } ],
          user: "root"
        )
      end

      it "falls back to individual ownership fixes when batch fails" do
        # First exec (batched ownership script) raises, triggering fallback
        exec_count = 0
        allow(mock_container).to receive(:exec) do |cmd, **_opts|
          exec_count += 1
          if exec_count == 1 && cmd.is_a?(Array) && cmd[0] == "sh" && cmd[1] == "-c"
            raise Docker::Error::DockerError, "batch failed"
          end
        end

        expect(service).to receive(:fix_ownership_individually!).and_call_original

        service.provision
      end

      it "configures container with security hardening" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["ReadonlyRootfs"]).to be true
          expect(config["CapDrop"]).to eq([ "ALL" ])
          expect(config["CapAdd"]).to eq([ "NET_RAW" ])
          expect(config["SecurityOpt"]).to eq([ "no-new-privileges:true" ])
          expect(config["User"]).to eq("agent")
          mock_container
        end

        service.provision
      end

      it "configures resource limits" do
        expect(Docker::Container).to receive(:create) do |config|
          host_config = config["HostConfig"]
          expect(host_config["Memory"]).to eq(4 * 1024 * 1024 * 1024)
          expect(host_config["MemorySwap"]).to eq(4 * 1024 * 1024 * 1024)
          expect(host_config["CpuPeriod"]).to eq(100_000)
          expect(host_config["CpuQuota"]).to eq(200_000)
          expect(host_config["PidsLimit"]).to eq(500)
          mock_container
        end

        service.provision
      end

      it "configures tmpfs mounts using DEFAULTS sizes" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs["/tmp"]).to eq("exec,size=#{1024 * 1024 * 1024},mode=1777")
          expect(tmpfs["/home/agent/.cache"]).to eq("exec,size=#{512 * 1024 * 1024},mode=0755")
          expect(tmpfs["/home/agent/.codex"]).to eq("size=#{256 * 1024 * 1024},mode=0700")
          mock_container
        end

        service.provision
      end

      # Regression: Docker's default tmpfs flags include noexec, which makes
      # mkmf's File.executable? check fail when bundle install builds native
      # gem extensions in /tmp — surfacing as a misleading "compiler failed
      # to generate an executable file" error (e.g. bigdecimal extconf).
      # Agent containers default Bundler to /tmp/bundle and the
      # coding/review/rebase flows all run bundle install early.
      it "mounts /tmp tmpfs with exec so bundle install can build native gems" do
        expect(Docker::Container).to receive(:create) do |config|
          tmp_options = config.dig("HostConfig", "Tmpfs", "/tmp")
          expect(tmp_options.split(",")).to include("exec")
          mock_container
        end

        service.provision
      end

      it "mounts /home/agent/.cache tmpfs with exec so native addons can be loaded" do
        expect(Docker::Container).to receive(:create) do |config|
          tmp_options = config.dig("HostConfig", "Tmpfs", "/home/agent/.cache")
          expect(tmp_options.split(",")).to include("exec")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for Codex CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.codex")
          expect(tmpfs["/home/agent/.codex"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.codex"]).to include("size=#{256 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "allows the Codex tmpfs size to be overridden" do
        service = described_class.new(
          agent_run: agent_run,
          worktree_path: worktree_path,
          tmpfs_codex_size: 384 * 1024 * 1024
        )

        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs["/home/agent/.codex"]).to eq("size=#{384 * 1024 * 1024},mode=0700")
          mock_container
        end

        service.provision
      end

      it "seeds Codex with a proxy-backed config file" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [
            "sh",
            "-lc",
            satisfy { |cmd| cmd.include?("/home/agent/.codex/config.toml") && decoded_base64_content(cmd).include?('model_provider = "paid"') }
          ],
          user: "agent"
        )
      end

      it "pins a Paid-selected top-level model so Codex does not default to an unsupported model" do
        create(:llm_model, :openai, model_id: "gpt-5.1", tier: "mid", capability_score: 9.0)

        service.provision

        expect(mock_container).to have_received(:exec).with(
          [
            "sh",
            "-lc",
            satisfy { |cmd|
              decoded = decoded_base64_content(cmd)
              cmd.include?("/home/agent/.codex/config.toml") &&
                decoded.include?('model = "gpt-5.1"') &&
                decoded.include?("[chatgpt]") &&
                decoded.index('model = "gpt-5.1"') < decoded.index("[chatgpt]")
            }
          ],
          user: "agent"
        )
      end

      it "seeds Codex config with the current notify command shape" do
        service.provision
        notify_line = described_class.codex_notify_line

        expect(mock_container).to have_received(:exec).with(
          [
            "sh",
            "-lc",
            satisfy { |cmd|
              decoded = decoded_base64_content(cmd)
              cmd.include?("/home/agent/.codex/config.toml") &&
                decoded.include?(notify_line) &&
                decoded.include?("[chatgpt]") &&
                decoded.index(notify_line) < decoded.index("[chatgpt]")
            }
          ],
          user: "agent"
        )
      end

      it "does not mount host subscription auth directories by default" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds.none? { |bind| bind.include?("/home/agent/.claude-host:ro") }).to be true
          expect(binds.none? { |bind| bind.include?("/home/agent/.codex-host:ro") }).to be true
          expect(binds.none? { |bind| bind.include?("/home/agent/.gemini-host:ro") }).to be true
          expect(binds.none? { |bind| bind.include?("/home/agent/.copilot-host:ro") }).to be true
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for Cursor agent CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.cursor-agent")
          expect(tmpfs["/home/agent/.cursor-agent"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.cursor-agent"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for Gemini CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.gemini")
          expect(tmpfs["/home/agent/.gemini"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.gemini"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for OpenCode CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.config/opencode")
          expect(tmpfs["/home/agent/.config/opencode"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.config/opencode"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for OpenCode CLI data" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.local/share/opencode")
          expect(tmpfs["/home/agent/.local/share/opencode"]).to include("mode=0700")
          # @spec CONTAINER-RUNTIME-029
          expect(tmpfs["/home/agent/.local/share/opencode"]).to include("size=#{256 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      # @spec SUBSCRIPTION-RUNNER-AUTH-005
      it "configures a writable tmpfs for OMP CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.config/omp")
          expect(tmpfs["/home/agent/.config/omp"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.config/omp"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      # @spec SUBSCRIPTION-RUNNER-AUTH-005
      it "configures a writable tmpfs for OMP CLI data" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.local/share/omp")
          expect(tmpfs["/home/agent/.local/share/omp"]).to include("mode=0700")
          # OMP shares the OpenCode SQLite/state layout so it gets the same
          # 256MB cap as OpenCode (CONTAINER-RUNTIME-029 rationale).
          expect(tmpfs["/home/agent/.local/share/omp"]).to include("size=#{256 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for Kilocode CLI data" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.local/share/kilo")
          expect(tmpfs["/home/agent/.local/share/kilo"]).to include("mode=0700")
          # @spec CONTAINER-RUNTIME-029 — Kilocode is an OpenCode fork with the
          # same SQLite/WAL state layout and the identical ENOSPC failure.
          expect(tmpfs["/home/agent/.local/share/kilo"]).to include("size=#{256 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for GitHub Copilot CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.copilot")
          expect(tmpfs["/home/agent/.copilot"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.copilot"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures worktree volume mount" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("#{worktree_path}:/workspace:rw")
          mock_container
        end

        service.provision
      end

      # @spec CONTAINER-RUNTIME-001
      it "creates a Docker volume instead of bind-mounting when worktree_path is the container mount point" do
        container_internal_service = described_class.new(
          agent_run: agent_run,
          worktree_path: "/workspace"
        )

        expect(Docker::Volume).to receive(:create).with("paid-workspace-#{agent_run.id}", anything).and_return(mock_volume)
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).not_to include("/workspace:/workspace:rw")
          expect(binds).to include("paid-workspace-#{agent_run.id}:/workspace:rw")
          mock_container
        end

        container_internal_service.provision
      end

      it "configures environment variables for proxy access" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include(
            "PAID_PROXY_URL=http://paid-proxy:3000",
            "KNOWLEDGE_SEARCH_URL=http://paid-proxy:3000/api/proxy/knowledge/search",
            "PROJECT_ID=#{project.id}", "AGENT_RUN_ID=#{agent_run.id}",
            "ANTHROPIC_BASE_URL=http://paid-proxy:3000/api/proxy/anthropic",
            "OPENAI_BASE_URL=http://paid-proxy:3000/api/proxy/openai",
            "ANTHROPIC_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
            "OPENAI_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
            "ANTHROPIC_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
            "OPENAI_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
            "OPENAI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}",
            "PAID_CLAUDE_SUBSCRIPTION_AUTH=0", "PAID_CODEX_SUBSCRIPTION_AUTH=0",
            "PAID_GEMINI_SUBSCRIPTION_AUTH=0", "PAID_COPILOT_SUBSCRIPTION_AUTH=0"
          )
          mock_container
        end

        service.provision
      end

      it "sets writable Bundler and Yarn cache paths for all agent containers" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("BUNDLE_PATH=/tmp/bundle")
          expect(env).to include("BUNDLE_APP_CONFIG=/tmp/bundle-config")
          expect(env).to include("YARN_CACHE_FOLDER=/workspace/.yarn-cache")
          mock_container
        end

        service.provision
      end

      it "writes preview tunnel client config when preview metadata is provided" do
        preview_service = build_preview_tunnel_service(agent_run:, worktree_path:)
        allow(Containers::ProxyUrl).to receive(:resolve).with(backend: preview_service.backend, restricted: true).and_return("http://paid-proxy:3000")
        expect(Docker::Container).to receive(:create) do |config|
          expect_preview_tunnel_container_config(config)
          mock_container
        end
        allow(mock_container).to receive(:exec).and_return([ [], [], 0 ])
        allow(preview_service).to receive(:write_container_file).and_call_original
        preview_service.provision
        expect(preview_service).to have_received(:write_container_file).with(
          "/home/agent/.paid-preview/rathole-client.toml",
          include('[client.services.preview-preview-token]', 'local_addr = "127.0.0.1:4000"')
        )
        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", "rathole --client /home/agent/.paid-preview/rathole-client.toml > /tmp/paid-preview-tunnel-client.log 2>&1 &" ],
          user: "agent"
        )
      end

      it "defers preview tunnel client setup until the app port is known" do
        preview_service = build_preview_tunnel_service(agent_run:, worktree_path:, app_port: nil)
        allow(Containers::ProxyUrl).to receive(:resolve).with(backend: preview_service.backend, restricted: true).and_return("http://paid-proxy:3000")
        allow(mock_container).to receive(:exec).and_return([ [], [], 0 ])
        allow(preview_service).to receive(:write_container_file).and_call_original

        preview_service.provision

        expect(preview_service).not_to have_received(:write_container_file)
          .with("/home/agent/.paid-preview/rathole-client.toml", anything)

        preview_service.activate_preview_tunnel!(app_port: 4100)

        expect(preview_service).to have_received(:write_container_file).with(
          "/home/agent/.paid-preview/rathole-client.toml",
          include('[client.services.preview-preview-token]', 'local_addr = "127.0.0.1:4100"')
        )
      end

      it "allows the preview tunnel server destination through the restricted firewall" do
        preview_service = build_preview_tunnel_service(agent_run:, worktree_path:)
        allow(Containers::ProxyUrl).to receive(:resolve).with(backend: preview_service.backend, restricted: true).and_return("http://paid-proxy:3000")

        expect(NetworkPolicy).to receive(:apply_firewall_rules).with(
          mock_container,
          service_destinations: [ { ip: "paid-proxy", port: 7000 } ],
          backend: preview_service.backend
        )

        preview_service.provision
      end

      it "sets git committer identity environment variables" do
        bot_identity = Github::BotIdentity.new(
          app_slug: "paid-agents",
          name: "Paid Agent",
          email: "agent@paid-agents.com"
        )
        allow(Github::BotIdentity).to receive(:for_git).and_return(bot_identity)

        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("GIT_AUTHOR_NAME=Paid Agent")
          expect(env).to include("GIT_AUTHOR_EMAIL=agent@paid-agents.com")
          expect(env).to include("GIT_COMMITTER_NAME=Paid Agent")
          expect(env).to include("GIT_COMMITTER_EMAIL=agent@paid-agents.com")
          mock_container
        end

        service.provision
      end

      it "configures Google proxy environment variables" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("GOOGLE_GEMINI_BASE_URL=http://paid-proxy:3000/api/proxy/google")
          expect(env).to include("GOOGLE_GENAI_BASE_URL=http://paid-proxy:3000/api/proxy/google")
          expect(env).to include("GOOGLE_HEADER_X_AGENT_RUN_ID=#{agent_run.id}")
          expect(env).to include("GOOGLE_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}")
          expect(env).to include("GEMINI_CLI_CUSTOM_HEADERS=X-Agent-Run-Id: #{agent_run.id}, X-Proxy-Token: #{agent_run.proxy_token}")
          expect(env).to include("GEMINI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}")
          mock_container
        end

        service.provision
      end

      it "uses PAID_PROXY_EXTERNAL_URL when a remote backend is active" do
        remote_backend = stub_remote_backend_proxy_support(
          mock_network: mock_network,
          mock_volume: mock_volume,
          mock_container: mock_container
        )

        original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
        ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"

        remote_service = described_class.new(agent_run: agent_run, backend: remote_backend)

        expect(remote_backend).to receive(:create_container) do |config|
          expect_remote_proxy_env(config["Env"], "https://proxy.example.test:3443")
          mock_container
        end

        remote_service.provision
      ensure
        ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
      end

      it "prefers a per-host PAID_PROXY_EXTERNAL_URL when a remote backend is active" do
        remote_backend = stub_remote_backend_proxy_support(
          mock_network: mock_network,
          mock_volume: mock_volume,
          mock_container: mock_container
        )

        original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
        original_host_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1"]
        ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
        ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1"] = "https://worker-1-proxy.example.test:3443"

        remote_service = described_class.new(agent_run: agent_run, backend: remote_backend)

        expect(remote_backend).to receive(:create_container) do |config|
          expect_remote_proxy_env(config["Env"], "https://worker-1-proxy.example.test:3443")
          mock_container
        end

        remote_service.provision
      ensure
        ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
        ENV["PAID_PROXY_EXTERNAL_URL_WORKER_1"] = original_host_proxy_external_url
      end

      it "includes runner CLI env overrides from agent-harness" do
        gemini_runner = instance_double(
          AgentHarness::Providers::Gemini,
          cli_env_overrides: { "GEMINI_SANDBOX" => "false", "GEMINI_CLI_DISABLE_RETRIES" => "true" }
        )
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:gemini).and_return(gemini_runner)

        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("GEMINI_SANDBOX=false")
          expect(env).to include("GEMINI_CLI_DISABLE_RETRIES=true")
          mock_container
        end

        service.provision
      end

      it "does not let harness cli_env_overrides clobber app-managed subscription auth" do
        codex_runner = instance_double(
          AgentHarness::Providers::Codex,
          cli_env_overrides: { "PAID_CODEX_SUBSCRIPTION_AUTH" => "1" },
          config_file_content: "model_provider = \"paid\"\n",
          auth_lock_config: { path: "/tmp/codex-auth.lock" }
        )
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:codex).and_return(codex_runner)

        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          # App sets PAID_CODEX_SUBSCRIPTION_AUTH=0 (no subscription); harness
          # defaults to 1, but the app value must win.
          auth_entries = env.select { |e| e.start_with?("PAID_CODEX_SUBSCRIPTION_AUTH=") }
          expect(auth_entries).to eq([ "PAID_CODEX_SUBSCRIPTION_AUTH=0" ])
          mock_container
        end

        service.provision
      end

      it "raises when a known runner is missing from agent-harness" do
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:gemini).and_raise(KeyError, "missing gemini")

        expect { service.provision }.to raise_error(KeyError, /missing gemini/)
      end

      it "raises when runner CLI env overrides are misconfigured in agent-harness" do
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:gemini)
          .and_raise(AgentHarness::ConfigurationError, "broken gemini")

        expect { service.provision }
          .to raise_error(AgentHarness::ConfigurationError, /broken gemini/)
      end

      it "does not include real upstream API keys in environment variables" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("GEMINI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}")
          expect(env).to include("OPENAI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}")
          expect(env.none? { |e| e.start_with?("GOOGLE_API_KEY=") }).to be true
          expect(env.none? { |e| e.start_with?("ANTHROPIC_API_KEY=") }).to be true
          mock_container
        end

        service.provision
      end

      it "adds labels for tracking" do
        expect(Docker::Container).to receive(:create) do |config|
          labels = config["Labels"]
          expect(labels["paid.agent_run_id"]).to eq(agent_run.id.to_s)
          expect(labels["paid.project_id"]).to eq(project.id.to_s)
          mock_container
        end

        service.provision
      end

      it "stores container reference" do
        service.provision

        expect(service.container).to eq(mock_container)
      end
    end

    context "when worktree path is not provided" do
      it "creates workspace volume for nil path" do
        # RDR-058: the workspace volume is named after this run's own
        # agent_run.id, never shared with another run.
        # @spec EXECUTION-ISOLATION-001
        service = described_class.new(agent_run: agent_run)

        result = service.provision

        expect(result).to be_success
        expect(service.workspace_volume).to eq("paid-workspace-#{agent_run.id}")
      end

      it "labels created workspace volumes for paid ownership" do
        service = described_class.new(agent_run: agent_run)

        service.provision

        expect(Docker::Volume).to have_received(:create).with(
          "paid-workspace-#{agent_run.id}",
          {
            "Labels" => {
              "paid.managed" => "true",
              "paid.resource" => "workspace_volume",
              "paid.agent_run_id" => agent_run.id.to_s,
              "paid.project_id" => project.id.to_s
            }
          }
        )
      end

      it "preserves the workspace-volume resource kind when ownership labels are merged" do
        service = described_class.new(
          agent_run: agent_run,
          ownership_labels: {
            "paid.resource" => "container",
            "paid.environment" => "test"
          }
        )

        service.provision

        expect(Docker::Volume).to have_received(:create).with(
          "paid-workspace-#{agent_run.id}",
          hash_including(
            "Labels" => hash_including(
              "paid.resource" => "workspace_volume",
              "paid.environment" => "test"
            )
          )
        )
      end

      it "creates workspace volume for blank path" do
        service = described_class.new(agent_run: agent_run, worktree_path: "")

        result = service.provision

        expect(result).to be_success
        expect(service.workspace_volume).to eq("paid-workspace-#{agent_run.id}")
      end

      it "reuses existing volume idempotently" do
        allow(Docker::Volume).to receive(:get).with("paid-workspace-#{agent_run.id}").and_return(mock_volume)
        service = described_class.new(agent_run: agent_run)

        service.provision

        expect(Docker::Volume).not_to have_received(:create)
      end

      it "mounts workspace volume in container binds" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("paid-workspace-#{agent_run.id}:/workspace:rw")
          mock_container
        end

        described_class.new(agent_run: agent_run).provision
      end

      it "keeps enhance_issue workspace volume writable so clone can populate the review workspace" do
        enhance_run = create(:agent_run, :enhance_issue_goal, project: project)

        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("paid-workspace-#{enhance_run.id}:/workspace:rw")
          mock_container
        end

        described_class.new(agent_run: enhance_run).provision
      end

      it "raises ProvisionError for non-existent path" do
        service = described_class.new(agent_run: agent_run, worktree_path: "/nonexistent/path")

        expect { service.provision }.to raise_error(described_class::ProvisionError, /does not exist/)
      end
    end

    context "when Docker fails" do
      before do
        allow(Docker::Container).to receive(:create).and_raise(Docker::Error::ServerError.new("Docker daemon error"))
      end

      it "raises ProvisionError" do
        expect { service.provision }.to raise_error(described_class::ProvisionError, /Docker error/)
      end

      it "logs the failure" do
        allow(agent_run).to receive(:log!)
        expect(agent_run).to receive(:log!).with("system", "container.provision.start",
          metadata: hash_including(image: anything, backend: "local"))
        expect(agent_run).to receive(:log!).with("system", "container.provision.failed",
          metadata: hash_including(error: anything))

        expect { service.provision }.to raise_error(described_class::ProvisionError)
      end

      it "releases preview tunnel reservations when create_container fails before assigning the container" do
        preview_service = build_preview_tunnel_service(agent_run:, worktree_path:)
        PreviewTunnelPortReservation.create!(reservation_key: "preview-token", tunnel_port: 8201)

        expect {
          preview_service.provision
        }.to raise_error(described_class::ProvisionError, /Docker error/)

        expect(PreviewTunnelPortReservation.find_by(reservation_key: "preview-token")).to be_nil
      end
    end

    context "when interrupted with SignalException" do
      # ProvisionContainerActivity escalates to Thread#raise(Interrupt) when its
      # worker thread does not finish within the cancellation grace window.
      # Interrupt inherits from SignalException — NOT StandardError — so the
      # existing rescue clauses would bypass cleanup. The SignalException
      # rescue clause runs cleanup + cleanup_workspace_volume before re-raising
      # so a half-provisioned container and workspace volume are not orphaned.
      it "deletes the half-provisioned container before re-raising Interrupt" do
        stub_provision_steps(service)

        allow(mock_container).to receive(:delete)
        allow(mock_container).to receive(:stop)
        allow(service).to receive(:log_system)
        allow(service).to receive(:cleanup_workspace_volume)

        # Drop into the rescue path immediately after create_container
        # populates @container, mimicking the activity's worker thread being
        # raised into the middle of provision.
        allow(service).to receive(:start_container) do
          raise Interrupt, "canceled"
        end
        allow(Docker::Container).to receive(:create).and_return(mock_container)

        expect {
          service.provision
        }.to raise_error(Interrupt)

        expect(mock_container).to have_received(:delete)
      end

      it "deletes the workspace volume before re-raising Interrupt" do
        # No worktree_path means provision creates a named Docker volume via
        # prepare_workspace! — interrupt mid-flight and verify
        # cleanup_workspace_volume ran (no orphan leaked).
        worktree_vol_service = described_class.new(agent_run: agent_run, worktree_path: nil)

        # Stub only the steps after the interrupt point so prepare_workspace!
        # actually creates the volume (and @workspace_volume is set). The
        # global before already mocks Docker::Volume.create to return
        # mock_volume, so prepare_workspace! seeds @workspace_volume for us.
        allow(worktree_vol_service).to receive(:log_system)
        allow(worktree_vol_service).to receive(:fix_all_ownership!)
        allow(worktree_vol_service).to receive(:seed_opencode_database!)
        allow(worktree_vol_service).to receive(:seed_kilo_database!)
        allow(worktree_vol_service).to receive(:seed_codex_credentials!)
        allow(worktree_vol_service).to receive(:seed_gemini_credentials!)
        allow(worktree_vol_service).to receive(:seed_copilot_credentials!)
        allow(worktree_vol_service).to receive(:seed_claude_credentials!)
        allow(worktree_vol_service).to receive(:apply_network_restrictions!)

        # Override the global Docker::Volume.get mock so it returns the just-
        # created volume (rather than always raising). This simulates the
        # production behaviour where Docker actually returns the volume.
        allow(Docker::Volume).to receive(:get).with("paid-workspace-#{agent_run.id}").and_return(mock_volume)

        allow(worktree_vol_service).to receive(:ensure_network!) do
          raise Interrupt, "canceled"
        end

        expect(mock_volume).to receive(:remove)

        expect {
          worktree_vol_service.provision
        }.to raise_error(Interrupt)
      end
    end

    context "with network integration" do
      it "ensures the agent network exists before provisioning" do
        expect(NetworkPolicy).to receive(:ensure_network!).with(
          network: NetworkPolicy::NETWORK_NAME,
          backend: service.backend
        ).ordered
        expect(Docker::Container).to receive(:create).ordered.and_return(mock_container)

        service.provision
      end

      it "always configures network mode" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "warns and ignores custom :network option" do
        expect(Rails.logger).to receive(:warn).with(
          hash_including(
            message: "container_manager.container.network_option_ignored",
            agent_run_id: agent_run.id
          )
        )

        custom_service = described_class.new(
          agent_run: agent_run,
          worktree_path: worktree_path,
          network: "custom_network"
        )

        expect(custom_service.options).not_to have_key(:network)

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::NETWORK_NAME)
          mock_container
        end

        custom_service.provision
      end

      it "applies firewall rules after container start" do
        expect(mock_container).to receive(:start).ordered
        expect(NetworkPolicy).to receive(:apply_firewall_rules).with(
          mock_container,
          service_destinations: [],
          backend: service.backend
        ).ordered

        service.provision
      end

      it "raises ProvisionError when network creation fails" do
        allow(NetworkPolicy).to receive(:ensure_network!)
          .and_raise(NetworkPolicy::Error, "Failed to create agent network")

        expect { service.provision }.to raise_error(
          described_class::ProvisionError, /Network setup failed/
        )
      end
    end

    context "with networking_policy provided (RDR-054 runner-driven path)" do
      let(:restricted_policy) { ExecutionRunners::NetworkingPolicy.proxy_restricted }
      let(:direct_outbound_policy) { ExecutionRunners::NetworkingPolicy.direct_outbound }
      let(:policy_service) do
        described_class.new(
          agent_run: agent_run, worktree_path: worktree_path, backend: service.backend,
          networking_policy: restricted_policy
        )
      end

      it "uses the policy's restricted? flag to choose the proxy URL" do
        ENV.delete("PAID_PROXY_EXTERNAL_URL")
        allow(Containers::ProxyUrl).to receive(:resolve).and_call_original

        expect(Containers::ProxyUrl).to receive(:resolve)
          .with(backend: policy_service.backend, policy: restricted_policy)
          .and_return("http://paid-proxy:3000")

        expect(policy_service.send(:proxy_base_url)).to eq("http://paid-proxy:3000")
      end

      it "uses the unrestricted policy's allowed host for the proxy URL" do
        ENV.delete("PAID_PROXY_EXTERNAL_URL")
        allow(Containers::ProxyUrl).to receive(:resolve).and_call_original

        unrestricted_service = described_class.new(
          agent_run: agent_run, worktree_path: worktree_path, backend: service.backend,
          networking_policy: direct_outbound_policy
        )

        expect(Containers::ProxyUrl).to receive(:resolve)
          .with(backend: unrestricted_service.backend, policy: direct_outbound_policy)
          .and_return("http://web:3000")

        expect(unrestricted_service.send(:proxy_base_url)).to eq("http://web:3000")
      end

      it "skips NetworkPolicy.ensure_network! during provision when a policy is provided" do
        expect(NetworkPolicy).not_to receive(:ensure_network!)
        allow(Docker::Container).to receive(:create).and_return(mock_container)

        policy_service.provision
      end

      it "skips NetworkPolicy.apply_firewall_rules during provision when a policy is provided" do
        allow(Docker::Container).to receive(:create).and_return(mock_container)

        expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

        policy_service.provision
      end

      it "reports the paid_agent network name for restricted policies" do
        expect(policy_service.network_name).to eq(NetworkPolicy::NETWORK_NAME)
      end

      it "reports the paid_internal network name for unrestricted policies" do
        unrestricted_service = described_class.new(
          agent_run: agent_run, worktree_path: worktree_path, backend: service.backend,
          networking_policy: direct_outbound_policy
        )

        expect(unrestricted_service.network_name).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
      end
    end

    context "with subscription auth (CLAUDE_CONFIG_DIR)" do
      let(:claude_config_dir) { Dir.mktmpdir("claude-config") }

      before do
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(claude_config_dir)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(codex_local_config_path: nil, gemini_local_config_path: nil, copilot_local_config_path: nil)
      end

      after do
        FileUtils.rm_rf(claude_config_dir)
      end

      it "mounts Claude config at staging path and creates writable tmpfs" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("#{claude_config_dir}:/home/agent/.claude-host:ro")

          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.claude")
          expect(tmpfs["/home/agent/.claude"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.claude"]).to include("size=#{256 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "does not set ANTHROPIC_BASE_URL" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env.none? { |e| e.start_with?("ANTHROPIC_BASE_URL=") }).to be true
          mock_container
        end

        service.provision
      end

      it "still sets OpenAI and Google proxy vars for fallback providers" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include(
            "OPENAI_BASE_URL=http://web:3000/api/proxy/openai",
            "OPENAI_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
            "OPENAI_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
            "OPENAI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}",
            "PAID_CLAUDE_SUBSCRIPTION_AUTH=1", "PAID_CODEX_SUBSCRIPTION_AUTH=0",
            "PAID_COPILOT_SUBSCRIPTION_AUTH=0", "PAID_GEMINI_SUBSCRIPTION_AUTH=0",
            "GOOGLE_GEMINI_BASE_URL=http://web:3000/api/proxy/google",
            "GOOGLE_GENAI_BASE_URL=http://web:3000/api/proxy/google",
            "GOOGLE_HEADER_X_AGENT_RUN_ID=#{agent_run.id}",
            "GOOGLE_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}",
            "GEMINI_CLI_CUSTOM_HEADERS=X-Agent-Run-Id: #{agent_run.id}, X-Proxy-Token: #{agent_run.proxy_token}",
            "GEMINI_API_KEY=paid-run:#{agent_run.id}:#{agent_run.proxy_token}"
          )
          mock_container
        end

        service.provision
      end

      it "sets PAID_PROXY_URL using compose service name" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("PAID_PROXY_URL=http://web:3000")
          mock_container
        end

        service.provision
      end

      it "ensures the infrastructure network exists" do
        expect(NetworkPolicy).to receive(:ensure_network!).with(
          network: NetworkPolicy::INFRA_NETWORK_NAME,
          backend: service.backend
        )

        service.provision
      end

      it "skips firewall rules" do
        expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

        service.provision
      end

      it "does not copy settings.json into the container even when present on host" do
        File.write(File.join(claude_config_dir, "settings.json"), '{"model":"claude-sonnet-4-20250514"}')

        service.provision

        exec_calls = []
        expect(mock_container).to have_received(:exec).at_least(:once) do |cmd, **_opts|
          exec_calls << cmd
        end

        copy_commands = exec_calls.select { |cmd| cmd.is_a?(Array) && cmd.last.to_s.include?("cp ") }
        copy_commands.each do |cmd|
          expect(cmd.last).not_to include("settings.json")
        end
      end
    end

    context "with managed Claude credentials json" do
      let!(:managed_credential) do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token",
          token: JSON.generate(
            "claudeAiOauth" => {
              "accessToken" => "managed-access",
              "refreshToken" => "managed-refresh",
              "expiresAt" => 12.hours.from_now.iso8601
            }
          )
        )
      end

      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: nil,
          copilot_local_config_path: nil
        )
      end

      it "treats the managed credentials json as Claude subscription auth without env token injection" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("PAID_CLAUDE_SUBSCRIPTION_AUTH=1")
          expect(env.none? { |entry| entry.start_with?("CLAUDE_CODE_OAUTH_TOKEN=") }).to be(true)
          mock_container
        end

        service.provision
      end

      it "writes the managed credentials json into the container" do
        allow(service).to receive(:write_container_file).and_call_original

        service.provision

        expect(service).to have_received(:write_container_file)
          .with("/home/agent/.claude/.credentials.json", managed_credential.token)
      end
    end

    context "with fallback providers" do
      let(:settings) { project.created_by.settings }
      let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let!(:direct_outbound_runner) do
        create(
          :runner,
          :api_key,
          user: project.created_by,
          runner_key: "opencode",
          provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
        )
      end

      before do
        project.created_by.runners.find_by!(runner_key: "claude").update!(enabled_for_fallback: false)
      end

      it "stays on the restricted network when direct-outbound fallbacks are disabled" do
        settings.update!(fallback_enabled: false, fallback_runners: [])

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network when a fallback requires direct outbound" do
        settings.update!(
          fallback_enabled: true,
          fallback_runners: [ direct_outbound_runner.routing_key ]
        )

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network when kilocode is configured as a fallback" do
        kilocode_runner = create(
          :runner,
          user: project.created_by,
          runner_key: "kilocode",
          enabled_for_agent_runs: false,
          enabled_for_fallback: true
        )
        direct_outbound_runner.update!(enabled_for_fallback: false)

        settings.update!(
          fallback_enabled: true,
          fallback_runners: [ kilocode_runner.routing_key ]
        )

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network when a rate-limit fallback requires direct outbound" do
        settings.update!(fallback_enabled: false, fallback_runners: [])
        direct_outbound_runner.update!(
          enabled_for_agent_runs: false,
          fallback_role: "rate_limit_fallback"
        )

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end
    end

    context "with a direct-outbound default runner" do
      let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let!(:direct_outbound_runner) do
        create(
          :runner,
          :api_key,
          user: project.created_by,
          runner_key: "opencode",
          provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
        )
      end

      it "uses the infrastructure network for project-level provisioning when the default runner is direct outbound" do
        project.created_by.settings.update!(default_agent_runner: direct_outbound_runner.routing_key)

        expect(described_class.new(project: project).network_name).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
      end

      it "uses the infrastructure network when execution falls back from an unrunnable saved runner to a direct-outbound default" do
        copilot_runner = create(:runner, user: project.created_by, runner_key: "copilot")
        agent_run.update!(runner: copilot_runner, agent_type: "copilot")
        project.created_by.settings.update!(default_agent_runner: direct_outbound_runner.routing_key, fallback_enabled: false)
        allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
        allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the restricted network when an unrunnable saved runner has a runnable proxy-mode fallback despite a direct-outbound default" do
        copilot_runner = create(:runner, user: project.created_by, runner_key: "copilot")
        claude_api_key = create(:provider_api_key, user: project.created_by, api_service_type: "anthropic")
        claude_fallback = create(:runner, :api_key, user: project.created_by,
          runner_key: "claude", provider_api_key: claude_api_key)
        allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
        allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

        direct_outbound_runner.update!(enabled_for_fallback: false)
        project.created_by.runners.subscription.find_by!(runner_key: "claude")
          .update!(enabled_for_fallback: false)

        agent_run.update!(runner: copilot_runner, agent_type: "copilot")
        project.created_by.settings.update!(
          default_agent_runner: direct_outbound_runner.routing_key,
          fallback_enabled: true,
          fallback_runners: [ claude_fallback.routing_key ]
        )

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::NETWORK_NAME)
          mock_container
        end

        service.provision
      end
    end

    context "with service-container network alignment (#1282)" do
      let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let!(:direct_outbound_runner) do
        create(
          :runner,
          :api_key,
          user: project.created_by,
          runner_key: "opencode",
          provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
        )
      end

      it "network_for matches agent container network in proxy mode" do
        container_network = nil

        expect(Docker::Container).to receive(:create) do |config|
          container_network = config["HostConfig"]["NetworkMode"]
          mock_container
        end

        service.provision

        service_network = described_class.network_for(agent_run: agent_run)

        expect(service_network).to eq(container_network)
        expect(service_network).to eq(NetworkPolicy::NETWORK_NAME)
      end

      it "network_for matches agent container network in direct-outbound mode" do
        copilot_runner = create(:runner, user: project.created_by, runner_key: "copilot")
        agent_run.update!(runner: copilot_runner, agent_type: "copilot")
        project.created_by.settings.update!(default_agent_runner: direct_outbound_runner.routing_key, fallback_enabled: false)
        allow(RunnerSupport).to receive(:container_executable_runner_key?).and_call_original
        allow(RunnerSupport).to receive(:container_executable_runner_key?).with("copilot").and_return(false)

        container_network = nil

        expect(Docker::Container).to receive(:create) do |config|
          container_network = config["HostConfig"]["NetworkMode"]
          mock_container
        end

        service.provision

        service_network = described_class.network_for(agent_run: agent_run)

        expect(service_network).to eq(container_network)
        expect(service_network).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
      end

      it "network_for matches agent container network in subscription-auth mode" do
        claude_config_dir = Dir.mktmpdir("claude-config")
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")

        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(claude_config_dir)
        %w[CODEX_CONFIG_DIR CODEX_HOME GEMINI_CONFIG_DIR COPILOT_HOME COPILOT_CONFIG_DIR].each do |key|
          allow(ENV).to receive(:[]).with(key).and_return(nil)
        end
        allow(service).to receive_messages(codex_local_config_path: nil, gemini_local_config_path: nil, copilot_local_config_path: nil)

        container_network = nil

        expect(Docker::Container).to receive(:create) do |config|
          container_network = config["HostConfig"]["NetworkMode"]
          mock_container
        end

        service.provision

        service_network = described_class.network_for(agent_run: agent_run)

        expect(service_network).to eq(container_network)
        expect(service_network).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
      ensure
        FileUtils.rm_rf(claude_config_dir)
      end
    end

    context "with Claude managed runner token" do
      let!(:managed_credential) do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token",
          token: "sk-ant-oat01-managed-token"
        )
      end

      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: nil,
          copilot_local_config_path: nil
        )
      end

      it "treats the managed token as Claude subscription auth and injects it into the container env" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include(
            "PAID_CLAUDE_SUBSCRIPTION_AUTH=1",
            "CLAUDE_CODE_OAUTH_TOKEN=#{managed_credential.token}"
          )
          expect(env.none? { |entry| entry.start_with?("ANTHROPIC_BASE_URL=") }).to be(true)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "skips seeding host-forwarded Claude credentials" do
        expect(service).not_to receive(:seed_host_credentials!)
        expect(service).not_to receive(:seed_local_credentials!)

        service.provision
      end
    end

    context "with Gemini subscription auth (GEMINI_CONFIG_DIR)" do
      let(:gemini_config_dir) { Dir.mktmpdir("gemini-config") }

      before do
        File.write(File.join(gemini_config_dir, "oauth_creds.json"), "{}")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(gemini_config_dir)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(claude_local_config_path: nil, codex_local_config_path: nil, copilot_local_config_path: nil)
      end

      after do
        FileUtils.rm_rf(gemini_config_dir)
      end

      it "mounts Gemini config at a staging path and sets the subscription marker" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("#{gemini_config_dir}:/home/agent/.gemini-host:ro")
          env = config["Env"]
          expect(env).to include("PAID_GEMINI_SUBSCRIPTION_AUTH=1")
          expect(env).to include("ANTHROPIC_BASE_URL=http://web:3000/api/proxy/anthropic")
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network and seeds cached Gemini credentials" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-c", include("/home/agent/.gemini-host/oauth_creds.json").and(include("/home/agent/.gemini/oauth_creds.json")) ],
          user: "agent"
        )
      end
    end

    context "with Gemini subscription auth from the devcontainer filesystem" do
      let(:gemini_local_dir) { Dir.mktmpdir("gemini-local") }

      before do
        # Create fixture files that seed_local_credentials! will read
        File.write(File.join(gemini_local_dir, "oauth_creds.json"), '{"access_token":"test-token"}')
        File.write(File.join(gemini_local_dir, "settings.json"), "{\n  \"selectedType\": \"oauth-personal\"\n}")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: gemini_local_dir,
          copilot_local_config_path: nil
        )
      end

      after do
        FileUtils.rm_rf(gemini_local_dir)
      end

      it "sets the subscription marker without requiring a host bind mount" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds.none? { |bind| bind.include?("/home/agent/.gemini-host:ro") }).to be true
          expect(config["Env"]).to include("PAID_GEMINI_SUBSCRIPTION_AUTH=1")
          mock_container
        end

        service.provision
      end

      it "writes Gemini credentials into the agent tmpfs in a single batched exec" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd|
            cmd.include?("/home/agent/.gemini/oauth_creds.json") &&
              cmd.include?("/home/agent/.gemini/settings.json")
          } ],
          user: "agent"
        )
      end
    end

    context "with Codex subscription auth (CODEX_HOME)" do
      let(:codex_config_dir) { Dir.mktmpdir("codex-config") }

      before do
        create(:llm_model, :openai, model_id: "gpt-5.1", tier: "mid", capability_score: 9.0)
        File.write(File.join(codex_config_dir, "auth.json"), "{}")
        File.write(File.join(codex_config_dir, "config.toml"), <<~TOML)
          model = "gpt-5"
          model_reasoning_effort = "medium"

          [projects."/workspaces/paid"]
          trust_level = "trusted"

          [features]
          multi_agent = true
        TOML

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(codex_config_dir)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(claude_local_config_path: nil, gemini_local_config_path: nil, copilot_local_config_path: nil)
      end

      after do
        FileUtils.rm_rf(codex_config_dir)
      end

      it "keeps Codex auth in tmpfs and sets the subscription marker" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds.none? { |bind| bind.include?("/home/agent/.codex/auth.json") }).to be true
          expect(binds.none? { |bind| bind.include?("/home/agent/.codex/config.toml") }).to be true
          env = config["Env"]
          expect(env).to include("PAID_CODEX_SUBSCRIPTION_AUTH=1")
          expect(env).to include("ANTHROPIC_BASE_URL=http://web:3000/api/proxy/anthropic")
          expect(config["HostConfig"]["Tmpfs"]).to have_key("/home/agent/.codex")
          mock_container
        end

        service.provision
      end

      it "copies Codex auth into tmpfs and records the shared source path" do
        allow(agent_run).to receive(:log!).and_call_original

        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd|
            cmd.include?("/home/agent/.codex/auth.json") &&
              decoded_base64_content(cmd).include?("{")
          } ],
          user: "agent"
        )
        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.codex_credentials_shared",
          metadata: hash_including(source_path: codex_config_dir)
        )
      end

      it "fails clearly when Codex auth is not actually copied into tmpfs" do
        allow(mock_container).to receive(:exec) do |cmd, **_opts|
          shell = cmd.last.to_s
          if cmd.first(2) == [ "sh", "-lc" ] && shell.include?("/home/agent/.codex/auth.json")
            [ [], [ "write failed\n" ], 1 ]
          else
            [ [], [], 0 ]
          end
        end

        expect {
          service.provision
        }.to raise_error(
          Containers::Provision::ProvisionError,
          /Codex subscription auth\.json was not copied into the container/
        )
      end

      it "writes a sanitized host Codex config into writable tmpfs before rewriting notify" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [
            "sh",
            "-lc",
            satisfy { |cmd|
              decoded = decoded_base64_content(cmd)
              cmd.include?("/home/agent/.codex/config.toml") &&
                decoded.include?('model = "gpt-5.1"') &&
                !decoded.include?('model = "gpt-5"') &&
                !decoded.include?("model_reasoning_effort") &&
                decoded.include?("[features]") &&
                !decoded.include?("[projects")
            }
          ],
          user: "agent"
        )
      end

      it "rewrites Codex notify command using the current CLI config shape" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [
            "sh",
            "-lc",
            satisfy { |cmd|
              cmd.include?("/home/agent/.codex/config.toml") &&
                cmd.include?('touch "$config"') &&
                cmd.include?("awk") &&
                cmd.include?("notify[[:space:]]*=")
            }
          ],
          user: "agent"
        )
      end

      it "only chowns the .codex tmpfs directory entry (non-recursive) via batched script" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-c", satisfy { |script|
            script.include?("chown agent:agent /home/agent/.codex") &&
              !script.include?("chown -R agent:agent /home/agent/.codex")
          } ],
          user: "root"
        )
      end
    end

    context "with Codex subscription auth from the local filesystem" do
      let(:codex_local_dir) { Dir.mktmpdir("codex-local") }

      before do
        create(:llm_model, :openai, model_id: "gpt-5.1", tier: "mid", capability_score: 9.0)
        File.write(File.join(codex_local_dir, "auth.json"), '{"refresh_token":"test-token"}')
        File.write(File.join(codex_local_dir, "config.toml"), "model = \"gpt-5\"\nmodel_reasoning_effort = \"medium\"")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: codex_local_dir,
          gemini_local_config_path: nil,
          copilot_local_config_path: nil
        )
      end

      after do
        FileUtils.rm_rf(codex_local_dir)
      end

      it "does not bind-mount local Codex auth directly" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds.none? { |bind| bind.include?("/home/agent/.codex/auth.json") }).to be true
          expect(binds.none? { |bind| bind.include?(":/home/agent/.codex:rw") }).to be true
          expect(config["Env"]).to include("PAID_CODEX_SUBSCRIPTION_AUTH=1")

          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.codex")
          mock_container
        end

        service.provision
      end

      it "copies shared Codex auth and writes sanitized config into the writable tmpfs" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd|
            cmd.include?("/home/agent/.codex/auth.json") &&
              decoded_base64_content(cmd).include?("\"refresh_token\":\"test-token\"")
          } ],
          user: "agent"
        )
        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd|
            cmd.include?("/home/agent/.codex/config.toml") &&
              decoded_base64_content(cmd).include?('model = "gpt-5.1"') &&
              !decoded_base64_content(cmd).include?('model = "gpt-5"') &&
              !decoded_base64_content(cmd).include?("model_reasoning_effort")
          } ],
          user: "agent"
        )
      end

      it "uses the mounted local Codex path as the shared source without binding auth directly" do
        mount_source = Dir.mktmpdir("codex-host")
        mount_destination = File.dirname(codex_local_dir)
        current_container = instance_double(
          Docker::Container,
          info: { "Mounts" => [ { "Destination" => mount_destination, "Source" => mount_source } ] }
        )
        allow(Docker::Container).to receive(:get).with(Socket.gethostname).and_return(current_container)

        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds.none? { |bind| bind.include?("/home/agent/.codex/auth.json") }).to be true
          mock_container
        end

        service.provision
      ensure
        FileUtils.rm_rf(mount_source) if mount_source
      end

      it "fails clearly for a Codex subscription run when local auth is not bind-mountable" do
        codex_runner = create(:runner, user: project.created_by, runner_key: "codex")
        project.created_by.settings.update!(default_agent_runner: codex_runner.routing_key)
        agent_run.update!(agent_type: "codex")
        current_container = instance_double(Docker::Container, info: { "Mounts" => [] })
        allow(Docker::Container).to receive(:get).with(Socket.gethostname).and_return(current_container)

        expect {
          service.provision
        }.to raise_error(
          Containers::Provision::ProvisionError,
          /Codex subscription auth was found at .*not available as a Docker bind mount/
        )
      end

      it "does not fail for an API-key-backed Codex default when local auth is not bind-mountable" do
        api_key = create(:provider_api_key, user: project.created_by, api_service_type: "openai")
        codex_runner = create(:runner, :api_key, user: project.created_by, runner_key: "codex", provider_api_key: api_key)
        project.created_by.settings.update!(default_agent_runner: codex_runner.routing_key)
        agent_run.update!(agent_type: "codex")
        current_container = instance_double(Docker::Container, info: { "Mounts" => [] })
        allow(Docker::Container).to receive(:get).with(Socket.gethostname).and_return(current_container)

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["Env"]).to include("PAID_CODEX_SUBSCRIPTION_AUTH=0")
          mock_container
        end

        expect { service.provision }.not_to raise_error
      end
    end

    context "with Copilot subscription auth (COPILOT_CONFIG_DIR)" do
      let(:copilot_config_dir) { Dir.mktmpdir("copilot-config") }

      before do
        File.write(File.join(copilot_config_dir, "config.json"), "{}")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(copilot_config_dir)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(copilot_config_dir)
        allow(service).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: nil,
          copilot_local_config_path: nil
        )
      end

      after do
        FileUtils.rm_rf(copilot_config_dir)
      end

      it "mounts Copilot config at a staging path and sets the subscription marker" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("#{copilot_config_dir}:/home/agent/.copilot-host:ro")
          env = config["Env"]
          expect(env).to include("PAID_COPILOT_SUBSCRIPTION_AUTH=1")
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network for Copilot subscription auth" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "seeds cached Copilot credentials from the host bind mount" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-c", include("/home/agent/.copilot-host/config.json").and(include("/home/agent/.copilot/config.json")) ],
          user: "agent"
        )
      end

      it "sets COPILOT_GITHUB_TOKEN when config.json lacks oauth_token and token resolution succeeds" do
        allow(service).to receive(:resolve_copilot_github_token).and_return("gho_test_token_from_gh")

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["Env"]).to include("COPILOT_GITHUB_TOKEN=gho_test_token_from_gh")
          mock_container
        end

        service.provision
      end

      it "omits COPILOT_GITHUB_TOKEN when config.json has oauth_token" do
        File.write(File.join(copilot_config_dir, "config.json"), '{"oauth_token":"existing-token"}')

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["Env"]).not_to include(a_string_matching("COPILOT_GITHUB_TOKEN="))
          mock_container
        end

        service.provision
      end
    end

    context "with Copilot subscription auth from the devcontainer filesystem" do
      let(:copilot_local_dir) { Dir.mktmpdir("copilot-local") }

      before do
        File.write(File.join(copilot_local_dir, "config.json"), '{"oauth_token":"test-token"}')
        File.write(File.join(copilot_local_dir, "settings.json"), '{}')

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: nil,
          copilot_local_config_path: copilot_local_dir
        )
      end

      after do
        FileUtils.rm_rf(copilot_local_dir)
      end

      it "sets the subscription marker without requiring a host bind mount" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds.none? { |bind| bind.include?("/home/agent/.copilot-host:ro") }).to be true
          expect(config["Env"]).to include("PAID_COPILOT_SUBSCRIPTION_AUTH=1")
          mock_container
        end

        service.provision
      end

      it "writes Copilot credentials into the agent tmpfs from the local filesystem" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd| cmd.include?("/home/agent/.copilot/config.json") && decoded_base64_content(cmd).include?("oauth_token") } ],
          user: "agent"
        )
      end

      it "omits COPILOT_GITHUB_TOKEN when local config.json has oauth_token" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["Env"]).not_to include(a_string_matching("COPILOT_GITHUB_TOKEN="))
          mock_container
        end

        service.provision
      end
    end

    context "when firewall rules fail in production" do
      before do
        # Materialize records while the environment is still test so their
        # Turbo broadcasts use the test cable adapter, not production
        # SolidCable (which has no database in this environment).
        agent_run
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        # Production resolves the runtime image through the immutable catalog
        # (RDR-059). No catalog profiles are configured in this environment, so
        # stub the selector to keep this example focused on firewall failure.
        allow(Containers::RuntimeImageSelector).to receive(:select).and_return(
          instance_double(
            Containers::RuntimeImageSelector::Result,
            image: "ghcr.io/acme/paid-agent@sha256:#{'1' * 64}",
            metadata: runtime_image_selection_metadata
          )
        )
        allow(NetworkPolicy).to receive(:apply_firewall_rules)
          .and_raise(NetworkPolicy::Error, "Permission denied")
      end

      it "raises ProvisionError" do
        expect { service.provision }.to raise_error(
          described_class::ProvisionError, /Firewall setup failed/
        )
      end
    end

    context "when firewall rules fail in development" do
      before do
        allow(NetworkPolicy).to receive(:apply_firewall_rules)
          .and_raise(NetworkPolicy::Error, "Permission denied")
        allow(agent_run).to receive(:log!)
      end

      it "does not raise and logs the failure" do
        expect(agent_run).to receive(:log!).with("system", "container.firewall.failed",
          metadata: hash_including(error: "Permission denied"))

        result = service.provision
        expect(result).to be_success
      end
    end

    context "with kilocode agent runs" do
      let(:agent_run) { create(:agent_run, project: project, agent_type: "kilocode") }

      it "uses the infrastructure network for direct outbound access" do
        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "skips firewall rules" do
        expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

        service.provision
      end
    end
  end

  describe "#seed_opencode_database!" do
    let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
    let!(:opencode_provider) do
      create(
        :runner,
        :api_key,
        user: project.created_by,
        runner_key: "opencode",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
      )
    end
    let(:service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

    before do
      project.created_by.settings.update!(default_agent_runner: opencode_provider.routing_key)
      allow(Docker::Container).to receive(:create).and_return(mock_container)
      allow(mock_container).to receive(:start)
      allow(NetworkPolicy).to receive_messages(ensure_network!: mock_network, apply_firewall_rules: nil)
      allow(Docker::Volume).to receive(:create).and_return(mock_volume)
      allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)
      allow(agent_run).to receive(:log!)
    end

    it "copies pre-seeded database from /opt/opencode-seed into the tmpfs" do
      service.provision

      expect(mock_container).to have_received(:exec).with(
        [ "sh", "-c",
          satisfy { |script|
            script.include?("/opt/opencode-seed") &&
              script.include?("/home/agent/.local/share/opencode")
          } ],
        user: "root"
      )
    end

    it "logs the seeding success" do
      service.provision

      expect(agent_run).to have_received(:log!).with("system", "container.opencode_database_seeded",
        metadata: {})
    end

    it "does not seed when the run resolves to a different runner" do
      project.created_by.settings.update!(default_agent_runner: "claude")

      service.provision

      expect(mock_container).not_to have_received(:exec).with(
        [ "sh", "-c", include("/opt/opencode-seed") ],
        user: "root"
      )
    end

    context "when Docker exec fails during opencode seed" do
      before do
        allow(mock_container).to receive(:exec) do |cmd, **opts|
          if cmd.is_a?(Array) && cmd[0] == "sh" && cmd[1] == "-c" && cmd.last.include?("/opt/opencode-seed")
            raise Docker::Error::DockerError, "copy failed"
          end
          nil
        end
      end

      it "logs the failure but does not raise" do
        expect { service.provision }.not_to raise_error

        expect(agent_run).to have_received(:log!).with("system", "container.opencode_database_seed_failed",
          metadata: hash_including(error: "copy failed"))
      end
    end

    context "when the cp command exits non-zero" do
      before do
        allow(mock_container).to receive(:exec) do |cmd, **opts|
          if cmd.is_a?(Array) && cmd[0] == "sh" && cmd[1] == "-c" && cmd.last.include?("/opt/opencode-seed")
            [ [], [], 1 ]
          else
            nil
          end
        end
      end

      it "logs the failure with the exit code" do
        expect { service.provision }.not_to raise_error

        expect(agent_run).to have_received(:log!).with("system", "container.opencode_database_seed_failed",
          metadata: hash_including(error: "opencode database seed exited with 1"))
      end
    end
  end

  describe "#seed_kilo_database!" do
    let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "anthropic") }
    let!(:kilocode_provider) do
      create(
        :runner,
        :api_key,
        user: project.created_by,
        runner_key: "kilocode",
        provider_api_key: api_key,
        config: { "kilocode" => { "api_provider" => "anthropic", "model" => "claude-sonnet-4-5" } }
      )
    end
    let(:service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

    before do
      project.created_by.settings.update!(default_agent_runner: kilocode_provider.routing_key)
      allow(Docker::Container).to receive(:create).and_return(mock_container)
      allow(mock_container).to receive(:start)
      allow(NetworkPolicy).to receive_messages(ensure_network!: mock_network, apply_firewall_rules: nil)
      allow(Docker::Volume).to receive(:create).and_return(mock_volume)
      allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)
      allow(agent_run).to receive(:log!)
    end

    it "copies pre-seeded database from /opt/kilo-seed into the tmpfs" do
      service.provision

      expect(mock_container).to have_received(:exec).with(
        [ "sh", "-c",
          satisfy { |script|
            script.include?("/opt/kilo-seed") &&
              script.include?("/home/agent/.local/share/kilo")
          } ],
        user: "root"
      )
    end

    it "logs the seeding success" do
      service.provision

      expect(agent_run).to have_received(:log!).with("system", "container.kilo_database_seeded",
        metadata: {})
    end

    it "does not seed when the run resolves to a different runner" do
      project.created_by.settings.update!(default_agent_runner: "claude")

      service.provision

      expect(mock_container).not_to have_received(:exec).with(
        [ "sh", "-c", include("/opt/kilo-seed") ],
        user: "root"
      )
    end

    context "when Docker exec fails during kilo seed" do
      before do
        allow(mock_container).to receive(:exec) do |cmd, **opts|
          if cmd.is_a?(Array) && cmd[0] == "sh" && cmd[1] == "-c" && cmd.last.include?("/opt/kilo-seed")
            raise Docker::Error::DockerError, "copy failed"
          end
          nil
        end
      end

      it "logs the failure but does not raise" do
        expect { service.provision }.not_to raise_error

        expect(agent_run).to have_received(:log!).with("system", "container.kilo_database_seed_failed",
          metadata: hash_including(error: "copy failed"))
      end
    end

    context "when the cp command exits non-zero" do
      before do
        allow(mock_container).to receive(:exec) do |cmd, **opts|
          if cmd.is_a?(Array) && cmd[0] == "sh" && cmd[1] == "-c" && cmd.last.include?("/opt/kilo-seed")
            [ [], [], 1 ]
          else
            nil
          end
        end
      end

      it "logs the failure with the exit code" do
        expect { service.provision }.not_to raise_error

        expect(agent_run).to have_received(:log!).with("system", "container.kilo_database_seed_failed",
          metadata: hash_including(error: "kilo database seed exited with 1"))
      end
    end
  end

  describe "#execute" do
    before do
      service.provision
    end

    context "when command succeeds" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "command output\n") if block
          [ [ "command output\n" ], [], 0 ]
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })
      end

      it "returns success result with stdout" do
        result = service.execute("echo 'hello'")

        expect(result).to be_success
        expect(result[:stdout]).to eq("command output\n")
        expect(result[:exit_code]).to eq(0)
      end

      it "logs command execution" do
        expect(agent_run).to receive(:log!).with("system", "container.execute.start",
          metadata: hash_including(command: anything))
        expect(agent_run).to receive(:log!).with("stdout", "command output\n")
        expect(agent_run).to receive(:log!).with("system", "container.execute.complete",
          metadata: hash_including(exit_code: 0, duration_ms: a_kind_of(Integer)))

        service.execute("echo 'hello'")
      end

      it "accepts array command format" do
        expect(mock_container).to receive(:exec).with([ "ls", "-la" ], hash_including(wait: anything))

        service.execute([ "ls", "-la" ])
      end

      it "passes exec environment variables without logging them" do
        allow(agent_run).to receive(:log!)
        expect(mock_container).to receive(:exec).with(
          [ "printenv", "SECRET_TOKEN" ],
          hash_including(wait: anything, Env: array_including("SECRET_TOKEN=super-secret"))
        )

        service.execute([ "printenv", "SECRET_TOKEN" ], env: { "SECRET_TOKEN" => "super-secret" })

        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.execute.start",
          metadata: hash_including(command: satisfy { |command| !command.include?("super-secret") })
        )
      end

      # @spec CONTAINER-RUNTIME-019
      it "yields normalized stdout and stderr chunks to the caller block in stream order" do
        raw_stdout = "out\x00put\n".b
        raw_stderr = "bad\xFF\n".b

        expect(Containers.backend).to receive(:exec_in_container) do |container, command, **_opts, &block|
          expect(container).to eq(mock_container)
          expect(command).to eq([ "sh", "-c", "echo 'hello'" ])

          block.call(:stdout, raw_stdout)
          block.call(:stderr, raw_stderr)

          [ [ raw_stdout ], [ raw_stderr ], 0 ]
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })

        streamed = []
        result = service.execute("echo 'hello'") { |stream, chunk| streamed << [ stream, chunk ] }

        expect(result).to be_success
        expect(streamed).to eq([
          [ :stdout, "output\n" ],
          [ :stderr, "bad\uFFFD\n" ]
        ])
      end

      it "fails the command and invalidates the container when preparation cleanup exits non-zero" do
        preparation = build_preparation
        allow(agent_run).to receive(:log!)
        agent_run.update!(container_id: mock_container.id)
        stub_exec_with_cleanup_failure(mock_container)
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })

        expect {
          service.execute("echo 'hello'", preparation: preparation)
        }.to raise_error(described_class::ExecutionError, /Failed to restore prepared runtime state: missing runtime preparation backup/)

        expect(agent_run.reload.container_id).to be_nil
        expect(service.container).to be_nil
        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.execute.preparation_cleanup_failed",
          metadata: hash_including(error: "missing runtime preparation backup\n")
        )
        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.execute.invalidated_after_preparation_cleanup_failure",
          metadata: hash_including(container_id: "abc123container")
        )
      end

      it "treats 'container is not running' Docker errors during preparation cleanup as a no-op" do
        preparation = build_preparation
        allow(agent_run).to receive(:log!)
        stub_exec_with_dead_container_cleanup(mock_container)
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })

        result = service.execute("echo 'hello'", preparation: preparation)

        expect(result).to be_success
        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.execute.preparation_cleanup_skipped_dead_container",
          metadata: hash_including(error: /is not running/i)
        )
        expect(agent_run).not_to have_received(:log!).with(
          "system", "container.execute.preparation_cleanup_failed", anything
        )
      end
    end

    context "when command fails" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stderr, "error message\n") if block
          [ [], [ "error message\n" ], 1 ]
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 1 } })
      end

      it "returns failure result with stderr and exit code" do
        result = service.execute("false")

        expect(result).to be_failure
        expect(result[:stderr]).to eq("error message\n")
        expect(result[:exit_code]).to eq(1)
        expect(result.error).to include("exited with code 1")
      end

      it "does not inspect container state for ordinary non-zero exits" do
        expect(mock_container).not_to receive(:refresh!)

        result = service.execute("false")

        expect(result[:oom_killed]).to be false
      end
    end

    context "when the command is OOM-killed (exit 137)" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stderr, "Killed\n") if block
          [ [], [ "Killed\n" ], 137 ]
        end
        allow(mock_container).to receive(:info).and_return(
          "State" => { "Running" => false, "ExitCode" => 137, "OOMKilled" => true },
          "HostConfig" => { "Memory" => 4 * 1024 * 1024 * 1024 }
        )
      end

      it "detects the OOM kill and flags the result" do
        result = service.execute("opencode run 'Reply with exactly OK.'")

        expect(result).to be_failure
        expect(result[:exit_code]).to eq(137)
        expect(result[:oom_killed]).to be true
        expect(result[:memory_limit_bytes]).to eq(4 * 1024 * 1024 * 1024)
      end

      it "logs the OOM kill distinctly with the memory limit" do
        allow(agent_run).to receive(:log!)

        service.execute("opencode run 'Reply with exactly OK.'")

        expect(agent_run).to have_received(:log!).with("system", "container.execute.oom_killed",
          metadata: hash_including(
            exit_code: 137,
            memory_limit_bytes: 4 * 1024 * 1024 * 1024,
            container_running: false
          ))
      end
    end

    context "when exit 137 occurs but the container is not OOM-killed" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stderr, "Killed\n") if block
          [ [], [ "Killed\n" ], 137 ]
        end
        allow(mock_container).to receive(:info).and_return(
          "State" => { "Running" => true, "ExitCode" => 137, "OOMKilled" => false }
        )
      end

      it "records a plain SIGKILL without claiming OOM" do
        allow(agent_run).to receive(:log!)

        result = service.execute("opencode run 'Reply with exactly OK.'")

        expect(result[:oom_killed]).to be false
        expect(result[:container_running]).to be true
        expect(agent_run).to have_received(:log!).with("system", "container.execute.sigkill",
          metadata: hash_including(exit_code: 137))
      end
    end

    context "when exit 137 occurs but the container is already gone" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stderr, "Killed\n") if block
          [ [], [ "Killed\n" ], 137 ]
        end
        allow(mock_container).to receive(:refresh!).and_raise(Docker::Error::NotFoundError, "No such container")
      end

      it "degrades gracefully without claiming OOM when state cannot be read" do
        allow(agent_run).to receive(:log!)

        result = service.execute("opencode run 'Reply with exactly OK.'")

        expect(result).to be_failure
        expect(result[:oom_killed]).to be false
        expect(result[:memory_limit_bytes]).to be_nil
        expect(result[:container_running]).to be_nil
        expect(agent_run).to have_received(:log!).with("system", "container.execute.exit_state_unavailable",
          metadata: hash_including(error: /No such container/))
        expect(agent_run).to have_received(:log!).with("system", "container.execute.sigkill",
          metadata: hash_including(exit_code: 137))
      end
    end

    context "when command output contains invalid UTF-8 bytes" do
      let(:invalid_chunk) { "bad \xFF output\n".b }

      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, invalid_chunk) if block
          [ [ invalid_chunk ], [], 0 ]
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })
      end

      it "scrubs output before buffering and logging" do
        allow(agent_run).to receive(:log!)

        result = service.execute("echo 'hello'")

        expect(agent_run).to have_received(:log!).with("stdout", "bad � output\n")
        expect(result).to be_success
        expect(result[:stdout]).to eq("bad � output\n")
        expect(result[:stdout]).to be_valid_encoding
      end
    end

    context "when command times out" do
      before do
        allow(mock_container).to receive(:exec) do
          sleep 0.2
        end
      end

      it "raises TimeoutError" do
        expect { service.execute("sleep 10", timeout: 0.1) }.to raise_error(described_class::TimeoutError)
      end
    end

    context "when stderr matches an abort pattern" do
      let(:abort_patterns) { [ /free tier limit reached/i ] }
      let(:quota_error) { "Error: Free tier limit reached. Please upgrade to a paid plan." }

      before do
        allow(mock_container).to receive(:stop)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stderr, quota_error) if block
          # Simulate exec returning after container.stop was called
          [ [], [ quota_error ], 1 ]
        end
      end

      it "raises OutputAbortError with the matched output" do
        expect { service.execute("kilo run --auto", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to eq(quota_error)
          }
      end

      it "stops the container immediately" do
        service.execute("kilo run --auto", abort_patterns: abort_patterns) rescue nil

        expect(mock_container).to have_received(:stop).with(timeout: 0)
      end

      it "logs the abort pattern match with stream type" do
        allow(agent_run).to receive(:log!)

        expect { service.execute("kilo run --auto", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError)

        expect(agent_run).to have_received(:log!).with(
          "system", "container.execute.abort_pattern_matched",
          metadata: hash_including(
            stream: "stderr",
            output: a_string_matching(/Free tier limit reached/)
          )
        )
      end
    end

    context "when stderr does not match abort patterns" do
      let(:abort_patterns) { [ /free tier limit reached/i ] }

      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stderr, "some benign warning\n") if block
          [ [ "output" ], [ "some benign warning\n" ], 0 ]
        end
      end

      it "does not raise OutputAbortError" do
        result = service.execute("kilo run --auto", abort_patterns: abort_patterns)

        expect(result.success?).to be true
      end

      it "does not stop the container" do
        allow(mock_container).to receive(:stop)
        service.execute("kilo run --auto", abort_patterns: abort_patterns)

        expect(mock_container).not_to have_received(:stop)
      end
    end

    context "when stdout is structured JSONL that embeds abort-like text" do
      let(:abort_patterns) { [ /free tier limit reached/i ] }
      let(:jsonl_chunk) do
        {
          "type" => "item.completed",
          "item" => {
            "id" => "item_1",
            "type" => "command_execution",
            "aggregated_output" => "spec text: Free tier limit reached. Please upgrade to a paid plan."
          }
        }.to_json + "\n"
      end

      before do
        allow(mock_container).to receive(:stop)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, jsonl_chunk) if block
          [ [ jsonl_chunk ], [], 0 ]
        end
      end

      it "does not raise OutputAbortError" do
        result = service.execute("codex exec --json", abort_patterns: abort_patterns)

        expect(result.success?).to be true
      end

      it "does not stop the container" do
        service.execute("codex exec --json", abort_patterns: abort_patterns)

        expect(mock_container).not_to have_received(:stop)
      end

      it "does not abort when a JSONL line is split across stdout chunks" do
        partial_start = "{\"type\":\"item.completed\",\"item\":{\"aggregated_output\":\"Free tier "
        partial_end = "limit reached. Please upgrade to a paid plan.\"}}\n"

        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, partial_start) if block
          block.call(:stdout, partial_end) if block
          [ [ partial_start, partial_end ], [], 0 ]
        end

        result = service.execute("codex exec --json", abort_patterns: abort_patterns)

        expect(result.success?).to be true
        expect(mock_container).not_to have_received(:stop)
      end

      it "buffers a partial structured event until the type field arrives" do
        partial_start = "{\"item\":{\"aggregated_output\":\"Free tier limit reached. Please upgrade to a paid plan.\"}"
        partial_end = ",\"type\":\"item.completed\"}\n"

        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, partial_start) if block
          block.call(:stdout, partial_end) if block
          [ [ partial_start, partial_end ], [], 0 ]
        end

        result = service.execute("codex exec --json", abort_patterns: abort_patterns)

        expect(result.success?).to be true
        expect(mock_container).not_to have_received(:stop)
      end

      it "still aborts on structured stdout failure events" do
        structured_error = {
          "type" => "response.failed",
          "error" => {
            "message" => "Error: Free tier limit reached. Please upgrade to a paid plan."
          }
        }.to_json + "\n"

        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, structured_error) if block
          [ [ structured_error ], [], 1 ]
        end

        expect { service.execute("codex exec --json", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to include("Free tier limit reached")
          }

        expect(mock_container).to have_received(:stop).with(timeout: 0)
      end

      it "logs stdout as the stream type when structured JSONL triggers abort" do
        error_json = { "type" => "response.failed",
                       "error" => { "message" => "Error: Free tier limit reached." } }.to_json + "\n"
        allow(agent_run).to receive(:log!)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, error_json) if block
          [ [ error_json ], [], 1 ]
        end

        expect { service.execute("codex exec --json", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError)

        expect(agent_run).to have_received(:log!).with(
          "system", "container.execute.abort_pattern_matched",
          metadata: hash_including(stream: "stdout", output: a_string_matching(/Free tier limit reached/))
        )
      end

      it "aborts on a complete structured stdout failure event without a trailing newline" do
        structured_error = {
          "type" => "response.failed",
          "error" => {
            "message" => "Error: Free tier limit reached. Please upgrade to a paid plan."
          }
        }.to_json

        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, structured_error) if block
          [ [ structured_error ], [], 1 ]
        end

        expect { service.execute("codex exec --json", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to include("Free tier limit reached")
          }

        expect(mock_container).to have_received(:stop).with(timeout: 0)
      end

      it "falls back to raw stdout matching for malformed brace-prefixed fatal output" do
        malformed_error = "{Error: Free tier limit reached. Please upgrade to a paid plan."

        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, malformed_error) if block
          [ [ malformed_error ], [], 1 ]
        end

        expect { service.execute("codex exec --json", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to include("Free tier limit reached")
          }

        expect(mock_container).to have_received(:stop).with(timeout: 0)
      end

      it "checks a buffered brace-prefixed fatal fragment when the stream ends" do
        truncated_error = "{\"error\":\"Free tier limit reached. Please upgrade to a paid plan."

        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, truncated_error) if block
          [ [ truncated_error ], [], 1 ]
        end

        expect { service.execute("codex exec --json", abort_patterns: abort_patterns) }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to include("Free tier limit reached")
          }

        expect(mock_container).to have_received(:stop).with(timeout: 0)
      end
    end

    context "when streaming JSONL events trigger abort" do
      before do
        allow(mock_container).to receive(:stop)
      end

      it "raises OutputAbortError on turn.failed event" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "{\"type\": \"turn.failed\", \"message\": \"context window exceeded\"}\n") if block
          [ [], [], 1 ]
        end

        expect { service.execute("codex exec --json") }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to eq("streaming_event:turn.failed")
          }
      end

      it "raises OutputAbortError on error event" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "{\"type\": \"error\", \"message\": \"fatal API error\"}\n") if block
          [ [], [], 1 ]
        end

        expect { service.execute("codex exec --json") }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to eq("streaming_event:error")
          }
      end

      it "stops the container immediately on abort event" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "{\"type\": \"turn.failed\", \"message\": \"failed\"}\n") if block
          [ [], [], 1 ]
        end

        service.execute("codex exec --json") rescue nil

        expect(mock_container).to have_received(:stop).with(timeout: 0)
      end

      it "handles JSONL events split across chunks" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          if block
            # Split a single JSONL line across two chunks
            block.call(:stdout, '{"type": "turn.fai')
            block.call(:stdout, "led\", \"message\": \"exceeded\"}\n")
          end
          [ [], [], 1 ]
        end

        expect { service.execute("codex exec --json") }
          .to raise_error(described_class::OutputAbortError) { |e|
            expect(e.matched_output).to eq("streaming_event:turn.failed")
          }
      end

      it "flushes turn metrics even on abort" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          if block
            block.call(:stdout, "{\"type\": \"turn_complete\", \"usage\": {\"input_tokens\": 500, \"output_tokens\": 200}}\n")
            block.call(:stdout, "{\"type\": \"turn.failed\", \"message\": \"context window exceeded\"}\n")
          end
          [ [], [], 1 ]
        end

        service.execute("codex exec --json") rescue nil

        agent_run.reload
        expect(agent_run.turns_completed).to eq(2)
        expect(agent_run.streaming_turns_data.length).to eq(2)
      end

      it "swallows metric flush failures so the original error is preserved" do
        processor = instance_double(Containers::StreamingEventProcessor)
        allow(service).to receive(:build_streaming_event_processor).and_return(processor)
        allow(processor).to receive_messages(handle_line: nil, last_event_type: nil)
        allow(processor).to receive(:flush_metrics!).and_raise(ActiveRecord::ActiveRecordError, "flush failed")
        allow(agent_run).to receive(:log!).and_call_original
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "{\"type\": \"progress\"}\n") if block
          raise Docker::Error::DockerError, "exec failed"
        end

        expect { service.execute("codex exec --json") }
          .to raise_error(described_class::ExecutionError, /Docker exec error: exec failed/)

        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.execute.streaming_metrics_flush_failed",
          metadata: hash_including(error: "flush failed")
        )
      end

      it "ignores streaming-looking JSON output from non-agent exec commands" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "{\"type\": \"error\", \"message\": \"helper output\"}\n") if block
          [ [], [], 0 ]
        end

        expect { service.execute("echo '{\"type\":\"error\"}'") }.not_to raise_error
        expect(mock_container).not_to have_received(:stop)
      end

      it "drops oversized partial JSONL buffers instead of growing without bound" do
        overflow_chunk = "{" + ("x" * described_class::MAX_STREAMING_LINE_BUFFER_BYTES)

        allow(agent_run).to receive(:log!).and_call_original
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, overflow_chunk) if block
          [ [], [], 0 ]
        end

        service.execute("codex exec --json")

        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.execute.streaming_buffer_reset",
          metadata: hash_including(dropped_bytes: overflow_chunk.bytesize)
        )
      end
    end

    context "when container is not provisioned" do
      let(:unprovisioned_service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

      it "raises ProvisionError" do
        expect { unprovisioned_service.execute("echo 'hello'") }
          .to raise_error(described_class::ProvisionError, /not provisioned/)
      end
    end

    context "when streaming is disabled" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "output\n") if block
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })
      end

      it "does not log output" do
        expect(agent_run).not_to receive(:log!).with("stdout", anything)

        service.execute("echo 'hello'", stream: false)
      end
    end

    context "when codex subscription auth host mount is active" do
      let(:codex_config_dir) { Dir.mktmpdir("codex-config") }

      before do
        File.write(File.join(codex_config_dir, "auth.json"), "{}")
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(codex_config_dir)
        # Clear memoized values so they pick up the new ENV stubs
        service.remove_instance_variable(:@codex_subscription_auth_mount) if service.instance_variable_defined?(:@codex_subscription_auth_mount)
        service.remove_instance_variable(:@codex_config_host_path) if service.instance_variable_defined?(:@codex_config_host_path)
        service.remove_instance_variable(:@current_container_mounts) if service.instance_variable_defined?(:@current_container_mounts)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "output\n") if block
          [ [ "output\n" ], [], 0 ]
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })
      end

      after do
        FileUtils.rm_rf(codex_config_dir)
      end

      it "acquires a per-config file lock around Codex execution" do
        lockfile = service.send(:codex_auth_lockfile_path)
        FileUtils.rm_f(lockfile)

        service.execute([ "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--", "prompt" ])

        expect(File.exist?(lockfile)).to be true
      end

      it "logs lock acquisition for Codex execution" do
        allow(agent_run).to receive(:log!)

        service.execute([ "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--", "prompt" ])

        expect(agent_run).to have_received(:log!).with(
          "system", "container.codex_auth_lock.acquired", metadata: hash_including(:lockfile)
        )
      end

      it "treats env-wrapped Codex execution as a Codex command" do
        allow(agent_run).to receive(:log!)

        service.execute([ "env", "-u", "OPENAI_API_KEY", "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--", "prompt" ])

        expect(agent_run).to have_received(:log!).with(
          "system", "container.codex_auth_lock.acquired", metadata: hash_including(:lockfile)
        )
      end

      it "does not sync shared auth back after timing out on the lock" do
        allow(service).to receive(:acquire_lock_with_timeout).and_return(false)
        allow(service).to receive(:sync_codex_auth_file_to_source!)
        allow(agent_run).to receive(:log!)

        service.execute([ "codex", "exec", "--dangerously-bypass-approvals-and-sandbox", "--", "prompt" ])

        expect(service).not_to have_received(:sync_codex_auth_file_to_source!)
        expect(agent_run).to have_received(:log!).with(
          "system", "container.codex_auth_sync_skipped_without_lock", metadata: hash_including(:source_path)
        )
      end

      it "does not lock non-Codex container commands" do
        allow(agent_run).to receive(:log!)

        service.execute("echo 'hello'")

        expect(agent_run).not_to have_received(:log!).with(
          "system", "container.codex_auth_lock.acquired", anything
        )
      end
    end

    context "when closing stdin for codex exec inside an sh -c wrapper" do
      let(:captured) { [] }

      before do
        allow(mock_container).to receive(:exec) do |cmd, **_opts, &block|
          captured << cmd
          block.call(:stdout, "output\n") if block
          [ [ "output\n" ], [], 0 ]
        end
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true, "ExitCode" => 0 } })
      end

      it "redirects stdin from /dev/null for a bare codex exec command" do
        service.execute([ "codex", "exec", "--json", "prompt" ])

        expect(captured.last.first(2)).to eq([ "sh", "-lc" ])
        expect(captured.last.last).to end_with(" < /dev/null")
      end

      it "redirects stdin from /dev/null for an sh -c api-key auth codex command" do
        script = 'env OPENAI_API_KEY="$KEY" codex exec --json "$1"'
        service.execute([ "sh", "-c", script, "--", "prompt" ])

        expect(captured.last.first(2)).to eq([ "sh", "-lc" ])
        expect(captured.last.last).to end_with(" < /dev/null")
        expect(captured.last.last).to include("codex")
      end

      it "redirects stdin from /dev/null for an sh -c subscription auth codex command" do
        script = 'if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]; then env -u OPENAI_API_KEY codex exec --json "$1"; else codex exec --json "$1"; fi'
        service.execute([ "sh", "-c", script, "--", "prompt" ])

        expect(captured.last.first(2)).to eq([ "sh", "-lc" ])
        expect(captured.last.last).to end_with(" < /dev/null")
      end
    end
  end

  describe "#codex_exec_command?" do
    it "detects a bare codex exec command" do
      expect(service.send(:codex_exec_command?, [ "codex", "exec", "--json", "prompt" ])).to be true
    end

    it "detects an env -u wrapped codex exec command" do
      expect(service.send(:codex_exec_command?, [ "env", "-u", "OPENAI_API_KEY", "codex", "exec", "--json", "prompt" ])).to be true
    end

    it "detects an env assignment wrapped codex exec command" do
      expect(service.send(:codex_exec_command?, [ "env", 'OPENAI_API_KEY="$KEY"', "codex", "exec", "--json", "prompt" ])).to be true
    end

    it "detects codex exec inside an sh -c api-key auth wrapper" do
      script = 'env OPENAI_API_KEY="$KEY" codex exec --json "$1"'
      expect(service.send(:codex_exec_command?, [ "sh", "-c", script, "--", "prompt" ])).to be true
    end

    it "detects codex exec inside an sh -c subscription auth wrapper" do
      script = 'if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]; then env -u OPENAI_API_KEY codex exec --json "$1"; else codex exec --json "$1"; fi'
      expect(service.send(:codex_exec_command?, [ "sh", "-c", script, "--", "prompt" ])).to be true
    end

    it "detects codex exec after an && shell operator" do
      script = 'test -n "$OPENAI_API_KEY" && env OPENAI_API_KEY="$OPENAI_API_KEY" codex exec --json "$1"'
      expect(service.send(:codex_exec_command?, [ "sh", "-c", script, "--", "prompt" ])).to be true
    end

    it "detects codex exec inside an sh -c wrapper passed as a string" do
      expect(service.send(:codex_exec_command?, %(sh -c 'codex exec --json "$1"' -- prompt))).to be true
    end

    it "returns false for an echoed codex exec string" do
      expect(service.send(:codex_exec_command?, [ "sh", "-c", 'echo "codex exec --json $1"' ])).to be false
    end

    it "returns false for a non-codex agent command" do
      expect(service.send(:codex_exec_command?, [ "claude", "--print", "prompt" ])).to be false
    end

    it "returns false for an sh -c wrapper without codex exec" do
      expect(service.send(:codex_exec_command?, [ "sh", "-c", "echo hello" ])).to be false
    end

    it "returns false for an empty command" do
      expect(service.send(:codex_exec_command?, [])).to be false
    end

    it "returns false for a malformed sh -c command missing a script" do
      expect(service.send(:codex_exec_command?, [ "sh", "-c" ])).to be false
    end

    it "returns false for a nil command" do
      expect(service.send(:codex_exec_command?, nil)).to be false
    end
  end

  describe "#close_stdin_for_codex_exec" do
    it "rewrites a bare codex exec command to redirect stdin from /dev/null" do
      rewritten = service.send(:close_stdin_for_codex_exec, [ "codex", "exec", "--json", "prompt" ])

      expect(rewritten.first(2)).to eq([ "sh", "-lc" ])
      expect(rewritten.last).to end_with(" < /dev/null")
      expect(rewritten.last).to include("codex")
    end

    it "rewrites an env -u wrapped codex exec command to redirect stdin from /dev/null" do
      rewritten = service.send(:close_stdin_for_codex_exec, [ "env", "-u", "OPENAI_API_KEY", "codex", "exec", "--json", "prompt" ])

      expect(rewritten.first(2)).to eq([ "sh", "-lc" ])
      expect(rewritten.last).to end_with(" < /dev/null")
    end

    it "rewrites an env assignment wrapped codex exec command to redirect stdin from /dev/null" do
      rewritten = service.send(:close_stdin_for_codex_exec, [ "env", 'OPENAI_API_KEY="$KEY"', "codex", "exec", "--json", "prompt" ])

      expect(rewritten.first(2)).to eq([ "sh", "-lc" ])
      expect(rewritten.last).to end_with(" < /dev/null")
    end

    it "rewrites an sh -c codex wrapper to redirect stdin from /dev/null" do
      script = 'env OPENAI_API_KEY="$KEY" codex exec --json "$1"'
      rewritten = service.send(:close_stdin_for_codex_exec, [ "sh", "-c", script, "--", "prompt" ])

      expect(rewritten.first(2)).to eq([ "sh", "-lc" ])
      expect(rewritten.last).to end_with(" < /dev/null")
      expect(rewritten.last).to include("codex")
    end

    it "preserves the prompt argument when rewriting an sh -c codex wrapper" do
      rewritten = service.send(:close_stdin_for_codex_exec, [ "sh", "-c", 'codex exec "$1"', "--", "build the feature" ])

      expect(rewritten.last).to include("build\\ the\\ feature")
    end

    it "leaves non-codex commands untouched" do
      original = [ "claude", "--print", "prompt" ]
      expect(service.send(:close_stdin_for_codex_exec, original)).to eq(original)
    end
  end

  describe "#cleanup" do
    before do
      service.provision
    end

    context "when container is running" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true } })
      end

      it "stops and deletes the container" do
        expect(mock_container).to receive(:stop).with(timeout: 10)
        expect(mock_container).to receive(:delete).with(force: false, v: true)

        service.cleanup
      end
    end

    context "when container is already stopped" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => false } })
      end

      it "only deletes the container" do
        expect(mock_container).not_to receive(:stop)
        expect(mock_container).to receive(:delete).with(force: false, v: true)

        service.cleanup
      end
    end

    context "when force cleanup is requested" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true } })
      end

      it "force stops and deletes the container" do
        expect(mock_container).to receive(:stop).with(timeout: 0)
        expect(mock_container).to receive(:delete).with(force: true, v: true)

        service.cleanup(force: true)
      end
    end

    context "when cleanup fails" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => false } })
        allow(mock_container).to receive(:delete).and_raise(Docker::Error::ServerError.new("Docker error"))
      end

      it "attempts force cleanup" do
        expect(mock_container).to receive(:delete).with(force: false, v: true).and_raise(Docker::Error::ServerError)
        expect(mock_container).to receive(:delete).with(force: true, v: true)

        service.cleanup
      end

      # @spec EXECUTION-AUDIT-005
      it "records cleanup failure, retry, and success audit events" do
        create_cleanup_ledger_entry(agent_run, provider_resource_id: "abc123container")
        allow(mock_container).to receive(:delete).with(force: false, v: true).and_raise(Docker::Error::ServerError.new("Docker error"))
        allow(mock_container).to receive(:delete).with(force: true, v: true).and_return(true)

        service.cleanup

        events = ExecutionAuditEvent.for_agent_run(agent_run)
          .where(event_name: %w[
            execution.resource_cleanup_failed
            execution.resource_cleanup_retried
            execution.resource_cleanup_succeeded
          ])
          .order(:id)

        expect(events.pluck(:event_name)).to eq(%w[
          execution.resource_cleanup_failed
          execution.resource_cleanup_retried
          execution.resource_cleanup_succeeded
        ])
        expect(events.first.metadata["resource_ledger_id"]).to be_present
      end

      # @spec EXECUTION-AUDIT-005
      it "records the retry attempt even when the forced delete also fails" do
        allow(mock_container).to receive(:delete).with(force: false, v: true).and_raise(Docker::Error::ServerError.new("Docker error"))
        allow(mock_container).to receive(:delete).with(force: true, v: true).and_raise(Docker::Error::ServerError.new("still failing"))

        service.cleanup

        events = ExecutionAuditEvent.for_agent_run(agent_run)
          .where(event_name: %w[
            execution.resource_cleanup_failed
            execution.resource_cleanup_retried
            execution.resource_cleanup_succeeded
          ])
          .order(:id)

        expect(events.pluck(:event_name)).to eq(%w[
          execution.resource_cleanup_failed
          execution.resource_cleanup_retried
        ])
      end
    end

    it "clears the container reference" do
      service.cleanup

      expect(service.container).to be_nil
    end

    it "logs cleanup operations" do
      expect(agent_run).to receive(:log!).with("system", "container.cleanup.start",
        metadata: hash_including(container_id: "abc123container"))
      expect(agent_run).to receive(:log!).with("system", "container.cleanup.success",
        metadata: anything)

      service.cleanup
    end

    it "releases preview tunnel reservations after deleting the container" do
      preview_service = build_preview_tunnel_service(agent_run:, worktree_path:)
      allow(Containers::ProxyUrl).to receive(:resolve).with(backend: preview_service.backend, restricted: true).and_return("http://paid-proxy:3000")
      PreviewTunnelPortReservation.create!(reservation_key: "preview-token", tunnel_port: 8201)

      preview_service.provision
      preview_service.cleanup

      expect(PreviewTunnelPortReservation.find_by(reservation_key: "preview-token")).to be_nil
    end

    it "releases preview tunnel reservations when both delete attempts fail" do
      preview_service = build_preview_tunnel_service(agent_run:, worktree_path:)
      allow(Containers::ProxyUrl).to receive(:resolve).with(backend: preview_service.backend, restricted: true).and_return("http://paid-proxy:3000")
      PreviewTunnelPortReservation.create!(reservation_key: "preview-token", tunnel_port: 8201)
      allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => false } })
      allow(mock_container).to receive(:delete).and_raise(Docker::Error::ServerError.new("Docker error"))

      preview_service.provision

      expect { preview_service.cleanup }.not_to raise_error
      expect(PreviewTunnelPortReservation.find_by(reservation_key: "preview-token")).to be_nil
    end
  end

  describe "#container_running?" do
    before do
      service.provision
    end

    context "when container is running" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true } })
      end

      it "returns true" do
        expect(service.container_running?).to be true
      end
    end

    context "when container is stopped" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => false } })
      end

      it "returns false" do
        expect(service.container_running?).to be false
      end
    end

    context "when container is not provisioned" do
      let(:unprovisioned_service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

      it "returns false" do
        expect(unprovisioned_service.container_running?).to be false
      end
    end
  end

  describe "#container_status" do
    before do
      service.provision
    end

    it "returns running, exit code, OOM flag, and memory limit" do
      allow(mock_container).to receive(:info).and_return(
        { "State" => { "Running" => true, "ExitCode" => 0, "OOMKilled" => false },
          "HostConfig" => { "Memory" => 4_294_967_296 } }
      )

      expect(service.container_status).to eq(
        running: true, exit_code: nil, oom_killed: false, memory_limit_bytes: 4_294_967_296
      )
    end

    it "normalizes exit_code to nil while running even when Docker retains a prior exit code" do
      allow(mock_container).to receive(:info).and_return(
        { "State" => { "Running" => true, "ExitCode" => 137, "OOMKilled" => false },
          "HostConfig" => { "Memory" => 4_294_967_296 } }
      )

      expect(service.container_status).to include(running: true, exit_code: nil)
    end

    it "reports oom_killed and exit code when the container was OOM killed" do
      allow(mock_container).to receive(:info).and_return(
        { "State" => { "Running" => false, "ExitCode" => 137, "OOMKilled" => true },
          "HostConfig" => { "Memory" => 1024 } }
      )

      expect(service.container_status).to include(running: false, exit_code: 137, oom_killed: true, memory_limit_bytes: 1024)
    end

    it "returns an empty hash when the container is not provisioned" do
      unprovisioned = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(unprovisioned.container_status).to eq({})
    end

    it "returns an empty hash when inspection fails" do
      allow(mock_container).to receive(:refresh!).and_raise(Docker::Error::DockerError, "daemon down")

      expect(service.container_status).to eq({})
    end
  end

  describe ".with_container" do
    it "provisions container, yields, and cleans up" do
      yielded_service = nil

      described_class.with_container(agent_run: agent_run, worktree_path: worktree_path) do |svc|
        yielded_service = svc
        expect(svc.container).to eq(mock_container)
      end

      expect(yielded_service.container).to be_nil
    end

    it "cleans up even when block raises" do
      expect(mock_container).to receive(:delete)

      expect {
        described_class.with_container(agent_run: agent_run, worktree_path: worktree_path) do |_svc|
          raise "Something went wrong"
        end
      }.to raise_error("Something went wrong")
    end
  end

  describe "preparation scripts" do
    before do
      service.instance_variable_set(:@container, mock_container)
    end

    it "snapshots symlinks via readlink and regular files via cp -p, rejecting directories" do
      script = service.send(:materialize_script, nil)

      expect(script).to include('if [ -L "$PAID_PREPARATION_TARGET" ]; then')
      expect(script).to include('readlink "$PAID_PREPARATION_TARGET" > "$PAID_PREPARATION_STATE_DIR/symlink_target"')
      expect(script).to include('cp -p "$PAID_PREPARATION_TARGET" "$PAID_PREPARATION_STATE_DIR/backup"')
      expect(script).to include('elif [ -d "$PAID_PREPARATION_TARGET" ]; then')
      expect(script).to include("exit 1")
    end

    it "restores symlinks via ln -s, regular files via cp -p, and rejects directory mutations" do
      script = service.send(:cleanup_script)

      expect(script).to include('if [ -d "$PAID_PREPARATION_TARGET" ] && [ ! -L "$PAID_PREPARATION_TARGET" ]; then')
      expect(script).to include('ln -s -- "$(cat "$PAID_PREPARATION_STATE_DIR/symlink_target")" "$PAID_PREPARATION_TARGET"')
      expect(script).to include('cp -p "$PAID_PREPARATION_STATE_DIR/backup" "$PAID_PREPARATION_TARGET"')
    end

    it "does not raise when the preparation script exits successfully" do
      allow(mock_container).to receive(:exec).and_return([ "ok", "", 0 ])

      expect do
        service.send(:run_preparation_script, "echo ok", env: { "BASE" => "1" }, script_env: { "EXTRA" => "2" })
      end.not_to raise_error
    end

    it "raises ExecutionError when the preparation script exits non-zero" do
      allow(mock_container).to receive(:exec).and_return([ "", "base64: invalid input", 1 ])

      expect do
        service.send(:run_preparation_script, "echo bad", env: {}, script_env: {})
      end.to raise_error(described_class::ExecutionError, /base64: invalid input/)
    end
  end

  describe "Result" do
    describe ".success" do
      it "creates a success result with data" do
        result = Containers::Provision::Result.success(foo: "bar", count: 42)

        expect(result).to be_success
        expect(result).not_to be_failure
        expect(result[:foo]).to eq("bar")
        expect(result[:count]).to eq(42)
        expect(result.error).to be_nil
      end
    end

    describe ".failure" do
      it "creates a failure result with error and data" do
        result = Containers::Provision::Result.failure(error: "Something went wrong", foo: "bar")

        expect(result).to be_failure
        expect(result).not_to be_success
        expect(result.error).to eq("Something went wrong")
        expect(result[:foo]).to eq("bar")
      end
    end
  end

  describe "error classes" do
    describe "ProvisionError" do
      it "has a default message" do
        error = Containers::Provision::ProvisionError.new
        expect(error.message).to eq("Failed to provision container")
      end
    end

    describe "ExecutionError" do
      it "stores exit_code, stdout, and stderr" do
        error = Containers::Provision::ExecutionError.new(
          "Command failed", exit_code: 1, stdout: "out", stderr: "err"
        )

        expect(error.message).to eq("Command failed")
        expect(error.exit_code).to eq(1)
        expect(error.stdout).to eq("out")
        expect(error.stderr).to eq("err")
      end
    end

    describe "TimeoutError" do
      it "has a default message" do
        error = Containers::Provision::TimeoutError.new
        expect(error.message).to eq("Operation timed out")
      end
    end

    describe "StartupTimeoutError" do
      it "has a default message" do
        error = Containers::Provision::StartupTimeoutError.new
        expect(error.message).to eq("No output received within startup timeout")
      end

      it "is a subclass of TimeoutError" do
        expect(Containers::Provision::StartupTimeoutError.new).to be_a(Containers::Provision::TimeoutError)
      end
    end

    describe "IdleTimeoutError" do
      it "has a default message" do
        error = Containers::Provision::IdleTimeoutError.new
        expect(error.message).to eq("No output received within idle timeout")
      end

      it "is a subclass of TimeoutError" do
        expect(Containers::Provision::IdleTimeoutError.new).to be_a(Containers::Provision::TimeoutError)
      end
    end
  end

  describe "watchdog timeouts" do
    # The watchdog stops the container to unblock exec. We use a flag
    # to simulate the container being stopped mid-exec.
    let(:container_stopped) { Concurrent::AtomicBoolean.new(false) }

    before do
      service.provision
      # Speed up watchdog polling for tests (default is 1s)
      allow(service).to receive(:watchdog_poll_interval).and_return(0.05)
      # When the watchdog calls container.stop, set the flag so the
      # exec mock can unblock.
      allow(mock_container).to receive(:stop) do |**_opts|
        container_stopped.make_true
      end
    end

    context "with startup timeout" do
      it "fires when exec produces no output" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [], [], 137 ]
        end

        expect {
          service.execute("slow_command", timeout: 10, startup_timeout: 0.1)
        }.to raise_error(described_class::StartupTimeoutError)
      end

      it "does not fire when output arrives before deadline" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "output\n") if block
          [ [ "output\n" ], [], 0 ]
        end

        result = service.execute("fast_command", timeout: 10, startup_timeout: 2)
        expect(result).to be_success
      end
    end

    context "with idle timeout" do
      it "fires when output stops mid-stream" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [ "initial output\n" ], [], 137 ]
        end

        expect {
          service.execute("stalling_command", timeout: 10, idle_timeout: 0.1)
        }.to raise_error(described_class::IdleTimeoutError)
      end

      it "does not fire when output flows continuously" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          3.times do
            block.call(:stdout, "chunk\n") if block
            sleep 0.05
          end
          [ [ "chunk\nchunk\nchunk\n" ], [], 0 ]
        end

        result = service.execute("chatty_command", timeout: 10, idle_timeout: 2)
        expect(result).to be_success
      end
    end

    context "with wall-clock timeout" do
      it "fires when exec runs past the deadline without output" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [], [], 137 ]
        end

        expect {
          service.execute("hung_command", timeout: 0.1)
        }.to raise_error(described_class::TimeoutError, /timed out after 0.1 seconds/)
      end

      it "fires via post-exec deadline check when exec returns between watchdog ticks" do
        # Exec returns normally (no watchdog stop) but takes longer than the
        # wall-clock timeout. The post-exec check_deadline_exceeded! should catch it.
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          sleep 0.15 # exceed the 0.1s timeout
          block&.call(:stdout, "partial output\n")
          [ [ "partial output\n" ], [], 0 ]
        end

        # Use a long poll interval so the watchdog does NOT fire during exec
        allow(service).to receive(:watchdog_poll_interval).and_return(10)

        expect {
          service.execute("slow_command", timeout: 0.1)
        }.to raise_error(described_class::TimeoutError, /timed out after 0.1 seconds/)
      end
    end

    context "with startup timeout when exec raises Docker error" do
      it "detects the watchdog reason through the Docker error" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          raise Docker::Error::ServerError, "connection closed"
        end

        expect {
          service.execute("slow_command", timeout: 10, startup_timeout: 0.1)
        }.to raise_error(described_class::StartupTimeoutError)
      end

      it "logs the timeout when raising through the Docker error path" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          raise Docker::Error::ServerError, "connection closed"
        end
        allow(agent_run).to receive(:log!)

        expect {
          service.execute("slow_command", timeout: 10, startup_timeout: 0.1)
        }.to raise_error(described_class::StartupTimeoutError)

        expect(agent_run).to have_received(:log!).with(
          "system", "container.execute.timeout",
          metadata: hash_including(timeout_type: "StartupTimeoutError")
        )
      end
    end

    context "with idle timeout when exec raises Docker error" do
      it "detects the watchdog reason through the Docker error" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          raise Docker::Error::ServerError, "connection closed"
        end

        expect {
          service.execute("stalling_command", timeout: 10, idle_timeout: 0.1)
        }.to raise_error(described_class::IdleTimeoutError)
      end

      it "logs the timeout when raising through the Docker error path" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          raise Docker::Error::ServerError, "connection closed"
        end
        allow(agent_run).to receive(:log!)

        expect {
          service.execute("stalling_command", timeout: 10, idle_timeout: 0.1)
        }.to raise_error(described_class::IdleTimeoutError)

        expect(agent_run).to have_received(:log!).with(
          "system", "container.execute.timeout",
          metadata: hash_including(timeout_type: "IdleTimeoutError")
        )
      end
    end

    context "with wall-clock timeout when exec raises Docker error" do
      it "detects wall-clock timeout via post-exec deadline check" do
        # Exec raises a Docker error after the wall-clock deadline, but the
        # watchdog hasn't fired yet (long poll interval). The post-exec
        # check_deadline_exceeded! in the Docker error rescue should catch it.
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          sleep 0.15 # exceed the 0.1s timeout
          raise Docker::Error::ServerError, "connection reset"
        end
        allow(service).to receive(:watchdog_poll_interval).and_return(10)

        expect {
          service.execute("hung_command", timeout: 0.1)
        }.to raise_error(described_class::TimeoutError, /timed out after 0.1 seconds/)
      end

      it "reclassifies Docker API timeout race as TimeoutError when elapsed is near the timeout" do
        # Simulates the Docker `wait:` timer firing slightly before Ruby's
        # monotonic clock reaches the timeout value — the exact race from #1547.
        # We use a 1s timeout and sleep just under it so elapsed lands within
        # the DOCKER_TIMEOUT_SKEW_TOLERANCE (0.5s) window, triggering
        # reclassification of the Docker transport error as a TimeoutError.
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          sleep 0.85 # near but below the 1s timeout
          raise Docker::Error::DockerError, "read: connection reset by peer"
        end
        allow(service).to receive(:watchdog_poll_interval).and_return(10)

        expect {
          service.execute("hung_command", timeout: 1)
        }.to raise_error(described_class::TimeoutError, /timed out after 1 seconds/)
      end

      it "does not reclassify Docker error as timeout when elapsed is well below threshold" do
        # A Docker error that occurs well before the timeout should NOT be
        # reclassified — it is a genuine transport failure, not a timeout race.
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          sleep 0.01
          raise Docker::Error::DockerError, "connection refused"
        end
        allow(service).to receive(:watchdog_poll_interval).and_return(10)

        expect {
          service.execute("normal_command", timeout: 2)
        }.to raise_error(described_class::ExecutionError, /connection refused/)
      end
    end

    context "without startup and idle timeouts" do
      it "succeeds when only a wall-clock timeout is passed" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "output\n") if block
          [ [ "output\n" ], [], 0 ]
        end

        result = service.execute("normal_command", timeout: 10)
        expect(result).to be_success
      end
    end

    context "with heartbeat file" do
      let(:heartbeat_dir) { Dir.mktmpdir("heartbeat") }
      let(:heartbeat_path) { File.join(heartbeat_dir, "heartbeat") }

      after { FileUtils.remove_entry(heartbeat_dir) if File.directory?(heartbeat_dir) }

      it "suppresses idle timeout while heartbeat file is touched" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          10.times do
            FileUtils.touch(heartbeat_path)
            sleep 0.05
          end
          [ [ "initial output\n" ], [], 0 ]
        end

        result = service.execute(
          "working_silently",
          timeout: 10,
          idle_timeout: 0.2,
          heartbeat_path: heartbeat_path
        )
        expect(result).to be_success
        expect(container_stopped.true?).to be false
      end

      it "does not suppress startup timeout when a fresh heartbeat has no real output (regression #2502)" do
        # A heartbeat file kept continuously fresh while the agent produces NO
        # stdout/stderr must NOT extend the startup window. The authoritative
        # clock fires :startup at ~startup_timeout regardless of heartbeat
        # freshness — previously this suppressed startup for up to the
        # wall-clock cap, then mislabeled the kill as "within startup_timeout".
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Timeout.timeout(5) do
            until container_stopped.true?
              FileUtils.touch(heartbeat_path)
              sleep 0.01
            end
          end
          [ [], [], 137 ]
        end

        expect {
          service.execute(
            "waiting_on_llm",
            timeout: 10,
            startup_timeout: 0.2,
            heartbeat_path: heartbeat_path
          )
        }.to raise_error(described_class::StartupTimeoutError) do |error|
          # Fired from the authoritative clock near startup_timeout, nowhere
          # near the 10s wall-clock cap.
          expect(error.diagnostics[:elapsed_seconds]).to be < 1
        end
      end

      it "does not fire startup when output arrives after a silent delay within startup_timeout" do
        # Preserves the legitimate "silent MCP init then produces output" case:
        # output before startup_timeout keeps the run alive.
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          sleep 0.2
          block.call(:stdout, "finally output\n") if block
          [ [ "finally output\n" ], [], 0 ]
        end

        result = service.execute(
          "waiting_on_llm",
          timeout: 10,
          startup_timeout: 1.0,
          heartbeat_path: heartbeat_path
        )
        expect(result).to be_success
        expect(container_stopped.true?).to be false
      end

      it "still fires idle timeout when heartbeat file is not touched" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [ "initial output\n" ], [], 137 ]
        end

        expect {
          service.execute(
            "stalling_command",
            timeout: 10,
            idle_timeout: 0.1,
            heartbeat_path: heartbeat_path
          )
        }.to raise_error(described_class::IdleTimeoutError)
      end

      it "ignores a stale heartbeat file that was not touched during exec" do
        FileUtils.touch(heartbeat_path, mtime: Time.now - 3600)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [ "initial output\n" ], [], 137 ]
        end

        expect {
          service.execute(
            "stalling_command",
            timeout: 10,
            idle_timeout: 0.1,
            heartbeat_path: heartbeat_path
          )
        }.to raise_error(described_class::IdleTimeoutError)
      end

      it "suppresses wall-clock timeout when heartbeat is fresh" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Thread.new do
            20.times do
              FileUtils.touch(heartbeat_path)
              sleep 0.01
            end
          end
          # With heartbeat suppressing wall-clock timeout, exec completes normally
          sleep 0.25
          [ [], [], 0 ]
        end

        result = service.execute(
          "long_running",
          timeout: 0.2,
          heartbeat_path: heartbeat_path
        )
        expect(result).to be_success
      end

      it "fires wall-clock timeout when heartbeat is stale" do
        # Touch heartbeat once at start, then let it go stale
        FileUtils.touch(heartbeat_path)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [ "initial output\n" ], [], 137 ]
        end
        allow(service).to receive(:watchdog_poll_interval).and_return(0.05)

        expect {
          service.execute(
            "long_running",
            timeout: 0.15,
            heartbeat_path: heartbeat_path
          )
        }.to raise_error(described_class::TimeoutError)
      end

      it "tolerates a missing heartbeat file path and falls back to stdout activity" do
        missing_path = File.join(heartbeat_dir, "does-not-exist")
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "output\n") if block
          [ [ "output\n" ], [], 0 ]
        end

        result = service.execute(
          "fast_command",
          timeout: 10,
          idle_timeout: 2,
          heartbeat_path: missing_path
        )
        expect(result).to be_success
      end

      it "suppresses idle timeout when the heartbeat is only visible inside the container" do
        heartbeat_path = "#{described_class::HEARTBEAT_MOUNT_POINT}/.paid-heartbeat"

        allow(mock_container).to receive(:exec).with([ "sh", "-c", "working_silently" ], any_args) do |_, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          10.times { sleep 0.05 }
          [ [ "initial output\n" ], [], 0 ]
        end
        allow(service).to receive(:watchdog_poll_interval).and_return(0.05)
        allow(service).to receive(:container_heartbeat_mtime).with(heartbeat_path) { Time.now }

        result = service.execute(
          "working_silently",
          timeout: 10,
          idle_timeout: 1.2,
          heartbeat_path: heartbeat_path
        )
        expect(result).to be_success
        expect(container_stopped.true?).to be false
      end
    end

    context "with startup timeout enforced from the authoritative clock" do
      it "labels a no-output run that also blew past wall-clock as startup, not wall-clock" do
        # Defect #2 from issue #2502: :startup must take precedence so a no-output
        # run is never mislabeled wall_clock. The long poll interval forces the
        # first evaluation to happen after BOTH deadlines have elapsed, proving
        # startup wins regardless of ordering.
        allow(service).to receive(:watchdog_poll_interval).and_return(10)
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          sleep 0.25
          [ [], [], 0 ]
        end

        expect {
          service.execute("hung_no_output", timeout: 0.2, startup_timeout: 0.1)
        }.to raise_error(described_class::StartupTimeoutError)
      end

      it "applies idle timeout normally once first output is received" do
        # After real output, the run is no longer in the startup window; a
        # subsequent stall trips the idle timeout (not startup).
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block.call(:stdout, "initial output\n") if block
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [ "initial output\n" ], [], 137 ]
        end

        expect {
          service.execute("then_idle", timeout: 10, startup_timeout: 2, idle_timeout: 0.1)
        }.to raise_error(described_class::IdleTimeoutError)
      end
    end
  end

  describe "#start_watchdog" do
    let(:watchdog_mutex) { Mutex.new }
    let(:watchdog_state) { { exec_completed: false, timeout_reason: nil } }
    let(:watchdog_ctx) do
      described_class::WatchdogContext.new(
        container: mock_container,
        mutex: watchdog_mutex,
        output_received_ref: -> { false },
        last_activity_ref: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        exec_completed_ref: -> { watchdog_state[:exec_completed] },
        timeout_reason_setter: ->(reason) { watchdog_state[:timeout_reason] = reason },
        startup_timeout: 10,
        idle_timeout: nil,
        wall_clock_timeout: nil,
        started_at_ref: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        heartbeat_path: "/tmp/heartbeat"
      )
    end

    before do
      service.provision
      allow(service).to receive(:watchdog_poll_interval).and_return(0.05)
    end

    it "logs unexpected poll errors and keeps running" do
      allow(service).to receive(:log_system)
      heartbeat_checks = 0
      allow(service).to receive(:heartbeat_age_seconds).with("/tmp/heartbeat") do
        heartbeat_checks += 1
        raise Errno::ELOOP, "/tmp/heartbeat" if heartbeat_checks == 1

        nil
      end

      watchdog = service.send(:start_watchdog, watchdog_ctx)

      sleep 0.12
      watchdog_state[:exec_completed] = true
      service.send(:stop_watchdog, watchdog)

      expect(service).to have_received(:log_system).with(
        "container.watchdog.poll_failed",
        error: anything,
        error_class: "Errno::ELOOP"
      )
      expect(heartbeat_checks).to be >= 2
      expect(watchdog_state[:timeout_reason]).to be_nil
    end
  end

  describe "#watchdog_stop_container!" do
    before { service.provision }

    it "stops the container on the first attempt" do
      allow(mock_container).to receive(:stop)
      allow(service).to receive(:log_system)

      result = service.send(:watchdog_stop_container!, mock_container)

      expect(result).to be true
      expect(mock_container).to have_received(:stop).once
    end

    it "retries and succeeds on the second attempt" do
      call_count = 0
      allow(mock_container).to receive(:stop) do
        call_count += 1
        raise Docker::Error::DockerError, "busy" if call_count == 1
      end
      allow(service).to receive(:log_system)

      result = service.send(:watchdog_stop_container!, mock_container)

      expect(result).to be true
      expect(mock_container).to have_received(:stop).twice
      expect(service).to have_received(:log_system).with(
        "container.watchdog.stop_failed",
        error: "busy",
        attempt: 1,
        max_attempts: described_class::WATCHDOG_STOP_ATTEMPTS
      )
    end

    it "retries all attempts via backend.stop_container" do
      call_count = 0
      allow(mock_container).to receive(:stop) do
        call_count += 1
        raise Docker::Error::DockerError, "busy" if call_count < described_class::WATCHDOG_STOP_ATTEMPTS
      end
      allow(service).to receive(:log_system)

      result = service.send(:watchdog_stop_container!, mock_container)

      expect(result).to be true
      expect(mock_container).to have_received(:stop).exactly(described_class::WATCHDOG_STOP_ATTEMPTS).times
    end

    it "logs stop_exhausted when all attempts fail" do
      allow(mock_container).to receive(:stop).and_raise(Docker::Error::DockerError, "busy")
      allow(service).to receive(:log_system)

      result = service.send(:watchdog_stop_container!, mock_container)

      expect(result).to be false
      expect(service).to have_received(:log_system).with(
        "container.watchdog.stop_exhausted",
        message: "All #{described_class::WATCHDOG_STOP_ATTEMPTS} stop attempts failed"
      )
    end
  end

  describe "#heartbeat_age_seconds" do
    let(:heartbeat_dir) { Dir.mktmpdir("heartbeat-age") }
    let(:heartbeat_path) { File.join(heartbeat_dir, "heartbeat") }

    after { FileUtils.remove_entry(heartbeat_dir) if File.directory?(heartbeat_dir) }

    it "advances a cached heartbeat age with monotonic time when wall clock moves backward" do
      File.write(heartbeat_path, "")
      heartbeat_mtime = Time.utc(2026, 4, 29, 12, 0, 0)
      service

      allow(File).to receive(:mtime).with(heartbeat_path).and_return(heartbeat_mtime)
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0, 105.0)
      allow(Time).to receive(:now).and_return(
        heartbeat_mtime + 10,
        heartbeat_mtime - 60
      )

      first_age = service.send(:heartbeat_age_seconds, heartbeat_path)
      second_age = service.send(:heartbeat_age_seconds, heartbeat_path)

      expect(first_age).to eq(10.0)
      expect(second_age).to eq(15.0)
    end

    it "reads container-visible heartbeat mtimes via docker exec" do
      service.with_existing_container(mock_container)
      heartbeat_path = "#{described_class::HEARTBEAT_MOUNT_POINT}/.paid-heartbeat"
      heartbeat_mtime = Time.utc(2026, 4, 29, 12, 0, 0)

      allow(mock_container).to receive(:exec).with(
        [ "sh", "-lc", "test -e /paid-heartbeat/.paid-heartbeat && stat -c %Y /paid-heartbeat/.paid-heartbeat" ],
        wait: 5,
        user: "agent"
      ).and_return([ [ "#{heartbeat_mtime.to_i}\n" ], [], 0 ])
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(100.0)
      allow(Time).to receive(:now).and_return(heartbeat_mtime + 10)

      age = service.send(:heartbeat_age_seconds, heartbeat_path)

      expect(age).to eq(10.0)
    end
  end

  describe "#strip_codex_project_sections" do
    let(:service) { described_class.new(agent_run: agent_run, project: project) }

    it "strips [projects.*] sections and their key-value pairs" do
      toml = <<~TOML
        model = "gpt-5"
        [projects."/Users/bart/Projects/paid"]
        trust_level = "trusted"
        [projects."/workspaces/other"]
        trust_level = "untrusted"
        [notice]
        key = "value"
      TOML

      result = service.send(:strip_codex_project_sections, toml)

      expect(result).to eq("model = \"gpt-5\"\n[notice]\nkey = \"value\"\n")
    end

    it "returns content unchanged when no [projects] sections exist" do
      toml = "model = \"gpt-5\"\n"

      result = service.send(:strip_codex_project_sections, toml)

      expect(result).to eq(toml)
    end

    it "handles consecutive [projects.*] sections" do
      toml = <<~TOML
        model = "gpt-5"
        [projects."/a"]
        trust_level = "trusted"
        [projects."/b"]
        trust_level = "trusted"
        [features]
        multi_agent = true
      TOML

      result = service.send(:strip_codex_project_sections, toml)

      expect(result).to eq("model = \"gpt-5\"\n[features]\nmulti_agent = true\n")
    end
  end

  describe "#sanitize_codex_host_config" do
    let(:service) { described_class.new(agent_run: agent_run, project: project) }

    it "replaces host model settings with an escaped Paid-selected Codex model" do
      allow(service).to receive(:codex_container_model_id).and_return('gpt-"quoted"')

      result = service.send(:sanitize_codex_host_config, <<~TOML)
          model = "gpt-5.5"
          model_reasoning_effort = "medium"
        [features]
        multi_agent = true
      TOML

      expect(result).to eq(<<~TOML)
        model = "gpt-\\"quoted\\""
        [features]
        multi_agent = true
      TOML
    end

    it "falls back to the active mid-tier Codex model when the run tier has no Codex default" do
      create(:llm_model, :openai, model_id: "gpt-5.1", tier: "mid", capability_score: 9.0)
      high_model = create(:llm_model, model_id: "claude-opus-test", provider: "anthropic", tier: "high")
      create(:model_selection, agent_run: agent_run, llm_model: high_model, tier: "high")

      result = service.send(:sanitize_codex_host_config, "model = \"gpt-5.5\"\n")

      expect(result).to eq("model = \"gpt-5.1\"\n")
    end

    it "uses subscription-safe Codex defaults for subscription-auth Codex runners" do # @spec MODEL-SELECTION-005
      codex_runner = create(:runner, user: project.created_by, runner_key: "codex", auth_type: "subscription")
      agent_run.update!(runner: codex_runner)
      create(:llm_model, :openai, model_id: "gpt-5.6-preview", tier: "mid", capability_score: 9.9)
      create(:llm_model, :openai, model_id: "gpt-5.2-codex", tier: "mid", capability_score: 9.0)

      result = service.send(:sanitize_codex_host_config, "model = \"gpt-5.6-preview\"\n")

      expect(result).to eq("model = \"gpt-5.2-codex\"\n")
    end

    it "uses subscription-safe Codex defaults when subscription auth is active without a bound runner" do # @spec MODEL-SELECTION-005
      create(:llm_model, :openai, model_id: "gpt-5.6-preview", tier: "mid", capability_score: 9.9)
      create(:llm_model, :openai, model_id: "gpt-5.2-codex", tier: "mid", capability_score: 9.0)
      allow(service).to receive(:codex_subscription_auth?).and_return(true)

      result = service.send(:sanitize_codex_host_config, "model = \"gpt-5.6-preview\"\n")

      expect(result).to eq("model = \"gpt-5.2-codex\"\n")
    end
  end

  describe "#codex_model_config_line" do
    let(:service) { described_class.new(agent_run: agent_run, project: project) }

    it "returns a top-level model line for the Paid-selected Codex model" do
      create(:llm_model, :openai, model_id: "gpt-5.1", tier: "mid", capability_score: 9.0)

      expect(service.send(:codex_model_config_line)).to eq('model = "gpt-5.1"')
    end

    it "escapes quotes in the model id" do
      allow(service).to receive(:codex_container_model_id).and_return('gpt-"x"')

      expect(service.send(:codex_model_config_line)).to eq('model = "gpt-\\"x\\""')
    end

    it "returns nil when no Codex model resolves so the CLI default is left in place" do
      allow(service).to receive(:codex_container_model_id).and_return(nil)

      expect(service.send(:codex_model_config_line)).to be_nil
    end
  end

  describe "Claude credential keep-warm (RDR-041 Phase 3)" do
    let(:claude_config_dir) { Dir.mktmpdir("claude-config") }
    let(:service) { described_class.new(agent_run: agent_run, project: project) }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(claude_config_dir)
      allow(service).to receive(:claude_local_config_path).and_return(nil)
      allow(service).to receive(:log_system)
    end

    after do
      FileUtils.rm_rf(claude_config_dir)
    end

    describe "#claude_credentials_source_path" do
      context "when CLAUDE_CONFIG_DIR contains .credentials.json" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
        end

        it "returns the host config dir" do
          expect(service.send(:claude_credentials_source_path)).to eq(claude_config_dir)
        end
      end

      context "when no .credentials.json exists" do
        it "returns nil" do
          expect(service.send(:claude_credentials_source_path)).to be_nil
        end
      end

      context "when CLAUDE_CONFIG_DIR is nil but local path has credentials" do
        let(:local_dir) { Dir.mktmpdir("claude-local") }

        before do
          allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
          allow(service).to receive(:claude_local_config_path).and_return(local_dir)
          File.write(File.join(local_dir, ".credentials.json"), "{}")
        end

        after { FileUtils.rm_rf(local_dir) }

        it "returns the local config dir" do
          expect(service.send(:claude_credentials_source_path)).to eq(local_dir)
        end
      end
    end

    describe "#claude_native_credential_expiry" do
      context "when .credentials.json has native claudeAiOauth shape" do
        let(:future_expiry) { (Time.now + 2.hours).iso8601 }

        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "claudeAiOauth" => {
              "accessToken" => "tok",
              "refreshToken" => "ref",
              "expiresAt" => future_expiry
            }
          ))
        end

        it "parses the expiry from the claudeAiOauth nesting" do
          expiry = service.send(:claude_native_credential_expiry)
          expect(expiry).to be_within(2.seconds).of(Time.parse(future_expiry))
        end
      end

      context "when .credentials.json has flat expiresAt shape" do
        let(:future_expiry) { (Time.now + 2.hours).iso8601 }

        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "expiresAt" => future_expiry,
            "oauth_token" => "tok"
          ))
        end

        it "parses the flat expiresAt" do
          expiry = service.send(:claude_native_credential_expiry)
          expect(expiry).to be_within(2.seconds).of(Time.parse(future_expiry))
        end
      end

      context "when no .credentials.json exists" do
        it "returns nil" do
          expect(service.send(:claude_native_credential_expiry)).to be_nil
        end
      end

      context "when .credentials.json has no expiry field" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), '{"oauth_token":"tok"}')
        end

        it "returns nil" do
          expect(service.send(:claude_native_credential_expiry)).to be_nil
        end
      end

      context "when .credentials.json contains invalid JSON" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), "not-json")
        end

        it "returns nil without raising" do
          expect(service.send(:claude_native_credential_expiry)).to be_nil
        end
      end
    end

    describe "#claude_credentials_near_expiry?" do
      context "when credential expires within the refresh window" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "claudeAiOauth" => { "expiresAt" => (Time.now + 1.hour).iso8601 }
          ))
        end

        it "returns true" do
          expect(service.send(:claude_credentials_near_expiry?)).to be true
        end
      end

      context "when credential expires beyond the refresh window" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "claudeAiOauth" => { "expiresAt" => (Time.now + 12.hours).iso8601 }
          ))
        end

        it "returns false" do
          expect(service.send(:claude_credentials_near_expiry?)).to be false
        end
      end

      context "when credential is already expired" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "claudeAiOauth" => { "expiresAt" => (Time.now - 1.hour).iso8601 }
          ))
        end

        it "returns true" do
          expect(service.send(:claude_credentials_near_expiry?)).to be true
        end
      end

      context "when expiry is unknown" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), '{"oauth_token":"tok"}')
        end

        it "returns false (don't speculate)" do
          expect(service.send(:claude_credentials_near_expiry?)).to be false
        end
      end
    end

    describe "#claude_subscription_auth?" do
      before do
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(service).to receive(:claude_local_config_path).and_return(nil)
      end

      it "returns true when an active managed Claude runner credential exists for the account" do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token"
        )

        expect(service.send(:claude_subscription_auth?)).to be(true)
      end

      it "ignores account-managed Claude runner credentials that are not OAuth tokens" do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "api_key"
        )

        expect(service.send(:claude_subscription_auth?)).to be(false)
      end
    end

    describe "#with_claude_auth_lock" do
      before do
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
      end

      it "creates a lockfile scoped to the source path" do
        lockfile = service.send(:claude_auth_lockfile_path)
        FileUtils.rm_f(lockfile)

        yielded = false
        service.send(:with_claude_auth_lock) { yielded = true }

        expect(yielded).to be true
        expect(File.exist?(lockfile)).to be true
      end

      it "logs lock acquisition and release" do
        service.send(:with_claude_auth_lock) { nil }

        expect(service).to have_received(:log_system).with(
          "container.claude_auth_lock.acquired", hash_including(:lockfile)
        )
        expect(service).to have_received(:log_system).with(
          "container.claude_auth_lock.released", hash_including(:lockfile)
        )
      end

      it "still yields when lock times out" do
        allow(service).to receive(:acquire_lock_with_timeout).and_return(false)

        yielded = false
        service.send(:with_claude_auth_lock) { yielded = true }

        expect(yielded).to be true
        expect(service).to have_received(:log_system).with(
          "container.claude_auth_lock.timeout", anything
        )
      end
    end

    describe "#exchange_claude_refresh_token!" do
      before do
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
      end

      context "when AgentHarness::Authentication does not support exchange_refresh_token" do
        before do
          allow(AgentHarness::Authentication).to receive(:exchange_refresh_token_supported?)
            .with(:claude)
            .and_return(false)
        end

        it "logs unsupported and returns false" do
          result = service.send(:exchange_claude_refresh_token!)

          expect(result).to be false
          expect(service).to have_received(:log_system).with(
            "container.claude_auth_refresh.unsupported", hash_including(:note)
          )
        end
      end

      context "when AgentHarness::Authentication supports exchange_refresh_token" do
        before do
          allow(AgentHarness::Authentication).to receive(:exchange_refresh_token_supported?)
            .with(:claude)
            .and_return(true)
        end

        it "calls exchange_refresh_token with the source path in CLAUDE_CONFIG_DIR and returns true on success" do
          allow(AgentHarness::Authentication).to receive(:exchange_refresh_token)
            .with(:claude)
            .and_return({ success: true })

          result = service.send(:exchange_claude_refresh_token!)

          expect(result).to be true
          expect(AgentHarness::Authentication).to have_received(:exchange_refresh_token)
            .with(:claude)
          expect(service).to have_received(:log_system).with(
            "container.claude_auth_refreshed", hash_including(:source_path)
          )
        end

        it "logs and returns false on AgentHarness::AuthenticationError" do
          allow(AgentHarness::Authentication).to receive(:exchange_refresh_token)
            .and_raise(AgentHarness::AuthenticationError.new("refresh_token_reused"))

          result = service.send(:exchange_claude_refresh_token!)

          expect(result).to be false
          expect(service).to have_received(:log_system).with(
            "container.claude_auth_refresh_failed", hash_including(:error)
          )
        end

        it "logs and returns false on AgentHarness::Error" do
          allow(AgentHarness::Authentication).to receive(:exchange_refresh_token)
            .and_raise(AgentHarness::Error.new("network error"))

          result = service.send(:exchange_claude_refresh_token!)

          expect(result).to be false
          expect(service).to have_received(:log_system).with(
            "container.claude_auth_refresh_failed", hash_including(:error)
          )
        end
      end
    end

    describe "#refresh_claude_credentials_if_near_expiry!" do
      context "when credential is not near expiry" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "claudeAiOauth" => { "expiresAt" => (Time.now + 12.hours).iso8601 }
          ))
        end

        it "does not call exchange_claude_refresh_token!" do
          allow(service).to receive(:exchange_claude_refresh_token!)

          service.send(:refresh_claude_credentials_if_near_expiry!)

          expect(service).not_to have_received(:exchange_claude_refresh_token!)
        end
      end

      context "when credential is near expiry" do
        before do
          File.write(File.join(claude_config_dir, ".credentials.json"), JSON.generate(
            "claudeAiOauth" => { "expiresAt" => (Time.now + 1.hour).iso8601 }
          ))
          allow(service).to receive(:exchange_claude_refresh_token!).and_return(true)
        end

        it "calls exchange_claude_refresh_token! under a lock" do
          service.send(:refresh_claude_credentials_if_near_expiry!)

          expect(service).to have_received(:exchange_claude_refresh_token!)
        end

        it "does not call exchange after another process already refreshed while waiting for lock" do
          call_count = 0
          allow(service).to receive(:claude_credentials_near_expiry?) do
            call_count += 1
            # First call: near expiry; second call (post-lock): already refreshed
            call_count == 1
          end

          service.send(:refresh_claude_credentials_if_near_expiry!)

          # exchange not called because second near_expiry? check returned false
          expect(service).not_to have_received(:exchange_claude_refresh_token!)
        end
      end

      context "when no subscription auth is present" do
        before do
          allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
          allow(service).to receive(:claude_local_config_path).and_return(nil)
          allow(service).to receive(:exchange_claude_refresh_token!)
        end

        it "is a no-op" do
          service.send(:refresh_claude_credentials_if_near_expiry!)
          expect(service).not_to have_received(:exchange_claude_refresh_token!)
        end
      end
    end

    describe "#seed_claude_credentials! with keep-warm preflight" do
      before do
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
        allow(service).to receive(:refresh_claude_credentials_if_near_expiry!)
        allow(service).to receive(:seed_host_credentials!)
        allow(service).to receive(:seed_local_credentials!)
      end

      it "calls refresh_claude_credentials_if_near_expiry! before seeding" do
        service.send(:seed_claude_credentials!)
        expect(service).to have_received(:refresh_claude_credentials_if_near_expiry!)
      end

      it "does not call refresh when no subscription auth is present" do
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(service).to receive(:claude_local_config_path).and_return(nil)

        service.send(:seed_claude_credentials!)

        expect(service).not_to have_received(:refresh_claude_credentials_if_near_expiry!)
      end

      it "skips host and local credential seeding when a managed token is present" do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token"
        )
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(service).to receive(:claude_local_config_path).and_return(nil)

        service.send(:seed_claude_credentials!)

        expect(service).not_to have_received(:refresh_claude_credentials_if_near_expiry!)
        expect(service).not_to have_received(:seed_host_credentials!)
        expect(service).not_to have_received(:seed_local_credentials!)
      end

      it "materializes expired but refreshable managed native credentials into the container" do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token",
          token: file_fixture("claude_credentials_expired.json").read
        )
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(service).to receive(:claude_local_config_path).and_return(nil)
        allow(service).to receive(:write_container_file)
        allow(service).to receive(:log_system)

        service.send(:seed_claude_credentials!)

        expect(service).not_to have_received(:refresh_claude_credentials_if_near_expiry!)
        expect(service).not_to have_received(:seed_host_credentials!)
        expect(service).not_to have_received(:seed_local_credentials!)
        expect(service).to have_received(:write_container_file).with(
          "/home/agent/.claude/.credentials.json",
          include("expired-access-token")
        )
      end

      it "tags host and local credential seeding with auth_source: host_forwarded (#2959)" do
        allow(service).to receive(:seed_host_credentials!).and_return(true)

        service.send(:seed_claude_credentials!)

        expect(service).to have_received(:seed_host_credentials!).with(
          hash_including(auth_source: RunnerAuthAttempt::AUTH_SOURCE_HOST_FORWARDED)
        )
      end

      it "tags the managed credential materialization log with auth_source: managed (#2959)" do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token",
          token: file_fixture("claude_credentials_expired.json").read
        )
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(service).to receive(:claude_local_config_path).and_return(nil)
        allow(service).to receive(:write_container_file)
        allow(service).to receive(:log_system)

        service.send(:seed_claude_credentials!)

        expect(service).to have_received(:log_system).with(
          "container.claude_credentials_seeded",
          hash_including(auth_source: RunnerAuthAttempt::AUTH_SOURCE_MANAGED)
        )
      end
    end
  end

  describe "#cleanup_execution_preparation" do
    let(:service) { described_class.new(agent_run: agent_run, project: project) }
    let(:cleanup_steps) { [ { "PAID_PREPARATION_TARGET" => "/x", "PAID_PREPARATION_STATE_DIR" => "/x.state" } ] }

    it "skips the restore and invalidates when the container is not running" do
      allow(service).to receive(:container_running?).and_return(false)
      allow(service).to receive(:invalidate_container_after_preparation_cleanup_failure!)

      expect(service).not_to receive(:run_preparation_cleanup_step)

      expect {
        service.send(:cleanup_execution_preparation, cleanup_steps, env: {})
      }.not_to raise_error
      expect(service).to have_received(:invalidate_container_after_preparation_cleanup_failure!)
    end

    it "does not raise a terminal restore error when the container dies mid-restore" do
      allow(service).to receive(:invalidate_container_after_preparation_cleanup_failure!)
      allow(service).to receive_messages(container_running?: true, run_preparation_cleanup_step: Containers::Provision::ExecutionError.new("container abc is not running"))

      expect {
        service.send(:cleanup_execution_preparation, cleanup_steps, env: {})
      }.not_to raise_error
      expect(service).to have_received(:invalidate_container_after_preparation_cleanup_failure!)
    end

    it "raises for a genuine restore failure while the container is still running" do
      allow(service).to receive(:invalidate_container_after_preparation_cleanup_failure!)
      allow(service).to receive_messages(container_running?: true, run_preparation_cleanup_step: Containers::Provision::ExecutionError.new("missing runtime preparation backup"))

      expect {
        service.send(:cleanup_execution_preparation, cleanup_steps, env: {})
      }.to raise_error(Containers::Provision::ExecutionError, /Failed to restore prepared runtime state/)
    end
  end

  # RDR-058: managed subscription credentials must never leak across accounts
  # into another account's run. @spec EXECUTION-ISOLATION-003
  describe "#managed_subscription_credential_scope_for" do
    it "only resolves credentials belonging to the run's own account" do
      own_credential = create(
        :runner_credential,
        account: project.account,
        created_by: project.created_by,
        runner_key: "claude",
        auth_kind: "oauth_token"
      )

      other_account = create(:account)
      other_project = create(:project, account: other_account)
      create(
        :runner_credential,
        account: other_account,
        created_by: other_project.created_by,
        runner_key: "claude",
        auth_kind: "oauth_token"
      )

      scope = service.send(:managed_subscription_credential_scope_for, "claude")

      expect(scope).to contain_exactly(own_credential)
    end

    it "returns nil when the record's project has no account" do
      allow(project).to receive(:account).and_return(nil)

      expect(service.send(:managed_subscription_credential_scope_for, "claude")).to be_nil
    end
  end

  # RDR-041/RDR-048: subscription auth host eligibility contract (#2963).
  describe "subscription auth host eligibility" do
    let(:remote_backend) do
      instance_double(
        Containers::Backends::RemoteDocker,
        identifier: "elguapo",
        remote?: true,
        supports_host_paths?: false
      )
    end
    let(:claude_config_dir) { Dir.mktmpdir("claude-host") }

    after do
      FileUtils.rm_rf(claude_config_dir) if claude_config_dir && Dir.exist?(claude_config_dir)
    end

    def remote_service
      described_class.new(agent_run: agent_run, project: project, backend: remote_backend)
    end

    context "when a managed Claude credential carries the run" do
      before do
        create(
          :runner_credential,
          account: project.account,
          created_by: project.created_by,
          runner_key: "claude",
          auth_kind: "oauth_token",
          token: JSON.generate(
            "claudeAiOauth" => {
              "accessToken" => "managed-access",
              "refreshToken" => "managed-refresh",
              "expiresAt" => 12.hours.from_now.iso8601
            }
          )
        )
        # A host .credentials.json also exists, but the managed credential is
        # remote-safe so it must NOT be rejected on remote Docker.
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(claude_config_dir)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("PAID_PROXY_EXTERNAL_URL").and_return("http://paid.example:3000")
      end

      it "does not reject the run on the host-path-incapable backend" do
        svc = remote_service
        allow(svc).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: nil,
          copilot_local_config_path: nil,
          codex_subscription_auth_host_mount_path: nil
        )

        expect { svc.send(:validate_backend_mount_support!) }.not_to raise_error
      end
    end

    context "when only host-forwarded Claude auth exists" do
      before do
        File.write(File.join(claude_config_dir, ".credentials.json"), "{}")
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(claude_config_dir)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
      end

      it "rejects with a named requires_host_bind_mount reason and managed-auth guidance" do
        svc = remote_service
        allow(svc).to receive_messages(
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          gemini_local_config_path: nil,
          copilot_local_config_path: nil,
          codex_subscription_auth_host_mount_path: nil
        )

        expect {
          svc.send(:validate_backend_mount_support!)
        }.to raise_error(
          Containers::Provision::ProvisionError,
          /requires_host_bind_mount.*Configure a managed claude credential/
        )
      end
    end

    context "when only host-forwarded Codex auth exists" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
      end

      it "rejects with requires_host_bind_mount and directs to a host-path backend" do
        svc = remote_service
        allow(svc).to receive_messages(
          claude_config_host_path: nil,
          claude_local_config_path: nil,
          codex_local_config_path: nil,
          codex_subscription_auth_host_mount_path: "/host/codex",
          gemini_config_host_path: nil,
          gemini_local_config_path: nil,
          copilot_config_host_path: nil,
          copilot_local_config_path: nil
        )

        expect {
          svc.send(:validate_backend_mount_support!)
        }.to raise_error(
          Containers::Provision::ProvisionError,
          /Codex subscription auth \(requires_host_bind_mount\).*host-path-capable backend/
        )
      end
    end
  end
end
