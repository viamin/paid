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

    it "applies container_memory_bytes from user settings" do
      create(:user_setting, user: project.created_by, container_memory_bytes: 2 * 1024 * 1024 * 1024)

      svc = described_class.new(agent_run: agent_run, worktree_path: worktree_path)

      expect(svc.options[:memory_bytes]).to eq(2 * 1024 * 1024 * 1024)
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

      it "logs the provision start and success" do
        expect(agent_run).to receive(:log!).with("system", "container.provision.start",
          metadata: hash_including(image: "paid-agent:latest")).ordered
        expect(agent_run).to receive(:log!).with("system", "container.heartbeat_dir_prepared",
          metadata: hash_including(:path)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.network.ready",
          metadata: hash_including(network: NetworkPolicy::NETWORK_NAME)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.ownership_batch_fixed",
          metadata: hash_including(dirs_count: 12)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.codex_config_seeded",
          metadata: {}).ordered
        expect(agent_run).to receive(:log!).with("system", "container.firewall.applied",
          metadata: hash_including(container_id: "abc123container")).ordered
        expect(agent_run).to receive(:log!).with("system", "container.provision.success",
          metadata: hash_including(container_id: "abc123container")).ordered

        service.provision
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
              script.include?("/home/agent/.aider") &&
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
          expect(tmpfs["/home/agent/.cache"]).to eq("size=#{512 * 1024 * 1024},mode=0755")
          mock_container
        end

        service.provision
      end

      # Regression: Docker's default tmpfs flags include noexec, which makes
      # mkmf's File.executable? check fail when bundle install builds native
      # gem extensions in /tmp — surfacing as a misleading "compiler failed
      # to generate an executable file" error (e.g. bigdecimal extconf).
      # Coding/review/rebase prompts all run bundle install as step 1, and
      # review-goal runs additionally set BUNDLE_PATH=/tmp/bundle.
      it "mounts /tmp tmpfs with exec so bundle install can build native gems" do
        expect(Docker::Container).to receive(:create) do |config|
          tmp_options = config.dig("HostConfig", "Tmpfs", "/tmp")
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
          expect(tmpfs["/home/agent/.codex"]).to include("size=#{64 * 1024 * 1024}")
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
          expect(binds.none? { |bind| bind.include?("/home/agent/.config/github-copilot-host:ro") }).to be true
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
          expect(tmpfs["/home/agent/.local/share/opencode"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for GitHub Copilot CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.config/github-copilot")
          expect(tmpfs["/home/agent/.config/github-copilot"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.config/github-copilot"]).to include("size=#{64 * 1024 * 1024}")
          mock_container
        end

        service.provision
      end

      it "configures a writable tmpfs for Aider CLI config" do
        expect(Docker::Container).to receive(:create) do |config|
          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.aider")
          expect(tmpfs["/home/agent/.aider"]).to include("mode=0700")
          expect(tmpfs["/home/agent/.aider"]).to include("size=#{64 * 1024 * 1024}")
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

      it "includes provider CLI env overrides from agent-harness" do
        gemini_provider = instance_double(
          AgentHarness::Providers::Gemini,
          cli_env_overrides: { "GEMINI_SANDBOX" => "false", "GEMINI_CLI_DISABLE_RETRIES" => "true" }
        )
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:gemini).and_return(gemini_provider)

        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env).to include("GEMINI_SANDBOX=false")
          expect(env).to include("GEMINI_CLI_DISABLE_RETRIES=true")
          mock_container
        end

        service.provision
      end

      it "does not let harness cli_env_overrides clobber app-managed subscription auth" do
        codex_provider = instance_double(
          AgentHarness::Providers::Codex,
          cli_env_overrides: { "PAID_CODEX_SUBSCRIPTION_AUTH" => "1" },
          config_file_content: "model_provider = \"paid\"\n",
          auth_lock_config: { path: "/tmp/codex-auth.lock" }
        )
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:codex).and_return(codex_provider)

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

      it "raises when a known provider is missing from agent-harness" do
        allow(AgentHarness).to receive(:provider).and_call_original
        allow(AgentHarness).to receive(:provider).with(:gemini).and_raise(KeyError, "missing gemini")

        expect { service.provision }.to raise_error(KeyError, /missing gemini/)
      end

      it "raises when provider CLI env overrides are misconfigured in agent-harness" do
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
          metadata: hash_including(image: anything))
        expect(agent_run).to receive(:log!).with("system", "container.provision.failed",
          metadata: hash_including(error: anything))

        expect { service.provision }.to raise_error(described_class::ProvisionError)
      end
    end

    context "with network integration" do
      it "ensures the agent network exists before provisioning" do
        expect(NetworkPolicy).to receive(:ensure_network!).with(network: NetworkPolicy::NETWORK_NAME).ordered
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
        expect(NetworkPolicy).to receive(:apply_firewall_rules).with(mock_container, service_destinations: []).ordered

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
        expect(NetworkPolicy).to receive(:ensure_network!).with(network: NetworkPolicy::INFRA_NETWORK_NAME)

        service.provision
      end

      it "skips firewall rules" do
        expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

        service.provision
      end
    end

    context "with fallback providers" do
      let(:settings) { project.created_by.settings }
      let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let!(:direct_outbound_provider) do
        create(
          :provider,
          :api_key,
          user: project.created_by,
          provider_key: "opencode",
          provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
        )
      end

      before do
        project.created_by.providers.find_by!(provider_key: "claude").update!(enabled_for_fallback: false)
      end

      it "stays on the restricted network when direct-outbound fallbacks are disabled" do
        settings.update!(fallback_enabled: false, fallback_providers: [])

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network when a fallback requires direct outbound" do
        settings.update!(
          fallback_enabled: true,
          fallback_providers: [ direct_outbound_provider.routing_key ]
        )

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network when kilocode is configured as a fallback" do
        kilocode_provider = create(
          :provider,
          user: project.created_by,
          provider_key: "kilocode",
          enabled_for_agent_runs: false,
          enabled_for_fallback: true
        )
        direct_outbound_provider.update!(enabled_for_fallback: false)

        settings.update!(
          fallback_enabled: true,
          fallback_providers: [ kilocode_provider.routing_key ]
        )

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the infrastructure network when a rate-limit fallback requires direct outbound" do
        settings.update!(fallback_enabled: false, fallback_providers: [])
        direct_outbound_provider.update!(
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

    context "with a direct-outbound default provider" do
      let(:api_key) { create(:provider_api_key, user: project.created_by, api_service_type: "openrouter") }
      let!(:direct_outbound_provider) do
        create(
          :provider,
          :api_key,
          user: project.created_by,
          provider_key: "opencode",
          provider_api_key: api_key,
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
        )
      end

      it "uses the infrastructure network for project-level provisioning when the default provider is direct outbound" do
        project.created_by.settings.update!(default_agent_provider: direct_outbound_provider.routing_key)

        expect(described_class.new(project: project).network_name).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
      end

      it "uses the infrastructure network when execution falls back from an unrunnable saved provider to a direct-outbound default" do
        copilot_provider = create(:provider, user: project.created_by, provider_key: "copilot")
        agent_run.update!(provider: copilot_provider, agent_type: "copilot")
        project.created_by.settings.update!(default_agent_provider: direct_outbound_provider.routing_key, fallback_enabled: false)

        expect(Docker::Container).to receive(:create) do |config|
          expect(config["HostConfig"]["NetworkMode"]).to eq(NetworkPolicy::INFRA_NETWORK_NAME)
          mock_container
        end

        service.provision
      end

      it "uses the restricted network when an unrunnable saved provider has a runnable proxy-mode fallback despite a direct-outbound default" do
        copilot_provider = create(:provider, user: project.created_by, provider_key: "copilot")
        claude_api_key = create(:provider_api_key, user: project.created_by, api_service_type: "anthropic")
        claude_fallback = create(:provider, :api_key, user: project.created_by,
          provider_key: "claude", provider_api_key: claude_api_key)

        direct_outbound_provider.update!(enabled_for_fallback: false)
        project.created_by.providers.subscription.find_by!(provider_key: "claude")
          .update!(enabled_for_fallback: false)

        agent_run.update!(provider: copilot_provider, agent_type: "copilot")
        project.created_by.settings.update!(
          default_agent_provider: direct_outbound_provider.routing_key,
          fallback_enabled: true,
          fallback_providers: [ claude_fallback.routing_key ]
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
      let!(:direct_outbound_provider) do
        create(
          :provider,
          :api_key,
          user: project.created_by,
          provider_key: "opencode",
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
        copilot_provider = create(:provider, user: project.created_by, provider_key: "copilot")
        agent_run.update!(provider: copilot_provider, agent_type: "copilot")
        project.created_by.settings.update!(default_agent_provider: direct_outbound_provider.routing_key, fallback_enabled: false)

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
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
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
        File.write(File.join(codex_config_dir, "auth.json"), "{}")
        File.write(File.join(codex_config_dir, "config.toml"), <<~TOML)
          model = "gpt-5"

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
        allow(ENV).to receive(:[]).with("COPILOT_CONFIG_DIR").and_return(nil)
        allow(service).to receive_messages(claude_local_config_path: nil, gemini_local_config_path: nil, copilot_local_config_path: nil)
      end

      after do
        FileUtils.rm_rf(codex_config_dir)
      end

      it "bind-mounts only Codex auth and sets the subscription marker" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("#{File.join(codex_config_dir, 'auth.json')}:/home/agent/.codex/auth.json:rw")
          expect(binds.none? { |bind| bind.include?("/home/agent/.codex/config.toml") }).to be true
          env = config["Env"]
          expect(env).to include("PAID_CODEX_SUBSCRIPTION_AUTH=1")
          expect(env).to include("ANTHROPIC_BASE_URL=http://web:3000/api/proxy/anthropic")
          expect(config["HostConfig"]["Tmpfs"]).to have_key("/home/agent/.codex")
          mock_container
        end

        service.provision
      end

      it "uses a shared writable Codex auth mount instead of copying credentials" do
        allow(agent_run).to receive(:log!).and_call_original

        service.provision

        expect(mock_container).not_to have_received(:exec).with(
          [ "sh", "-lc", include("/home/agent/.codex/config.toml").and(include('model_provider = "paid"')) ],
          user: "agent"
        )
        expect(agent_run).to have_received(:log!).with(
          "system",
          "container.codex_credentials_shared",
          metadata: hash_including(source_path: codex_config_dir)
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
                decoded.include?('model = "gpt-5"') &&
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
        File.write(File.join(codex_local_dir, "auth.json"), '{"refresh_token":"test-token"}')
        File.write(File.join(codex_local_dir, "config.toml"), "model = \"gpt-5\"")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
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

      it "bind-mounts local Codex auth as the shared writable auth source" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("#{File.join(codex_local_dir, 'auth.json')}:/home/agent/.codex/auth.json:rw")
          expect(binds.none? { |bind| bind.include?(":/home/agent/.codex:rw") }).to be true
          expect(config["Env"]).to include("PAID_CODEX_SUBSCRIPTION_AUTH=1")

          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.codex")
          mock_container
        end

        service.provision
      end

      it "uses shared Codex auth and writes sanitized config into the writable tmpfs" do
        service.provision

        expect(mock_container).not_to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd|
            cmd.include?("/home/agent/.codex/auth.json") &&
              !cmd.include?("/home/agent/.codex/config.toml")
          } ],
          user: "agent"
        )
        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd|
            cmd.include?("/home/agent/.codex/config.toml") &&
              decoded_base64_content(cmd).include?('model = "gpt-5"')
          } ],
          user: "agent"
        )
      end

      it "translates a mounted local Codex path to the Docker host bind source" do
        mount_source = Dir.mktmpdir("codex-host")
        mount_destination = File.dirname(codex_local_dir)
        current_container = instance_double(
          Docker::Container,
          info: { "Mounts" => [ { "Destination" => mount_destination, "Source" => mount_source } ] }
        )
        allow(Docker::Container).to receive(:get).with(Socket.gethostname).and_return(current_container)

        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expected_source = File.join(mount_source, File.basename(codex_local_dir), "auth.json")
          expect(binds).to include("#{expected_source}:/home/agent/.codex/auth.json:rw")
          mock_container
        end

        service.provision
      ensure
        FileUtils.rm_rf(mount_source) if mount_source
      end

      it "fails clearly for a Codex subscription run when local auth is not bind-mountable" do
        codex_provider = create(:provider, user: project.created_by, provider_key: "codex")
        project.created_by.settings.update!(default_agent_provider: codex_provider.routing_key)
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
        codex_provider = create(:provider, :api_key, user: project.created_by, provider_key: "codex", provider_api_key: api_key)
        project.created_by.settings.update!(default_agent_provider: codex_provider.routing_key)
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
        File.write(File.join(copilot_config_dir, "hosts.json"), "{}")

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
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
          expect(binds).to include("#{copilot_config_dir}:/home/agent/.config/github-copilot-host:ro")
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
          [ "sh", "-c", include("/home/agent/.config/github-copilot-host/hosts.json").and(include("/home/agent/.config/github-copilot/hosts.json")) ],
          user: "agent"
        )
      end
    end

    context "with Copilot subscription auth from the devcontainer filesystem" do
      let(:copilot_local_dir) { Dir.mktmpdir("copilot-local") }

      before do
        File.write(File.join(copilot_local_dir, "hosts.json"), '{"github.com":{"oauth_token":"test-token"}}')
        File.write(File.join(copilot_local_dir, "apps.json"), '{}')

        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_CONFIG_DIR").and_return(nil)
        allow(ENV).to receive(:[]).with("CODEX_HOME").and_return(nil)
        allow(ENV).to receive(:[]).with("GEMINI_CONFIG_DIR").and_return(nil)
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
          expect(binds.none? { |bind| bind.include?("/home/agent/.config/github-copilot-host:ro") }).to be true
          expect(config["Env"]).to include("PAID_COPILOT_SUBSCRIPTION_AUTH=1")
          mock_container
        end

        service.provision
      end

      it "writes Copilot credentials into the agent tmpfs from the local filesystem" do
        service.provision

        expect(mock_container).to have_received(:exec).with(
          [ "sh", "-lc", satisfy { |cmd| cmd.include?("/home/agent/.config/github-copilot/hosts.json") && decoded_base64_content(cmd).include?("oauth_token") } ],
          user: "agent"
        )
      end
    end

    context "when firewall rules fail in production" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
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
        :provider,
        :api_key,
        user: project.created_by,
        provider_key: "opencode",
        provider_api_key: api_key,
        config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2.5" } }
      )
    end
    let(:service) { described_class.new(agent_run: agent_run, worktree_path: worktree_path) }

    before do
      project.created_by.settings.update!(default_agent_provider: opencode_provider.routing_key)
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

    it "does not seed when the run resolves to a different provider" do
      project.created_by.settings.update!(default_agent_provider: "claude")

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

      it "does not lock non-Codex container commands" do
        allow(agent_run).to receive(:log!)

        service.execute("echo 'hello'")

        expect(agent_run).not_to have_received(:log!).with(
          "system", "container.codex_auth_lock.acquired", anything
        )
      end
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

      it "suppresses startup timeout while heartbeat file is touched before any output" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          10.times do
            FileUtils.touch(heartbeat_path)
            sleep 0.05
          end
          block.call(:stdout, "finally output\n") if block
          [ [ "finally output\n" ], [], 0 ]
        end

        result = service.execute(
          "waiting_on_llm",
          timeout: 10,
          startup_timeout: 0.2,
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

      it "does not suppress the wall-clock timeout" do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &_block|
          Thread.new do
            20.times do
              FileUtils.touch(heartbeat_path)
              sleep 0.01
            end
          end
          Timeout.timeout(5) { sleep 0.01 until container_stopped.true? }
          [ [], [], 137 ]
        end

        expect {
          service.execute(
            "long_running",
            timeout: 0.2,
            heartbeat_path: heartbeat_path
          )
        }.to raise_error(described_class::TimeoutError, /timed out after 0.2 seconds/)
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
end
