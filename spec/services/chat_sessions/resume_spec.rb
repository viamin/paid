# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::Resume do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe ".call" do
    it "reopens a closed API session" do
      session = create(:chat_session, :closed, account: account, created_by: user, idle_timeout_at: 1.day.ago)

      freeze_time do
        described_class.call(chat_session: session)

        expect(session.reload.status).to eq("active")
        expect(session.idle_timeout_at).to be_within(5.seconds).of(30.minutes.from_now)
        expect(session.metadata).to include(
          "resume_count" => 1,
          "last_resumed_at" => Time.current.iso8601
        )
      end
    end

    it "increments resume metadata" do
      session = create(:chat_session, :closed, account: account, created_by: user,
        metadata: { "resume_count" => 2, "last_resumed_at" => 1.day.ago.iso8601 })

      described_class.call(chat_session: session)

      expect(session.reload.metadata["resume_count"]).to eq(3)
    end

    it "clears close snapshot metadata when reopening" do
      session = create(:chat_session, :closed, account: account, created_by: user,
        metadata: {
          "closed_at" => 1.day.ago.iso8601,
          "total_messages" => 9,
          "total_tokens_input" => 100,
          "total_tokens_output" => 50,
          "total_cost_cents" => 12
        })

      described_class.call(chat_session: session)

      expect(session.reload.metadata).not_to include(
        "closed_at",
        "total_messages",
        "total_tokens_input",
        "total_tokens_output",
        "total_cost_cents"
      )
    end

    it "treats already-active API sessions as a no-op" do
      session = create(:chat_session, account: account, created_by: user)

      expect {
        described_class.call(chat_session: session)
      }.not_to change { session.reload.attributes.slice("status", "metadata") }
    end

    it "rejects workspace sessions" do
      session = create(:chat_session, :closed, :workspace, account: account, created_by: user)

      expect {
        described_class.call(chat_session: session)
      }.to raise_error(ArgumentError, /cannot be resumed/)
    end

    it "rejects idle sessions" do
      session = create(:chat_session, :idle, account: account, created_by: user)

      expect {
        described_class.call(chat_session: session)
      }.to raise_error(ArgumentError, /active or closed/)
    end
  end
end
