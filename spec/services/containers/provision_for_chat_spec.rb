# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::ProvisionForChat do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:chat_session) { create(:chat_session, :with_project, account: account, project: project) }

  let(:mock_container) do
    instance_double(
      Docker::Container,
      id: "chat-container-abc123",
      start: true,
      stop: true,
      delete: true,
      exec: [ [], [], 0 ]
    )
  end

  let(:mock_volume) { instance_double(Docker::Volume, remove: true) }

  before do
    allow(Docker::Container).to receive(:create).and_return(mock_container)
    allow(Docker::Volume).to receive(:create).and_return(mock_volume)
    allow(Docker::Volume).to receive(:get).and_raise(Docker::Error::NotFoundError)
    allow(Rails.application.config.x).to receive(:paid_proxy_port).and_return(3000)
  end

  describe "constants" do
    it "defines memory limit of 2GB" do
      expect(described_class::CHAT_DEFAULTS[:memory_bytes]).to eq(2 * 1024 * 1024 * 1024)
    end

    it "defines CPU quota for 1 CPU" do
      expect(described_class::CHAT_DEFAULTS[:cpu_quota]).to eq(100_000)
    end

    it "defines PID limit of 500" do
      expect(described_class::CHAT_DEFAULTS[:pids_limit]).to eq(500)
    end

    it "defines idle timeout of 30 minutes" do
      expect(described_class::CHAT_DEFAULTS[:idle_timeout]).to eq(30.minutes)
    end
  end

  describe ".call" do
    it "provisions a container and returns success" do
      result = described_class.call(chat_session: chat_session)

      expect(result).to be_success
      expect(result[:container_id]).to eq("chat-container-abc123")
      expect(result[:workspace_volume]).to start_with("paid-chat-workspace-")
      expect(result[:state_volume]).to start_with("paid-chat-state-")
    end

    it "updates the chat session with container details" do
      described_class.call(chat_session: chat_session)

      chat_session.reload
      expect(chat_session.container_id).to eq("chat-container-abc123")
      expect(chat_session.workspace_volume).to start_with("paid-chat-workspace-")
      expect(chat_session.idle_timeout_at).to be_within(1.minute).of(30.minutes.from_now)
    end

    it "creates workspace and state volumes" do
      expect(Docker::Volume).to receive(:create).with(
        "paid-chat-workspace-#{chat_session.id}",
        hash_including("Labels" => hash_including("paid.resource" => "chat_workspace_volume"))
      ).and_return(mock_volume)

      expect(Docker::Volume).to receive(:create).with(
        "paid-chat-state-#{chat_session.id}",
        hash_including("Labels" => hash_including("paid.resource" => "chat_state_volume"))
      ).and_return(mock_volume)

      described_class.call(chat_session: chat_session)
    end

    it "creates container with correct resource limits" do
      expect(Docker::Container).to receive(:create).with(
        hash_including(
          "HostConfig" => hash_including(
            "Memory" => 2 * 1024 * 1024 * 1024,
            "MemorySwap" => 2 * 1024 * 1024 * 1024,
            "CpuQuota" => 100_000,
            "PidsLimit" => 500
          )
        )
      ).and_return(mock_container)

      described_class.call(chat_session: chat_session)
    end

    it "creates container with security hardening" do
      expect(Docker::Container).to receive(:create).with(
        hash_including(
          "ReadonlyRootfs" => true,
          "CapDrop" => [ "ALL" ],
          "CapAdd" => [ "NET_RAW" ],
          "SecurityOpt" => [ "no-new-privileges:true" ]
        )
      ).and_return(mock_container)

      described_class.call(chat_session: chat_session)
    end

    it "mounts workspace volume and state volume subpaths at agent CLI dirs" do
      expected_binds = [
        "paid-chat-workspace-#{chat_session.id}:/workspace:rw",
        "paid-chat-state-#{chat_session.id}:/home/agent/.claude:rw,subpath=.claude",
        "paid-chat-state-#{chat_session.id}:/home/agent/.codex:rw,subpath=.codex",
        "paid-chat-state-#{chat_session.id}:/home/agent/.gemini:rw,subpath=.gemini",
        "paid-chat-state-#{chat_session.id}:/home/agent/.cursor-agent:rw,subpath=.cursor-agent",
        "paid-chat-state-#{chat_session.id}:/home/agent/.cache:rw,subpath=.cache"
      ]

      expect(Docker::Container).to receive(:create).with(
        hash_including(
          "HostConfig" => hash_including(
            "Binds" => match_array(expected_binds)
          )
        )
      ).and_return(mock_container)

      described_class.call(chat_session: chat_session)
    end

    it "sets environment variables including MCP URL" do
      expect(Docker::Container).to receive(:create).with(
        hash_including(
          "Env" => include(
            "HOME=/home/agent",
            "PAID_MCP_URL=http://web:3000/mcp",
            "PAID_PROXY_URL=http://web:3000",
            "CHAT_SESSION_ID=#{chat_session.id}",
            "PROJECT_ID=#{project.id}"
          )
        )
      ).and_return(mock_container)

      described_class.call(chat_session: chat_session)
    end

    it "fixes ownership after starting container" do
      expected_cmd = [ "chown", "-R", "agent:agent", "/workspace" ] +
        described_class::STATE_VOLUME_DIRS

      expect(mock_container).to receive(:start).ordered
      expect(mock_container).to receive(:exec).with(
        expected_cmd,
        user: "root"
      ).ordered.and_return([ [], [], 0 ])

      described_class.call(chat_session: chat_session)
    end

    it "uses paid_internal network" do
      expect(Docker::Container).to receive(:create).with(
        hash_including(
          "HostConfig" => hash_including("NetworkMode" => "paid_internal")
        )
      ).and_return(mock_container)

      described_class.call(chat_session: chat_session)
    end

    it "reuses existing volumes instead of creating new ones" do
      allow(Docker::Volume).to receive(:get).and_return(mock_volume)

      expect(Docker::Volume).not_to receive(:create)

      described_class.call(chat_session: chat_session)
    end

    context "when provisioning fails" do
      it "cleans up container and volumes on Docker error" do
        allow(mock_container).to receive(:start).and_raise(Docker::Error::DockerError, "start failed")

        expect(mock_container).to receive(:stop).with(timeout: 0)
        expect(mock_container).to receive(:delete).with(force: true, v: true)

        expect { described_class.call(chat_session: chat_session) }
          .to raise_error(Containers::ProvisionForChat::ProvisionError, /start failed/)
      end
    end

    context "without a project" do
      let(:chat_session) { create(:chat_session, account: account, project: nil) }

      it "provisions successfully without project-scoped env vars" do
        result = described_class.call(chat_session: chat_session)
        expect(result).to be_success
      end
    end
  end
end
