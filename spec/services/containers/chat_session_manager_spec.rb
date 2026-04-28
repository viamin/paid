# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ChatSessionManager do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:chat_session) do
    create(:chat_session, :workspace, :with_project,
      account: account,
      project: project,
      container_id: "chat-container-abc123",
      workspace_volume: "paid-chat-workspace-vol",
      idle_timeout_at: 30.minutes.from_now)
  end

  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "chat-container-abc123",
      stop: true,
      delete: true,
      refresh!: true,
      info: { "State" => { "Running" => true } }
    )
  end

  let(:mock_volume) { instance_double(Docker::Volume, remove: true) }

  let(:manager) { described_class.new(chat_session) }

  before do
    allow(Docker::Container).to receive(:get)
      .with("chat-container-abc123")
      .and_return(mock_container)
    allow(Docker::Volume).to receive(:get).and_return(mock_volume)
  end

  describe "#execute_agent_command" do
    before do
      allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
        block&.call(:stdout, "Hello from agent\n")
        [ [ "Hello from agent\n" ], [], 0 ]
      end
    end

    it "executes a command and returns success result" do
      result = manager.execute_agent_command(prompt: "Fix the bug")

      expect(result).to be_success
      expect(result[:stdout]).to include("Hello from agent")
      expect(result[:exit_code]).to eq(0)
    end

    it "builds correct agent CLI command" do
      expect(mock_container).to receive(:exec).with(
        [ "sh", "-c", /claude --print Fix\\ the\\ bug/ ],
        hash_including(wait: described_class::EXECUTE_TIMEOUT)
      ) do |_cmd, **_opts, &block|
        block&.call(:stdout, "output\n")
        [ [ "output\n" ], [], 0 ]
      end

      manager.execute_agent_command(prompt: "Fix the bug")
    end

    it "includes --resume flag when session_id is provided" do
      expect(mock_container).to receive(:exec).with(
        [ "sh", "-c", /claude --print --resume prev-session-123/ ],
        anything
      ) do |_cmd, **_opts, &block|
        block&.call(:stdout, "resumed\n")
        [ [ "resumed\n" ], [], 0 ]
      end

      manager.execute_agent_command(prompt: "Continue", session_id: "prev-session-123")
    end

    it "extends idle timeout after execution" do
      manager.execute_agent_command(prompt: "Fix the bug")

      chat_session.reload
      expect(chat_session.idle_timeout_at).to be_within(1.minute).of(30.minutes.from_now)
    end

    it "captures stderr output" do
      allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
        block&.call(:stderr, "warning: something\n")
        [ [], [ "warning: something\n" ], 0 ]
      end

      result = manager.execute_agent_command(prompt: "Fix")
      expect(result[:stderr]).to include("warning: something")
    end

    context "when agent CLI exits with non-zero code" do
      before do
        allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
          block&.call(:stderr, "Error: something went wrong\n")
          [ [], [ "Error: something went wrong\n" ], 1 ]
        end
      end

      it "returns a failure result" do
        result = manager.execute_agent_command(prompt: "Fix the bug")

        expect(result).to be_failure
        expect(result.error).to eq("Agent command exited with code 1")
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include("something went wrong")
      end
    end

    context "when container is not assigned" do
      let(:chat_session) do
        create(:chat_session, account: account, container_id: nil)
      end

      it "raises ContainerNotRunning" do
        expect { manager.execute_agent_command(prompt: "test") }
          .to raise_error(described_class::ContainerNotRunning, /No container assigned/)
      end
    end

    context "when container is not running" do
      before do
        allow(mock_container).to receive(:info)
          .and_return({ "State" => { "Running" => false } })
      end

      it "raises ContainerNotRunning" do
        expect { manager.execute_agent_command(prompt: "test") }
          .to raise_error(described_class::ContainerNotRunning, /not running/)
      end
    end

    context "when Docker exec fails" do
      before do
        allow(mock_container).to receive(:exec)
          .and_raise(Docker::Error::DockerError, "exec failed")
      end

      it "raises ExecutionError" do
        expect { manager.execute_agent_command(prompt: "test") }
          .to raise_error(described_class::ExecutionError, /exec failed/)
      end
    end
  end

  describe "#extend_idle_timeout!" do
    it "updates idle_timeout_at with default duration" do
      manager.extend_idle_timeout!

      chat_session.reload
      expect(chat_session.idle_timeout_at).to be_within(1.minute).of(30.minutes.from_now)
    end

    it "accepts custom duration" do
      manager.extend_idle_timeout!(duration: 1.hour)

      chat_session.reload
      expect(chat_session.idle_timeout_at).to be_within(1.minute).of(1.hour.from_now)
    end
  end

  describe "#health_check" do
    context "when container is running" do
      it "returns healthy status" do
        result = manager.health_check

        expect(result[:healthy]).to be true
        expect(result[:message]).to eq("Container is running")
      end
    end

    context "when container is not running" do
      before do
        allow(mock_container).to receive(:info)
          .and_return({ "State" => { "Running" => false } })
      end

      it "returns unhealthy status" do
        result = manager.health_check

        expect(result[:healthy]).to be false
        expect(result[:message]).to eq("Container is not running")
      end
    end

    context "when container is not found" do
      before do
        allow(Docker::Container).to receive(:get)
          .and_raise(Docker::Error::NotFoundError)
      end

      it "returns unhealthy status" do
        result = manager.health_check

        expect(result[:healthy]).to be false
        expect(result[:message]).to eq("Container not found")
      end
    end

    context "when no container is assigned" do
      let(:chat_session) do
        create(:chat_session, account: account, container_id: nil)
      end

      it "returns unhealthy status" do
        result = manager.health_check

        expect(result[:healthy]).to be false
        expect(result[:message]).to eq("No container assigned")
      end
    end
  end

  describe "#cleanup!" do
    it "stops and removes the container" do
      expect(mock_container).to receive(:stop).with(timeout: 10)
      expect(mock_container).to receive(:delete).with(force: true, v: true)

      manager.cleanup!
    end

    it "removes workspace and state volumes" do
      expect(Docker::Volume).to receive(:get).with("paid-chat-workspace-vol").and_return(mock_volume)
      expect(Docker::Volume).to receive(:get).with("paid-chat-state-#{chat_session.id}").and_return(mock_volume)
      expect(mock_volume).to receive(:remove).twice

      manager.cleanup!
    end

    it "clears container_id and workspace_volume on chat session" do
      manager.cleanup!

      chat_session.reload
      expect(chat_session.container_id).to be_nil
      expect(chat_session.workspace_volume).to be_nil
    end

    context "with preserve_state: true" do
      it "keeps the state volume" do
        expect(Docker::Volume).to receive(:get).with("paid-chat-workspace-vol").and_return(mock_volume)
        expect(Docker::Volume).not_to receive(:get).with("paid-chat-state-#{chat_session.id}")

        manager.cleanup!(preserve_state: true)
      end
    end

    context "when container is already gone" do
      before do
        allow(Docker::Container).to receive(:get)
          .with("chat-container-abc123")
          .and_raise(Docker::Error::NotFoundError)
      end

      it "completes without error" do
        expect { manager.cleanup! }.not_to raise_error
      end
    end

    context "when no container is assigned" do
      let(:chat_session) do
        create(:chat_session, account: account, container_id: nil, workspace_volume: nil)
      end

      it "completes without error" do
        expect { manager.cleanup! }.not_to raise_error
      end
    end
  end
end
