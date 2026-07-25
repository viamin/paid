# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::TokenOptimization do
  let(:container_service) { instance_double(Containers::Provision) }
  let(:exec_success) { Containers::Provision::Result.success(stdout: "ok", stderr: "", exit_code: 0) }

  before do
    allow(container_service).to receive(:execute).and_return(exec_success)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
  end

  describe ".rtk_init_for_runner" do
    context "with supported runners" do
      {
        "claude" => [],
        "claude_code" => [],
        "copilot" => [],
        "codex" => %w[--codex],
        "gemini" => %w[--gemini],
        "opencode" => %w[--opencode],
        "cursor" => %w[--agent cursor]
      }.each do |runner, extra_flags|
        it "runs rtk init with correct flags for #{runner}" do
          expected_command = [ "rtk", "init", "-g", "--auto-patch", "--hook-only", *extra_flags ]

          expect(container_service).to receive(:execute)
            .with(expected_command, timeout: described_class::RTK_INIT_TIMEOUT)

          described_class.rtk_init_for_runner(container_service: container_service, runner_key: runner)
        end
      end

      it "accepts symbol runner keys" do
        expect(container_service).to receive(:execute)
          .with([ "rtk", "init", "-g", "--auto-patch", "--hook-only", "--codex" ],
              timeout: described_class::CODEGRAPH_INSTALL_TIMEOUT)

        described_class.rtk_init_for_runner(container_service: container_service, runner_key: :codex)
      end
    end

    context "with unsupported runners" do
      %w[kilocode pi aider unknown_runner].each do |runner|
        it "does not call execute for #{runner}" do
          expect(container_service).not_to receive(:execute)

          described_class.rtk_init_for_runner(container_service: container_service, runner_key: runner)
        end
      end
    end

    it "is non-fatal when execute raises" do
      allow(container_service).to receive(:execute)
        .and_raise(Containers::Provision::ExecutionError.new("boom"))

      expect {
        described_class.rtk_init_for_runner(container_service: container_service, runner_key: "claude")
      }.not_to raise_error

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "container_manager.rtk_init_failed", runner: "claude")
      )
    end
  end

  describe ".codegraph_setup" do
    it "calls codegraph_init and codegraph_install" do
      expect(described_class).to receive(:codegraph_init).with(container_service: container_service)
      expect(described_class).to receive(:codegraph_install).with(container_service: container_service)

      described_class.codegraph_setup(container_service: container_service)
    end

    it "executes both commands through the container service" do
      described_class.codegraph_setup(container_service: container_service)

      expect(container_service).to have_received(:execute).with(
        [ "codegraph", "init" ], timeout: described_class::CODEGRAPH_INIT_TIMEOUT
      )
      expect(container_service).to have_received(:execute).with(
        [ "codegraph", "install", "--yes", "--location=global", "--no-permissions" ],
        timeout: described_class::CODEGRAPH_INSTALL_TIMEOUT
      )
    end
  end

  describe ".codegraph_init" do
    it "runs codegraph init in the workspace" do
      expect(container_service).to receive(:execute)
        .with([ "codegraph", "init" ], timeout: described_class::CODEGRAPH_INIT_TIMEOUT)

      described_class.codegraph_init(container_service: container_service)
    end

    it "is non-fatal when execute raises" do
      allow(container_service).to receive(:execute)
        .and_raise(Containers::Provision::TimeoutError.new("timed out"))

      expect {
        described_class.codegraph_init(container_service: container_service)
      }.not_to raise_error

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "container_manager.codegraph_init_failed")
      )
    end
  end

  describe ".codegraph_install" do
    it "configures MCP globally without modifying project files" do
      expect(container_service).to receive(:execute)
        .with([ "codegraph", "install", "--yes", "--location=global", "--no-permissions" ],
              timeout: described_class::RTK_INIT_TIMEOUT)

      described_class.codegraph_install(container_service: container_service)
    end

    it "is non-fatal when execute raises" do
      allow(container_service).to receive(:execute)
        .and_raise(StandardError, "install failed")

      expect {
        described_class.codegraph_install(container_service: container_service)
      }.not_to raise_error

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "container_manager.codegraph_install_failed")
      )
    end
  end
end
