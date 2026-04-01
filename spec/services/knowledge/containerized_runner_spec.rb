# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContainerizedRunner, :no_db do
  let(:project) { Struct.new(:id, :full_name).new(42, "owner/repo") }
  let(:commit_sha) { "a" * 40 }

  let(:mock_volume) do
    instance_double(Docker::Volume, remove: true)
  end

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

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(Docker::Volume).to receive_messages(create: mock_volume, get: mock_volume)
    # Stub host-side git clone
    allow(Dir).to receive(:mktmpdir).and_return("/tmp/paid-collector-test")
    allow(Open3).to receive(:capture3).and_return([ "", "", instance_double(Process::Status, success?: true) ])
    allow(FileUtils).to receive(:chmod)
    allow(FileUtils).to receive(:rm_rf)
    # Stub tar streaming and Docker archive_in_stream for seeding
    tar_stdout = instance_double(IO, read: nil, binmode: nil)
    tar_status = instance_double(Process::Status, success?: true, exitstatus: 0)
    tar_wait_thr = instance_double(Thread, value: tar_status)
    allow(Open3).to receive(:popen2)
      .with("tar", "-cf", "-", "-C", "/tmp/paid-collector-test", ".")
      .and_yield(instance_double(IO), tar_stdout, tar_wait_thr)
    allow(mock_container).to receive(:archive_in_stream)
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

    it "clones on host before provisioning the container" do
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(Open3).to have_received(:capture3).with("git", "init", "/tmp/paid-collector-test")
      expect(Open3).to have_received(:capture3).with(
        "git", "-C", "/tmp/paid-collector-test",
        "fetch", "--depth", "1", "origin", commit_sha
      )
    end

    it "creates a named volume instead of bind-mounting host paths" do
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(Docker::Volume).to have_received(:create).with(
        a_string_matching(/\Apaid-collector-42-[a-f0-9]{8}\z/),
        hash_including(
          "Labels" => hash_including(
            "paid.managed" => "true",
            "paid.resource" => "collector_volume",
            "paid.project_id" => "42"
          )
        )
      )
    end

    it "provisions a container with the named volume and runs collectors" do
      result = described_class.new(project: project, commit_sha: commit_sha).run

      expect(Docker::Container).to have_received(:create).with(
        hash_including(
          "Image" => "paid-agent:latest",
          "HostConfig" => hash_including(
            "NetworkMode" => "none",
            "Memory" => 512 * 1024 * 1024,
            "Binds" => [ a_string_matching(%r{\Apaid-collector-42-[a-f0-9]{8}:/workspace:rw\z}) ]
          )
        )
      )
      expect(mock_container).to have_received(:start)
      expect(result[:results].first[:status]).to eq("completed")
    end

    it "streams repo tar into the container via Docker API" do
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(Open3).to have_received(:popen2).with(
        "tar", "-cf", "-", "-C", "/tmp/paid-collector-test", "."
      )
      expect(mock_container).to have_received(:archive_in_stream).with("/workspace")
    end

    it "sets workspace read-only with root ownership after seeding" do
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(mock_container).to have_received(:exec).with(
        [ "chmod", "-R", "a=rX", "/workspace" ],
        user: "root"
      )
      # No chown to agent — files stay root-owned so the agent user
      # cannot restore write permissions.
      expect(mock_container).not_to have_received(:exec).with(
        [ "chown", "-R", "agent:agent", "/workspace" ],
        user: "root"
      )
    end

    it "raises ContainerError when chmod fails during seeding" do
      allow(mock_container).to receive(:exec)
        .with([ "chmod", "-R", "a=rX", "/workspace" ], user: "root")
        .and_return([ [ "" ], [ "Operation not permitted" ], 1 ])

      expect {
        described_class.new(project: project, commit_sha: commit_sha).run
      }.to raise_error(
        Knowledge::ContainerizedRunner::ContainerError,
        /Failed to set workspace permissions/
      )
    end

    it "raises ContainerError when tar fails" do
      failed_status = instance_double(Process::Status, success?: false, exitstatus: 1)
      failed_wait_thr = instance_double(Thread, value: failed_status)
      tar_stdout = instance_double(IO, read: nil, binmode: nil)
      allow(Open3).to receive(:popen2)
        .with("tar", "-cf", "-", "-C", "/tmp/paid-collector-test", ".")
        .and_yield(instance_double(IO), tar_stdout, failed_wait_thr)

      expect {
        described_class.new(project: project, commit_sha: commit_sha).run
      }.to raise_error(Knowledge::ContainerizedRunner::ContainerError, /tar failed/)
    end

    it "passes container_runner in options to CollectorRunner" do
      runner = described_class.new(project: project, commit_sha: commit_sha)

      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        expect(args[:options][:container_runner]).to eq(runner)
        runner_result
      end

      runner.run
    end

    it "exposes host_repo_dir for file access by collectors" do
      runner = described_class.new(project: project, commit_sha: commit_sha)

      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        expect(args[:options][:container_runner].host_repo_dir).to eq("/tmp/paid-collector-test")
        runner_result
      end

      runner.run
    end

    it "cleans up the container, volume, and host repo after execution" do
      described_class.new(project: project, commit_sha: commit_sha).run

      expect(mock_container).to have_received(:stop)
      expect(mock_container).to have_received(:delete)
      expect(mock_volume).to have_received(:remove).with(force: true)
      expect(FileUtils).to have_received(:rm_rf).with("/tmp/paid-collector-test")
    end

    it "logs a warning when volume cleanup fails with a non-NotFound error" do
      allow(mock_volume).to receive(:remove).and_raise(
        Docker::Error::ServerError.new("volume in use")
      )
      allow(Rails.logger).to receive(:warn)

      described_class.new(project: project, commit_sha: commit_sha).run

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "knowledge.containerized_runner.cleanup_workspace_volume.failed",
          project_id: 42,
          error_class: "Docker::Error::ServerError"
        )
      )
    end

    it "cleans up even when CollectorRunner raises" do
      allow(Knowledge::CollectorRunner).to receive(:call).and_raise(RuntimeError, "boom")

      expect {
        described_class.new(project: project, commit_sha: commit_sha).run
      }.to raise_error(RuntimeError, "boom")

      expect(mock_container).to have_received(:delete)
      expect(mock_volume).to have_received(:remove).with(force: true)
      expect(FileUtils).to have_received(:rm_rf).with("/tmp/paid-collector-test")
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

    it "uses a named volume instead of a host bind mount" do
      config = nil
      allow(Docker::Container).to receive(:create) { |cfg| config = cfg; mock_container }
      described_class.new(project: project, commit_sha: commit_sha).run

      binds = config.dig("HostConfig", "Binds")
      expect(binds.first).to match(%r{\Apaid-collector-42-[a-f0-9]{8}:/workspace:rw\z})
    end
  end

  describe "input validation" do
    it "rejects invalid commit SHA" do
      expect {
        described_class.new(
          project: project,
          commit_sha: "not-a-sha; rm -rf /"
        ).run
      }.to raise_error(Knowledge::ContainerizedRunner::CloneError, /Invalid commit SHA/)
    end

    it "rejects invalid project name" do
      bad_project = Struct.new(:id, :full_name).new(42, "owner/repo; echo pwned")

      expect {
        described_class.new(
          project: bad_project,
          commit_sha: commit_sha
        ).run
      }.to raise_error(Knowledge::ContainerizedRunner::CloneError, /Invalid project name/)
    end

    it "accepts valid 40-hex commit SHA" do
      runner_result = {
        project_version: Object.new,
        results: []
      }
      allow(Knowledge::CollectorRunner).to receive(:call).and_return(runner_result)

      expect {
        described_class.new(project: project, commit_sha: "abcdef1234567890abcdef1234567890abcdef12").run
      }.not_to raise_error
    end
  end

  describe "#execute" do
    it "runs a command inside the container and returns stdout" do
      runner_result = { project_version: Object.new, results: [] }
      runner = described_class.new(project: project, commit_sha: commit_sha)

      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        container_runner = args[:options][:container_runner]
        allow(mock_container).to receive(:exec).and_return([ [ "hello world" ], [ "" ], 0 ])
        result = container_runner.execute("echo hello world")
        expect(result).to eq("hello world")
        runner_result
      end

      runner.run
    end

    it "raises ContainerError when command fails" do
      runner_result = { project_version: Object.new, results: [] }
      runner = described_class.new(project: project, commit_sha: commit_sha)

      allow(Knowledge::CollectorRunner).to receive(:call) do |args|
        container_runner = args[:options][:container_runner]
        allow(mock_container).to receive(:exec).and_return([ [ "" ], [ "error msg" ], 1 ])
        expect { container_runner.execute("bad command") }.to raise_error(
          Knowledge::ContainerizedRunner::ContainerError, /Command failed/
        )
        runner_result
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
