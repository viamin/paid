# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::AnalysisRunner, :no_db do
  let(:project) { Struct.new(:id).new(42) }
  let(:knowledge_run) do
    Struct.new(:id, :proxy_token, :persisted?, :active?, :status) do
      def ensure_proxy_token!
        self.proxy_token ||= "a1b2c3d4" * 8
        proxy_token
      end
    end.new(99, nil, true, true, "running")
  end

  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "analysis123",
      start: true,
      stop: true,
      delete: true
    )
  end
  let(:backend) do
    instance_double(
      Containers::Backends::Base,
      remote?: false,
      ping: "OK",
      create_container: mock_container,
      start_container: true,
      stop_container: true,
      delete_container: true,
      exec_in_container: [ [ "output" ], [ "" ], 0 ]
    )
  end

  before do
    allow(Containers).to receive(:backend).and_return(backend)
  end

  describe ".available?" do
    it "returns true when Docker is reachable" do
      expect(described_class.available?).to be true
    end

    it "returns false when Docker is unreachable" do
      allow(backend).to receive(:ping).and_raise(Excon::Error::Socket.new(StandardError.new("connect failed")))
      expect(described_class.available?).to be false
    end

    it "returns false on Docker API errors" do
      allow(backend).to receive(:ping).and_raise(Docker::Error::DockerError, "daemon not found")
      expect(described_class.available?).to be false
    end
  end

  describe ".supported_provider?" do
    it "returns true for anthropic-backed providers" do
      expect(described_class.supported_provider?("claude")).to be true
      expect(described_class.supported_provider?("cursor")).to be true
      expect(described_class.supported_provider?("aider")).to be true
    end

    it "returns true for openai-backed providers" do
      expect(described_class.supported_provider?("codex")).to be true
    end

    it "returns false for providers without a known API type" do
      expect(described_class.supported_provider?("copilot")).to be false
      expect(described_class.supported_provider?("unknown")).to be false
    end
  end

  describe "CONTAINER_DEFAULTS" do
    it "uses 256MB memory limit" do
      expect(described_class::CONTAINER_DEFAULTS[:memory_bytes]).to eq(256 * 1024 * 1024)
    end

    it "uses 1 CPU" do
      expect(described_class::CONTAINER_DEFAULTS[:cpu_quota]).to eq(100_000)
    end

    it "uses 60-second timeout" do
      expect(described_class::CONTAINER_DEFAULTS[:timeout_seconds]).to eq(60)
    end

    it "uses bridge network mode" do
      expect(described_class::CONTAINER_DEFAULTS[:network_mode]).to eq("bridge")
    end
  end

  describe "#with_container" do
    it "provisions a container, yields, and cleans up" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      runner.with_container do |r|
        expect(r).to eq(runner)
        expect(backend).to have_received(:create_container)
        expect(backend).to have_received(:start_container).with(mock_container)
      end

      expect(backend).to have_received(:stop_container).with(mock_container, timeout: 5)
      expect(backend).to have_received(:delete_container).with(mock_container, force: true)
    end

    it "cleans up container even when block raises" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      expect {
        runner.with_container { raise "boom" }
      }.to raise_error(RuntimeError, "boom")

      expect(backend).to have_received(:stop_container).with(mock_container, timeout: 5)
      expect(backend).to have_received(:delete_container).with(mock_container, force: true)
    end

    it "raises ContainerError when Docker fails to provision" do
      allow(backend).to receive(:create_container)
        .and_raise(Docker::Error::DockerError, "no such image")

      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      expect {
        runner.with_container { |_r| }
      }.to raise_error(described_class::ContainerError, /Failed to provision/)
    end
  end

  describe "#call_llm" do
    let(:runner) { described_class.new(project: project, knowledge_run: knowledge_run) }
    let(:remote_backend) do
      instance_double(
        Containers::Backends::Base,
        identifier: "worker-1",
        remote?: true,
        create_container: mock_container,
        start_container: true,
        stop_container: true,
        delete_container: true,
        exec_in_container: [ [ "output" ], [ "" ], 0 ]
      )
    end

    before do
      # Simulate container is provisioned
      runner.send(:provision!)
    end

    after { runner.send(:cleanup!) }

    it "executes an anthropic script for claude provider" do
      allow(backend).to receive(:exec_in_container).and_return([ [ '{"title":"Test"}' ], [ "" ], 0 ])

      result = runner.call_llm("Draft a decision", provider: "claude", model: "claude-sonnet-4-6")

      expect(result).to eq('{"title":"Test"}')
      expect(backend).to have_received(:exec_in_container) do |_container, cmd, **opts|
        expect(cmd[0]).to eq("ruby")
        expect(cmd[1]).to eq("-e")
        expect(cmd[2]).to include("anthropic")
        env_hash = opts[:Env].to_h { |e| e.split("=", 2) }
        expect(env_hash["API_SERVICE_TYPE"]).to eq("anthropic")
        expect(env_hash["LLM_MODEL"]).to eq("claude-sonnet-4-6")
        expect(env_hash["KNOWLEDGE_RUN_ID"]).to eq("99")
        expect(env_hash["PROXY_TOKEN"]).to be_present
      end
    end

    it "executes an openai script for codex provider" do
      allow(backend).to receive(:exec_in_container).and_return([ [ '{"title":"Test"}' ], [ "" ], 0 ])

      result = runner.call_llm("Draft a decision", provider: "codex")

      expect(result).to eq('{"title":"Test"}')
      expect(backend).to have_received(:exec_in_container) do |_container, cmd, **_opts|
        expect(cmd[2]).to include("openai")
      end
    end

    it "uses default model when not specified" do
      allow(backend).to receive(:exec_in_container).and_return([ [ "output" ], [ "" ], 0 ])

      runner.call_llm("test", provider: "claude")

      expect(backend).to have_received(:exec_in_container) do |_container, _cmd, **opts|
        env_hash = opts[:Env].to_h { |e| e.split("=", 2) }
        expect(env_hash["LLM_MODEL"]).to eq("claude-sonnet-4-6")
      end
    end

    it "raises ContainerError for unsupported provider" do
      expect {
        runner.call_llm("test", provider: "copilot")
      }.to raise_error(described_class::ContainerError, /Unsupported API type/)
    end

    it "raises ContainerError when container not provisioned" do
      unprov_runner = described_class.new(project: project, knowledge_run: knowledge_run)

      expect {
        unprov_runner.call_llm("test", provider: "claude")
      }.to raise_error(described_class::ContainerError, /Container not provisioned/)
    end

    it "raises ContainerError when exec returns non-zero exit code" do
      allow(backend).to receive(:exec_in_container).and_return([ [ "" ], [ "Proxy error: 500" ], 1 ])

      expect {
        runner.call_llm("test", provider: "claude")
      }.to raise_error(described_class::ContainerError, /LLM call failed/)
    end

    it "passes base64-encoded prompt in env" do
      allow(backend).to receive(:exec_in_container).and_return([ [ "output" ], [ "" ], 0 ])

      runner.call_llm("Hello world", provider: "claude")

      expect(backend).to have_received(:exec_in_container) do |_container, _cmd, **opts|
        env_hash = opts[:Env].to_h { |e| e.split("=", 2) }
        decoded = Base64.strict_decode64(env_hash["PROMPT_B64"])
        expect(decoded).to eq("Hello world")
      end
    end

    it "uses the external proxy URL for remote backends" do
      original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
      allow(Containers).to receive(:backend).and_return(remote_backend)

      remote_runner = described_class.new(project: project, knowledge_run: knowledge_run)
      remote_runner.send(:provision!)
      remote_runner.call_llm("test", provider: "claude")

      expect(remote_backend).to have_received(:exec_in_container) do |_container, _cmd, **opts|
        env_hash = opts[:Env].to_h { |e| e.split("=", 2) }
        expect(env_hash["PROXY_BASE_URL"]).to eq("https://proxy.example.test:3443")
      end
    ensure
      remote_runner&.send(:cleanup!)
      ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
    end
  end

  describe "container configuration" do
    it "enables TLS in generated proxy scripts when PROXY_BASE_URL is HTTPS" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      expect(runner.send(:anthropic_script)).to include('http.use_ssl = uri.scheme == "https"')
      expect(runner.send(:openai_script)).to include('http.use_ssl = uri.scheme == "https"')
    end

    it "creates container with security hardening" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      allow(backend).to receive(:exec_in_container).and_return([ [ "ok" ], [ "" ], 0 ])

      runner.with_container { |r| r.call_llm("test", provider: "claude") }

      expect(backend).to have_received(:create_container) do |config|
        expect(config["ReadonlyRootfs"]).to be true
        expect(config["CapDrop"]).to eq([ "ALL" ])
        expect(config["SecurityOpt"]).to eq([ "no-new-privileges:true" ])
        expect(config["User"]).to eq("agent")
        expect(config["Labels"]["paid.resource"]).to eq("analysis_container")
        expect(config["Labels"]["paid.knowledge_run_id"]).to eq("99")
        expect(config["HostConfig"]["NetworkMode"]).to eq("bridge")
        expect(config["HostConfig"]["Memory"]).to eq(256 * 1024 * 1024)
        expect(config["HostConfig"]["PidsLimit"]).to eq(100)
      end
    end

    it "does not include API keys in container env" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      runner.with_container do |_r|
        expect(backend).to have_received(:create_container) do |config|
          env_keys = config["Env"].map { |e| e.split("=", 2).first }
          expect(env_keys).not_to include("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY")
        end
      end
    end
  end
end
