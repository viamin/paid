# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContainerizedRunner, :no_db do
  let(:project) { Struct.new(:id, :full_name).new(42, "owner/repo") }
  let(:commit_sha) { "a" * 40 }

  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "collector123",
      start: true,
      stop: true,
      delete: true,
      exec: [ [ "output" ], [ "" ], 0 ]
    )
  end

  let(:mock_volume) { instance_double(Docker::Volume, remove: true) }

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(Docker::Volume).to receive(:create).and_return(mock_volume)
    allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)
  end

  describe ".available?" do
    it "returns true when Docker is reachable" do
      allow(Docker).to receive(:ping).and_return("OK")
      expect(described_class.available?).to be true
    end

    it "returns false when Docker is unreachable" do
      allow(Docker).to receive(:ping).and_raise(Excon::Error::Socket.new(StandardError.new("connect failed")))
      expect(described_class.available?).to be false
    end

    it "returns false when COLLECTORS_USE_HOST is set" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("COLLECTORS_USE_HOST").and_return("true")
      expect(described_class.available?).to be false
    end
  end

  describe "CONTAINER_DEFAULTS" do
    it "uses 512MB memory limit" do
      expect(described_class::CONTAINER_DEFAULTS[:memory_bytes]).to eq(512 * 1024 * 1024)
    end

    it "uses 1 CPU" do
      expect(described_class::CONTAINER_DEFAULTS[:cpu_quota]).to eq(100_000)
    end

    it "uses 5-minute timeout" do
      expect(described_class::CONTAINER_DEFAULTS[:timeout_seconds]).to eq(300)
    end

    it "uses paid-agent:latest image" do
      expect(described_class::CONTAINER_DEFAULTS[:image]).to eq("paid-agent:latest")
    end
  end

  describe "#run" do
    let(:runner_result) do
      {
        project_version: Object.new,
        results: [ { collector_type: "test", status: "completed", artifacts_count: 1 } ]
      }
    end

    before do
      allow(Knowledge::CollectorRunner).to receive(:call).and_return(runner_result)
    end

    it "provisions a container, clones the repo, and runs collectors" do
      result = described_class.new(
        project: project,
        commit_sha: commit_sha
      ).run

      expect(Docker::Container).to have_received(:create).with(
        hash_including(
          "Image" => "paid-agent:latest",
          "HostConfig" => hash_including(
            "NetworkMode" => "none",
            "Memory" => 512 * 1024 * 1024
          )
        )
      )
      expect(mock_container).to have_received(:start)
      expect(result[:results].first[:status]).to eq("completed")
    end

    it "passes container_runner in options to CollectorRunner" do
      runner = described_class.new(project: project, commit_sha: commit_sha)

      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        expect(args[:options][:container_runner]).to eq(runner)
        runner_result
      end

      runner.run
    end

    it "cleans up the container after execution" do
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(mock_container).to have_received(:stop)
      expect(mock_container).to have_received(:delete)
    end

    it "cleans up even when CollectorRunner raises" do
      allow(Knowledge::CollectorRunner).to receive(:call).and_raise(RuntimeError, "boom")

      expect {
        described_class.new(project: project, commit_sha: commit_sha).run
      }.to raise_error(RuntimeError, "boom")

      expect(mock_container).to have_received(:delete)
    end

    it "does not expose API keys or proxy URLs" do
      described_class.new(project: project, commit_sha: commit_sha).run

      config = nil
      allow(Docker::Container).to receive(:create) { |cfg| config = cfg; mock_container }
      described_class.new(project: project, commit_sha: commit_sha).run

      env = config["Env"]
      expect(env).not_to include(a_string_matching(/PROXY_TOKEN/))
      expect(env).not_to include(a_string_matching(/ANTHROPIC/))
      expect(env).not_to include(a_string_matching(/OPENAI/))
      expect(env).not_to include(a_string_matching(/API_KEY/))
    end

    it "uses network=none for isolation" do
      config = nil
      allow(Docker::Container).to receive(:create) { |cfg| config = cfg; mock_container }
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(config.dig("HostConfig", "NetworkMode")).to eq("none")
    end
  end

  describe "#execute" do
    it "runs a command inside the container and returns stdout" do
      runner = described_class.new(project: project, commit_sha: commit_sha)

      # Test execute via the CollectorRunner callback during #run
      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        container_runner = args[:options][:container_runner]
        allow(mock_container).to receive(:exec).and_return([ [ "hello world" ], [ "" ], 0 ])
        result = container_runner.execute("echo hello world")
        expect(result).to eq("hello world")
        { project_version: Object.new, results: [] }
      end

      runner.run
    end

    it "raises ContainerError when command fails" do
      runner = described_class.new(project: project, commit_sha: commit_sha)

      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        container_runner = args[:options][:container_runner]
        allow(mock_container).to receive(:exec).and_return([ [ "" ], [ "error msg" ], 1 ])
        expect { container_runner.execute("bad command") }.to raise_error(
          Knowledge::ContainerizedRunner::ContainerError, /Command failed/
        )
        { project_version: Object.new, results: [] }
      end

      runner.run
    end

    it "raises ContainerError when container is not provisioned" do
      runner = described_class.new(project: project, commit_sha: commit_sha)
      expect { runner.execute("echo test") }.to raise_error(
        Knowledge::ContainerizedRunner::ContainerError, /not provisioned/
      )
    end
  end
end
