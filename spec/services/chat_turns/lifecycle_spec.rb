# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurns::Lifecycle do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:chat_turn) { create(:chat_turn, chat_session: chat_session) }

  describe ".record" do
    # @spec CHAT-TURN-RECOVERY-007
    it "persists a lifecycle event" do
      event = described_class.record(event_name: "chat_turn.completed", chat_turn: chat_turn, metadata: { foo: "bar" })

      expect(event).to be_persisted
      expect(event.chat_session).to eq(chat_session)
      expect(event.metadata).to eq("foo" => "bar")
    end

    it "logs and swallows a write failure instead of raising" do
      allow(ChatTurnLifecycleEvent).to receive(:create!).and_raise(StandardError, "db unavailable")

      expect { described_class.record(event_name: "chat_turn.completed", chat_turn: chat_turn) }.not_to raise_error
    end
  end
end
