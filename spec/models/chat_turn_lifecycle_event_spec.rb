# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatTurnLifecycleEvent do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:chat_session) { create(:chat_session, account: account, created_by: user) }
  let(:chat_turn) { create(:chat_turn, chat_session: chat_session) }

  describe "validations" do
    it "requires a dotted event_name" do
      event = described_class.new(chat_turn: chat_turn, chat_session: chat_session, event_name: "not-dotted", occurred_at: Time.current)
      expect(event).not_to be_valid
    end

    it "is valid with a dotted event_name" do
      event = described_class.new(chat_turn: chat_turn, chat_session: chat_session, event_name: "chat_turn.completed", occurred_at: Time.current)
      expect(event).to be_valid
    end
  end

  # @spec CHAT-TURN-RECOVERY-007
  it "is readonly once persisted" do
    event = described_class.create!(chat_turn: chat_turn, chat_session: chat_session, event_name: "chat_turn.completed", occurred_at: Time.current)

    expect { event.update!(event_name: "chat_turn.failed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
