# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ToolDispatch do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account) }
  let(:dispatcher_class) do
    Class.new do
      include ChatSessions::ToolDispatch

      attr_reader :chat_session

      def initialize(chat_session)
        @chat_session = chat_session
      end

      def on_message_persisted; end

      def dispatch(name:, arguments:)
        dispatch_tool(name:, arguments:)
      end
    end
  end

  before do
    allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **|
      chat_session.update!(container_capability: "ready", container_id: "container-1")
    end
    allow(Tools::Registry).to receive(:dispatch).and_return({ status: "ok" })
  end

  it "replays the clone manifest when a stopped session is resumed by invoking a container tool" do
    session = create(:chat_session, account: account, created_by: user,
      container_capability: "stopped",
      clone_manifest: [ { project_id: project.id, path: "/workspace/#{project.full_name.tr('/', '-')}" } ])
    allow(ChatSessions::RestoreCloneManifest).to receive(:call)

    result = dispatcher_class.new(session).dispatch(name: "git_status", arguments: { "repo_path" => "/workspace" })

    expect(Containers::ProvisionForChat).to have_received(:call)
      .with(hash_including(chat_session: session, seed_project: false))
    expect(ChatSessions::RestoreCloneManifest).to have_received(:call).with(chat_session: session)
    expect(result).to eq(status: "ok")
  end

  it "seeds the primary project instead of restoring when a stopped session has no manifest" do
    session = create(:chat_session, account: account, created_by: user, container_capability: "stopped")
    allow(ChatSessions::RestoreCloneManifest).to receive(:call)

    dispatcher_class.new(session).dispatch(name: "git_status", arguments: { "repo_path" => "/workspace" })

    expect(Containers::ProvisionForChat).to have_received(:call)
      .with(hash_including(chat_session: session, seed_project: true))
    expect(ChatSessions::RestoreCloneManifest).not_to have_received(:call)
  end

  it "returns the session to stopped when manifest restore fails after provisioning" do
    session = create(:chat_session, account: account, created_by: user,
      container_capability: "stopped",
      clone_manifest: [ { project_id: project.id, path: "/workspace/#{project.full_name.tr('/', '-')}" } ])
    allow(Containers::ProvisionForChat).to receive(:call) do |chat_session:, **|
      chat_session.update!(container_capability: "ready", container_id: "container-1",
                           workspace_volume: "paid-chat-workspace-#{chat_session.id}")
    end
    allow(ChatSessions::RestoreCloneManifest).to receive(:call)
      .and_raise("Workspace reset failed: permission denied")
    allow(Docker::Container).to receive(:get).and_return(
      instance_double(Docker::Container, stop: true, delete: true)
    )
    allow(Docker::Volume).to receive(:get).and_return(
      instance_double(Docker::Volume, remove: true)
    )

    result = dispatcher_class.new(session).dispatch(name: "git_status", arguments: { "repo_path" => "/workspace" })

    expect(session.reload.container_capability).to eq("stopped")
    expect(session.container_id).to be_nil
    expect(session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")).to be_present
    expect(result).to include(status: "error", error: "container_unavailable")
  end
end
