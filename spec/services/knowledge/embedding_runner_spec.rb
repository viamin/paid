# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::EmbeddingRunner, :no_db do
  let(:project) { Struct.new(:id).new(42) }
  let(:remote_backend) { instance_double(Containers::Backends::Base, identifier: "worker-1", remote?: true) }
  let(:local_backend) { instance_double(Containers::Backends::Base, ping: "OK") }
  let(:knowledge_run) do
    Struct.new(:id) do
      def ensure_proxy_token!
        "proxy-token"
      end
    end.new(7)
  end

  describe ".available?" do
    it "checks Docker availability" do
      allow(Containers).to receive(:backend).and_return(local_backend)

      expect(described_class.available?).to be(true)
    end

    it "returns false on Docker API errors" do
      backend = instance_double(Containers::Backends::Base)
      allow(backend).to receive(:ping).and_raise(Docker::Error::DockerError, "daemon not found")
      allow(Containers).to receive(:backend).and_return(backend)

      expect(described_class.available?).to be(false)
    end
  end

  describe "#container_config" do
    it "mounts /paid-input as a writable tmpfs rather than a host bind" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      config = runner.send(:container_config)

      expect(config["CapAdd"]).to eq([ "NET_RAW" ])
      expect(config.dig("HostConfig", "Binds")).to be_nil
      expect(config.dig("HostConfig", "Tmpfs", "/paid-input")).to include("mode=1777")
      expect(config.dig("HostConfig", "NetworkMode")).to eq(NetworkPolicy::NETWORK_NAME)
    end
  end

  describe "#generate" do
    it "cleans up the container when execution fails" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      allow(runner).to receive(:ensure_container!)
      allow(runner).to receive(:stream_input_to_container!)
      allow(runner).to receive(:execute).and_raise(described_class::ContainerError, "boom")
      allow(runner).to receive(:cleanup_container!)

      expect {
        runner.generate(texts: [ "hello" ], provider: "openai", model: "text-embedding-3-small", dimensions: 1536)
      }.to raise_error(described_class::ContainerError, "boom")

      expect(runner).to have_received(:cleanup_container!)
    end
  end

  describe "#ensure_container!" do
    it "applies firewall rules after the container starts" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      container = instance_double(Docker::Container, start: true)

      allow(Containers).to receive(:backend).and_return(local_backend)
      allow(local_backend).to receive(:create_container).and_return(container)
      allow(local_backend).to receive(:start_container)
      allow(ExecutionRunners::LocalDockerRunner).to receive(:ensure_agent_network!)
      allow(ExecutionRunners::LocalDockerRunner).to receive(:apply_firewall_rules)

      runner.send(:ensure_container!)

      expect(ExecutionRunners::LocalDockerRunner).to have_received(:ensure_agent_network!).with(
        backend: local_backend
      )
      expect(ExecutionRunners::LocalDockerRunner).to have_received(:apply_firewall_rules).with(container, backend: Containers.backend)
    end

    it "raises ContainerError when the agent network cannot be ensured" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      allow(Containers).to receive(:backend).and_return(local_backend)
      allow(ExecutionRunners::LocalDockerRunner).to receive(:ensure_agent_network!)
        .and_raise(NetworkPolicy::Error, "network setup failed")

      expect {
        runner.send(:ensure_container!)
      }.to raise_error(described_class::ContainerError, /network setup failed/)
    end
  end

  describe "#stream_input_to_container!" do
    # @spec KNOWLEDGE-CONTAINER-002
    it "streams texts.json into the container as a tar archive instead of a host bind mount" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      container = instance_double(Docker::Container)
      runner.instance_variable_set(:@container, container)

      streamed = +""
      allow(container).to receive(:archive_in_stream) do |path, &block|
        expect(path).to eq("/paid-input")
        loop do
          chunk = block.call
          break if chunk.nil? || chunk.empty?

          streamed << chunk
        end
      end

      runner.send(:stream_input_to_container!, [ "hello", "world" ])

      tar_reader = Gem::Package::TarReader.new(StringIO.new(streamed))
      entry = tar_reader.each.first
      expect(entry.full_name).to eq("texts.json")
      expect(JSON.parse(entry.read)).to eq([ "hello", "world" ])
    end

    it "raises ContainerError when staging input fails" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      container = instance_double(Docker::Container)
      runner.instance_variable_set(:@container, container)
      allow(container).to receive(:archive_in_stream).and_raise(Docker::Error::DockerError, "no space left")

      expect {
        runner.send(:stream_input_to_container!, [ "hello" ])
      }.to raise_error(described_class::ContainerError, /Failed to stage embedding input/)
    end
  end

  describe "#script_env" do
    it "uses AgentHarness transport in the generated embedding proxy script" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      expect(runner.send(:script)).to include('AgentHarness::OpenAICompatibleTransport.new(')
      expect(runner.send(:script)).to include("transport.embed(inputs: texts, model: model, dimensions: dimensions)")
      expect(runner.send(:script)).to include("handle_embedding_error_response(http_response, status_code) unless status_code == 200")
      expect(runner.send(:script)).to include('OpenSSL::SSL::SSLError')
      expect(runner.send(:script)).to include('raise AgentHarness::ProviderError.new("HTTP connection error:')
    end

    it "uses the external proxy URL for remote backends" do
      original_proxy_external_url = ENV["PAID_PROXY_EXTERNAL_URL"]
      ENV["PAID_PROXY_EXTERNAL_URL"] = "https://proxy.example.test:3443"
      allow(Containers).to receive(:backend).and_return(remote_backend)
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      env = runner.send(:script_env, provider: "openai", model: "text-embedding-3-small", dimensions: 1536, timeout: 120)

      expect(env["PROXY_BASE_URL"]).to eq("https://proxy.example.test:3443")
    ensure
      ENV["PAID_PROXY_EXTERNAL_URL"] = original_proxy_external_url
    end
  end
end
