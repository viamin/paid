# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::IdleReaperJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:expired_at) { 1.minute.ago }

  describe "#perform" do
    it "closes inline-only sessions past their idle timeout" do
      session = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago)
      create(:chat_message, chat_session: session)

      described_class.new.perform

      session.reload
      expect(session.status).to eq("closed")
    end

    it "stops container-backed sessions past their idle timeout without closing them" do
      session = create(:chat_session, :workspace,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago,
        clone_manifest: [ { project_id: 123, path: "/workspace/app" } ])

      manager = instance_double(Containers::ChatSessionManager)
      allow(Containers::ChatSessionManager).to receive(:new).with(session).and_return(manager)
      allow(manager).to receive(:cleanup!) do
        session.update!(container_capability: "stopped", container_id: nil, workspace_volume: nil)
      end

      described_class.new.perform

      session.reload
      expect(session.status).to eq("active")
      expect(session.container_capability).to eq("stopped")
      expect(session.clone_manifest_entries).to contain_exactly(a_hash_including(project_id: 123, path: "/workspace/app"))
      expect(session.idle_timeout_at).to be_nil
      expect(manager).to have_received(:cleanup!).with(preserve_state: true)
    end

    it "does not close sessions before their timeout" do
      session = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 30.minutes.from_now)

      described_class.new.perform

      expect(session.reload.status).to eq("active")
    end

    it "computes token totals when closing inline-only sessions" do
      session = create(:chat_session,
        account: account,
        created_by: user,
        idle_timeout_at: 1.minute.ago)
      create(:chat_message, chat_session: session)
      create(:token_usage, :chat, chat_session: session, input_tokens: 50, output_tokens: 25, cost_cents: 0)

      described_class.new.perform

      session.reload
      expect(session.metadata["total_tokens_input"]).to eq(50)
    end

    it "continues processing if one session fails" do
      session1 = create_expired_inline_session
      session2 = create_expired_workspace_session
      create(:chat_message, chat_session: session1)
      create(:chat_message, chat_session: session2)

      allow(ChatSessions::Close).to receive(:call)
        .with(chat_session: anything)
        .and_call_original
      allow(ChatSessions::ReapIdleWorkspace).to receive(:call)
        .with(chat_session: session2) do
          session2.update!(container_capability: "stopped", container_id: nil, workspace_volume: nil, idle_timeout_at: nil)
          session2
        end

      # Both should be attempted even if processing continues
      described_class.new.perform

      expect(session1.reload.status).to eq("closed")
      expect(session2.reload.status).to eq("active")
    end
  end

  def create_expired_inline_session
    create(:chat_session, account: account, created_by: user, idle_timeout_at: expired_at)
  end

  def create_expired_workspace_session
    create(:chat_session, :workspace, account: account, created_by: user, idle_timeout_at: expired_at)
  end
end
