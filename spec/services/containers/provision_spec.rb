# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Provision do
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

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(NetworkPolicy).to receive_messages(ensure_network!: mock_network, apply_firewall_rules: nil)
  end

  after do
    FileUtils.rm_rf(worktree_path) if worktree_path && Dir.exist?(worktree_path)
  end

  describe "constants" do
    it "defines default memory limit of 2GB" do
      expect(described_class::DEFAULTS[:memory_bytes]).to eq(2 * 1024 * 1024 * 1024)
    end

    it "defines default CPU quota for 2 CPUs" do
      expect(described_class::DEFAULTS[:cpu_quota]).to eq(200_000)
    end

    it "defines default PID limit of 500" do
      expect(described_class::DEFAULTS[:pids_limit]).to eq(500)
    end

    it "defines default timeout of 30 minutes" do
      expect(described_class::DEFAULTS[:timeout_seconds]).to eq(1800)
    end

    it "defines default image name" do
      expect(described_class::DEFAULTS[:image]).to eq("paid-agent:latest")
    end

    it "does not include :network in defaults" do
      expect(described_class::DEFAULTS).not_to have_key(:network)
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
        expect(agent_run).to receive(:log!).with("system", "container.network.ready",
          metadata: hash_including(network: NetworkPolicy::NETWORK_NAME)).ordered
        expect(agent_run).to receive(:log!).with("system", "container.firewall.applied",
          metadata: hash_including(container_id: "abc123container")).ordered
        expect(agent_run).to receive(:log!).with("system", "container.provision.success",
          metadata: hash_including(container_id: "abc123container")).ordered

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
          expect(host_config["Memory"]).to eq(2 * 1024 * 1024 * 1024)
          expect(host_config["MemorySwap"]).to eq(2 * 1024 * 1024 * 1024)
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
          expect(tmpfs["/tmp"]).to eq("size=#{1024 * 1024 * 1024},mode=1777")
          expect(tmpfs["/home/agent/.cache"]).to eq("size=#{512 * 1024 * 1024},mode=0755")
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
          expect(env).to include("PAID_PROXY_URL=http://paid-proxy:3000")
          expect(env).to include("PROJECT_ID=#{project.id}")
          expect(env).to include("AGENT_RUN_ID=#{agent_run.id}")
          expect(env).to include("ANTHROPIC_BASE_URL=http://paid-proxy:3000/api/proxy/anthropic")
          expect(env).to include("OPENAI_BASE_URL=http://paid-proxy:3000/api/proxy/openai")
          expect(env).to include("ANTHROPIC_HEADER_X_AGENT_RUN_ID=#{agent_run.id}")
          expect(env).to include("OPENAI_HEADER_X_AGENT_RUN_ID=#{agent_run.id}")
          expect(env).to include("ANTHROPIC_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}")
          expect(env).to include("OPENAI_HEADER_X_PROXY_TOKEN=#{agent_run.proxy_token}")
          mock_container
        end

        service.provision
      end

      it "does not include API keys in environment variables" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env.none? { |e| e.include?("API_KEY") }).to be true
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

    context "when worktree path is invalid" do
      it "auto-creates workspace directory for blank path" do
        allow(FileUtils).to receive(:mkdir_p).and_call_original
        allow(FileUtils).to receive(:mkdir_p).with(a_string_matching(%r{runs/})).and_return(nil)
        service = described_class.new(agent_run: agent_run, worktree_path: "")

        result = service.provision

        expect(result).to be_success
        expect(service.workspace_dir).to be_present
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
        expect(NetworkPolicy).to receive(:ensure_network!).ordered
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
        expect(NetworkPolicy).to receive(:apply_firewall_rules).with(mock_container).ordered

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
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CLAUDE_CONFIG_DIR").and_return("/host/home/user/.claude")
      end

      it "mounts Claude config at staging path and creates writable tmpfs" do
        expect(Docker::Container).to receive(:create) do |config|
          binds = config["HostConfig"]["Binds"]
          expect(binds).to include("/host/home/user/.claude:/home/agent/.claude-host:ro")

          tmpfs = config["HostConfig"]["Tmpfs"]
          expect(tmpfs).to have_key("/home/agent/.claude")
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

      it "does not set ANTHROPIC_BASE_URL or OPENAI_BASE_URL" do
        expect(Docker::Container).to receive(:create) do |config|
          env = config["Env"]
          expect(env.none? { |e| e.start_with?("ANTHROPIC_BASE_URL=") }).to be true
          expect(env.none? { |e| e.start_with?("OPENAI_BASE_URL=") }).to be true
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

      it "skips network creation" do
        expect(NetworkPolicy).not_to receive(:ensure_network!)

        service.provision
      end

      it "skips firewall rules" do
        expect(NetworkPolicy).not_to receive(:apply_firewall_rules)

        service.provision
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
        expect(mock_container).to receive(:exec).with([ "ls", "-la" ])

        service.execute([ "ls", "-la" ])
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
        expect(mock_container).to receive(:delete).with(force: false)

        service.cleanup
      end
    end

    context "when container is already stopped" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => false } })
      end

      it "only deletes the container" do
        expect(mock_container).not_to receive(:stop)
        expect(mock_container).to receive(:delete).with(force: false)

        service.cleanup
      end
    end

    context "when force cleanup is requested" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => true } })
      end

      it "force stops and deletes the container" do
        expect(mock_container).to receive(:stop).with(timeout: 0)
        expect(mock_container).to receive(:delete).with(force: true)

        service.cleanup(force: true)
      end
    end

    context "when cleanup fails" do
      before do
        allow(mock_container).to receive(:info).and_return({ "State" => { "Running" => false } })
        allow(mock_container).to receive(:delete).and_raise(Docker::Error::ServerError.new("Docker error"))
      end

      it "attempts force cleanup" do
        expect(mock_container).to receive(:delete).with(force: false).and_raise(Docker::Error::ServerError)
        expect(mock_container).to receive(:delete).with(force: true)

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
  end
end
