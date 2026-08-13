# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-CONTAINER-PROVISIONING-001
# @spec CHAT-CONTAINER-PROVISIONING-006
RSpec.describe ChatSessions::ReenqueuePendingProvisionJob, type: :job do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }

  describe "#perform" do
    it "enqueues the oldest pending session for provisioning" do
      older_session = create(:chat_session,
        account:,
        created_by: user,
        container_capability: "pending",
        container_requested_at: 2.minutes.ago)
      create(:chat_session,
        account:,
        created_by: user,
        container_capability: "pending",
        container_requested_at: 1.minute.ago)

      expect {
        described_class.perform_now(account_id: account.id)
      }.to have_enqueued_job(ChatSessions::ProvisionContainerJob)
        .with(chat_session_id: older_session.id, account_id: account.id)
    end

    it "skips the excluded session when draining pending work" do
      excluded_session = create(:chat_session,
        account:,
        created_by: user,
        container_capability: "pending",
        container_requested_at: 2.minutes.ago)
      other_session = create(:chat_session,
        account:,
        created_by: user,
        container_capability: "pending",
        container_requested_at: 1.minute.ago)

      expect {
        described_class.perform_now(account_id: account.id, exclude_chat_session_id: excluded_session.id)
      }.to have_enqueued_job(ChatSessions::ProvisionContainerJob)
        .with(chat_session_id: other_session.id, account_id: account.id)
    end

    it "does nothing when no pending sessions remain" do
      create(:chat_session, account:, created_by: user, container_capability: "ready")

      expect {
        described_class.perform_now(account_id: account.id)
      }.not_to have_enqueued_job(ChatSessions::ProvisionContainerJob)
    end
  end
end
