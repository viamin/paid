# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::EmbeddingRunner, :no_db do
  let(:project) { Struct.new(:id).new(42) }
  let(:remote_backend) { instance_double(Containers::Backends::Base, remote?: true) }
  let(:knowledge_run) do
    Struct.new(:id) do
      def ensure_proxy_token!
        "proxy-token"
      end
    end.new(7)
  end

  describe "#container_config" do
    it "bind-mounts the input directory read-only" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      runner.instance_variable_set(:@input_dir, "/tmp/paid-embedding-runner-test")

      config = runner.send(:container_config)

      expect(config["CapAdd"]).to eq([ "NET_RAW" ])
      expect(config.dig("HostConfig", "Binds")).to eq(
        [ "/tmp/paid-embedding-runner-test:/paid-input:ro" ]
      )
    end
  end

  describe "#generate" do
    it "cleans up the temp input directory when container execution fails" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)

      allow(runner).to receive(:ensure_container!)
      allow(runner).to receive(:write_input_file)
      allow(runner).to receive(:execute).and_raise(described_class::ContainerError, "boom")
      allow(runner).to receive(:cleanup_container!)
      allow(runner).to receive(:cleanup_input_dir!)

      expect {
        runner.generate(texts: [ "hello" ], provider: "openai", model: "text-embedding-3-small", dimensions: 1536)
      }.to raise_error(described_class::ContainerError, "boom")

      expect(runner).to have_received(:cleanup_container!)
      expect(runner).to have_received(:cleanup_input_dir!)
    end
  end

  describe "#ensure_container!" do
    it "applies firewall rules after the container starts" do
      runner = described_class.new(project: project, knowledge_run: knowledge_run)
      container = instance_double(Docker::Container, start: true)

      allow(Dir).to receive(:mktmpdir).and_return("/tmp/paid-embedding-runner-test")
      allow(NetworkPolicy).to receive(:ensure_network!)
      allow(Docker::Container).to receive(:create).and_return(container)
      allow(NetworkPolicy).to receive(:apply_firewall_rules)

      runner.send(:ensure_container!)

      expect(NetworkPolicy).to have_received(:ensure_network!).with(network: NetworkPolicy::NETWORK_NAME)
      expect(NetworkPolicy).to have_received(:apply_firewall_rules).with(container, backend: Containers.backend)
    end
  end

  describe "#script_env" do
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
