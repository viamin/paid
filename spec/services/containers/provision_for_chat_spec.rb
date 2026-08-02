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
      expect(chat_session.container_capability).to eq("ready")
      expect(chat_session.container_id).to eq("chat-container-abc123")
      expect(chat_session.container_requested_at).to be_present
      expect(chat_session.container_ready_at).to be_present
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

    it "mounts workspace volume and the full state volume" do
      expected_binds = [
        "paid-chat-workspace-#{chat_session.id}:/workspace:rw",
        "paid-chat-state-#{chat_session.id}:/home/agent:rw"
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

    it "sets environment variables including proxy credentials" do
      expect(Docker::Container).to receive(:create).with(
        hash_including(
          "Env" => include(
            "HOME=/home/agent",
            "PAID_MCP_URL=http://web:3000/mcp",
            "PAID_PROXY_URL=http://web:3000",
            "CHAT_SESSION_ID=#{chat_session.id}",
            "PROJECT_ID=#{project.id}",
            a_string_matching(/\APROXY_TOKEN=\h{64}\z/),
            a_string_matching(/\AX_API_KEY=paid-chat-session:#{chat_session.id}:\h{64}\z/)
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
        [ "mkdir", "-p", *described_class::STATE_VOLUME_DIRS ],
        user: "root"
      ).ordered.and_return([ [], [], 0 ])
      expect(mock_container).to receive(:exec).with(
        expected_cmd,
        user: "root"
      ).ordered.and_return([ [], [], 0 ])
      # seed_workspace! exec call
      allow(mock_container).to receive(:exec).with(
        array_including("sh"),
        hash_including(user: "agent")
      ).and_return([ [], [], 0 ])

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

    it "skips recloning when reusing a non-empty workspace volume" do
      allow(Docker::Volume).to receive(:get).and_return(mock_volume)
      allow(mock_container).to receive(:exec).with(
        [ "sh", "-c", "if [ -z \"$(ls -A . 2>/dev/null)\" ]; then exit 0; fi; exit 1" ],
        user: "agent"
      ).and_return([ [], [], 1 ])

      expect(mock_container).not_to receive(:exec).with(
        [ "sh", "-c", a_string_matching(/git clone/) ],
        anything
      )

      described_class.call(chat_session: chat_session)
    end

    context "when project has an active GitHub token" do
      let(:github_token) { instance_double(GithubToken, active?: true, token: "ghp_test123") }

      before do
        allow(project).to receive(:github_token).and_return(github_token)
      end

      it "seeds the workspace by cloning the project repo" do
        expect(mock_container).to receive(:exec).with(
          [ "sh", "-c", anything ],
          hash_including(
            user: "agent",
            wait: described_class::CLONE_TIMEOUT,
            Env: [ "CLONE_TOKEN=ghp_test123" ]
          )
        ).and_return([ [], [], 0 ])

        described_class.call(chat_session: chat_session)
      end

      it "records the cloned repo in chat_session.clone_manifest" do
        allow(mock_container).to receive(:exec).with(
          [ "sh", "-c", a_string_matching(/git clone/) ],
          hash_including(user: "agent")
        ).and_return([ [], [], 0 ])

        described_class.call(chat_session: chat_session)

        expect(chat_session.reload.clone_manifest_entries).to contain_exactly(
          a_hash_including(project_id: project.id, path: "/workspace")
        )
      end

      it "appends manifest entries without dropping pre-existing ones" do
        chat_session.update!(clone_manifest: [ { project_id: 999, path: "/workspace/legacy" } ])
        allow(mock_container).to receive(:exec).with(
          [ "sh", "-c", a_string_matching(/git clone/) ],
          hash_including(user: "agent")
        ).and_return([ [], [], 0 ])

        described_class.call(chat_session: chat_session)

        entries = chat_session.reload.clone_manifest_entries
        expect(entries.map { |e| e[:path] }).to contain_exactly("/workspace/legacy", "/workspace")
      end

      it "does not record a manifest entry when the clone fails" do
        allow(mock_container).to receive(:exec).with(
          [ "sh", "-c", a_string_matching(/git clone/) ],
          hash_including(user: "agent")
        ).and_return([ [ "fatal: repository not found" ], [], 128 ])

        expect {
          described_class.call(chat_session: chat_session)
        }.to raise_error(Containers::ProvisionForChat::ProvisionError)

        expect(chat_session.reload.clone_manifest_entries).to be_empty
      end

      it "does not re-record a manifest entry when reusing a non-empty workspace" do
        chat_session.update!(clone_manifest: [ { project_id: project.id, path: "/workspace" } ])
        allow(Docker::Volume).to receive(:get).and_return(mock_volume)
        allow(mock_container).to receive(:exec).with(
          [ "sh", "-c", "if [ -z \"$(ls -A . 2>/dev/null)\" ]; then exit 0; fi; exit 1" ],
          user: "agent"
        ).and_return([ [], [], 1 ])

        expect(mock_container).not_to receive(:exec).with(
          [ "sh", "-c", a_string_matching(/git clone/) ],
          anything
        )

        described_class.call(chat_session: chat_session)

        expect(chat_session.reload.clone_manifest_entries.size).to eq(1)
      end

      it "raises ProvisionError when clone fails" do
        allow(mock_container).to receive(:exec).with(
          [ "sh", "-c", a_string_matching(/git clone/) ],
          hash_including(user: "agent")
        ).and_return([ [ "fatal: repository not found" ], [], 128 ])

        expect { described_class.call(chat_session: chat_session) }
          .to raise_error(Containers::ProvisionForChat::ProvisionError, /Workspace clone failed/)
      end
    end

    context "when provisioning fails" do
      it "marks the session failed through the capability transition flow" do
        subscriber = Mcp::SessionTransport.subscribe(session_id: chat_session.id)
        allow(mock_container).to receive(:start).and_raise(Docker::Error::DockerError, "start failed")

        expect {
          described_class.call(chat_session: chat_session)
        }.to raise_error(Containers::ProvisionForChat::ProvisionError, /start failed/)

        expect(chat_session.reload.container_capability).to eq("failed")

        notice = chat_session.messages.where(role: "system").find_by("metadata ->> 'container_capability_notice' = 'true'")
        expect(notice.content).to include("Workspace tools are currently unavailable")
        expect(notice.metadata).to include(
          "container_capability_notice" => true,
          "container_capability" => "failed"
        )

        expect_tools_list_changed_event(subscriber:, capability: "provisioning", previous_capability: "none")
        expect_tools_list_changed_event(subscriber:, capability: "failed", previous_capability: "provisioning")
      ensure
        Mcp::SessionTransport.unsubscribe(session_id: chat_session.id, subscriber:)
      end

      it "cleans up container and volumes on Docker error" do
        allow(mock_container).to receive(:start).and_raise(Docker::Error::DockerError, "start failed")

        expect(mock_container).to receive(:stop).with(timeout: 0)
        expect(mock_container).to receive(:delete).with(force: true, v: true)

        expect { described_class.call(chat_session: chat_session) }
          .to raise_error(Containers::ProvisionForChat::ProvisionError, /start failed/)
      end

      it "preserves reused volumes on failure" do
        allow(Docker::Volume).to receive(:get).and_return(mock_volume)
        allow(mock_container).to receive(:start).and_raise(Docker::Error::DockerError, "start failed")

        expect(mock_container).to receive(:stop).with(timeout: 0)
        expect(mock_container).to receive(:delete).with(force: true, v: true)
        expect(mock_volume).not_to receive(:remove)

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

      it "skips workspace seeding" do
        expect(mock_container).to receive(:exec).with(
          [ "mkdir", "-p", *described_class::STATE_VOLUME_DIRS ],
          user: "root"
        ).ordered.and_return([ [], [], 0 ])
        expect(mock_container).to receive(:exec).with(
          [ "chown", "-R", "agent:agent", "/workspace", *described_class::STATE_VOLUME_DIRS ],
          user: "root"
        ).ordered.and_return([ [], [], 0 ])
        described_class.call(chat_session: chat_session)
      end
    end
  end

  def expect_tools_list_changed_event(subscriber:, capability:, previous_capability:)
    expect(subscriber.pop(timeout: 1)).to eq(
      event: "message",
      data: {
        jsonrpc: "2.0",
        method: "notifications/tools/list_changed",
        params: {
          sessionId: chat_session.external_id,
          containerCapability: capability,
          previousContainerCapability: previous_capability
        }
      }
    )
  end
end
